// Package server wires HTTP routes, middleware and Prometheus metrics.
package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/RatulSikder97/platform-blueprint/apps/demo-api/internal/llm"
)

const (
	maxBodyBytes = 64 << 10 // 64 KiB of input text is plenty for a summarize call
	maxSentences = 20
)

// Options configures the HTTP handler.
type Options struct {
	Logger      *slog.Logger
	Summarizer  llm.Summarizer
	Version     string
	CallTimeout time.Duration
}

// Server holds handler state. Ready flips to false during graceful shutdown so
// /readyz fails and the endpoint is removed from Service endpoints first.
type Server struct {
	opts    Options
	ready   atomic.Bool
	reg     *prometheus.Registry
	metrics metrics
	mux     *http.ServeMux
}

type metrics struct {
	requests  *prometheus.CounterVec
	latency   *prometheus.HistogramVec
	llmTokens *prometheus.CounterVec
	llmErrors *prometheus.CounterVec
	inflight  prometheus.Gauge
}

// New builds a Server with its own Prometheus registry.
func New(opts Options) *Server {
	if opts.CallTimeout <= 0 {
		opts.CallTimeout = 30 * time.Second
	}
	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))

	m := metrics{
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total", Help: "HTTP requests by route, method and status code.",
		}, []string{"route", "method", "code"}),
		latency: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "http_request_duration_seconds", Help: "HTTP request latency by route.",
			Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10, 30},
		}, []string{"route", "method"}),
		llmTokens: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "llm_tokens_total", Help: "LLM tokens consumed, by backend, model and direction.",
		}, []string{"backend", "model", "direction"}),
		llmErrors: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "llm_errors_total", Help: "LLM backend failures by backend.",
		}, []string{"backend"}),
		inflight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_inflight_requests", Help: "In-flight HTTP requests.",
		}),
	}
	reg.MustRegister(m.requests, m.latency, m.llmTokens, m.llmErrors, m.inflight)

	buildInfo := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "demo_api_build_info", Help: "Build metadata.",
	}, []string{"version", "llm_backend"})
	reg.MustRegister(buildInfo)
	buildInfo.WithLabelValues(opts.Version, opts.Summarizer.Name()).Set(1)

	s := &Server{opts: opts, reg: reg, metrics: m, mux: http.NewServeMux()}
	s.ready.Store(true)

	s.route("GET /healthz", "/healthz", s.handleHealth)
	s.route("GET /readyz", "/readyz", s.handleReady)
	s.route("POST /v1/summarize", "/v1/summarize", s.handleSummarize)
	s.mux.Handle("GET /metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{Registry: reg}))
	return s
}

// Handler returns the root handler with recovery applied.
func (s *Server) Handler() http.Handler { return s.recoverer(s.mux) }

// SetReady toggles readiness (used on SIGTERM).
func (s *Server) SetReady(v bool) { s.ready.Store(v) }

func (s *Server) route(pattern, name string, h http.HandlerFunc) {
	s.mux.Handle(pattern, s.instrument(name, h))
}

type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.code = code
	r.ResponseWriter.WriteHeader(code)
}

func (s *Server) instrument(route string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		s.metrics.inflight.Inc()
		defer s.metrics.inflight.Dec()

		reqID := r.Header.Get("X-Request-Id")
		if reqID == "" || len(reqID) > 64 {
			reqID = newRequestID()
		}
		w.Header().Set("X-Request-Id", reqID)

		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		next.ServeHTTP(rec, r)

		elapsed := time.Since(start)
		s.metrics.requests.WithLabelValues(route, r.Method, strconv.Itoa(rec.code)).Inc()
		s.metrics.latency.WithLabelValues(route, r.Method).Observe(elapsed.Seconds())
		if route != "/healthz" && route != "/readyz" {
			s.opts.Logger.Info("request",
				"request_id", reqID, "method", r.Method, "route", route,
				"status", rec.code, "duration_ms", elapsed.Milliseconds())
		}
	})
}

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				if err, ok := v.(error); ok && errors.Is(err, http.ErrAbortHandler) {
					panic(v)
				}
				s.opts.Logger.Error("panic", "path", r.URL.Path, "panic", v)
				writeError(w, http.StatusInternalServerError, "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": s.opts.Version})
}

func (s *Server) handleReady(w http.ResponseWriter, _ *http.Request) {
	if !s.ready.Load() {
		writeError(w, http.StatusServiceUnavailable, "shutting down")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// SummarizeRequest is the public request body for POST /v1/summarize.
type SummarizeRequest struct {
	Text         string `json:"text"`
	MaxSentences int    `json:"max_sentences"`
}

// SummarizeResponse is the public response body for POST /v1/summarize.
type SummarizeResponse struct {
	Summary string `json:"summary"`
	Model   string `json:"model"`
	Backend string `json:"backend"`
	Usage   struct {
		InputTokens  int `json:"input_tokens"`
		OutputTokens int `json:"output_tokens"`
	} `json:"usage"`
}

func (s *Server) handleSummarize(w http.ResponseWriter, r *http.Request) {
	if ct := r.Header.Get("Content-Type"); ct != "" && !strings.HasPrefix(ct, "application/json") {
		writeError(w, http.StatusUnsupportedMediaType, "content-type must be application/json")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()

	var req SummarizeRequest
	if err := dec.Decode(&req); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, http.StatusRequestEntityTooLarge, "request body too large")
			return
		}
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	req.Text = strings.TrimSpace(req.Text)
	if req.Text == "" {
		writeError(w, http.StatusUnprocessableEntity, "text is required")
		return
	}
	if req.MaxSentences < 0 || req.MaxSentences > maxSentences {
		writeError(w, http.StatusUnprocessableEntity, "max_sentences must be between 0 and 20")
		return
	}
	if req.MaxSentences == 0 {
		req.MaxSentences = 3
	}

	ctx, cancel := context.WithTimeout(r.Context(), s.opts.CallTimeout)
	defer cancel()

	backend := s.opts.Summarizer.Name()
	res, err := s.opts.Summarizer.Summarize(ctx, llm.Request{Text: req.Text, MaxSentences: req.MaxSentences})
	if err != nil {
		s.metrics.llmErrors.WithLabelValues(backend).Inc()
		s.opts.Logger.Warn("summarize failed", "backend", backend, "err", err)
		writeError(w, http.StatusBadGateway, "summarization backend unavailable")
		return
	}
	s.metrics.llmTokens.WithLabelValues(backend, res.Model, "input").Add(float64(res.InputTokens))
	s.metrics.llmTokens.WithLabelValues(backend, res.Model, "output").Add(float64(res.OutputTokens))

	var out SummarizeResponse
	out.Summary, out.Model, out.Backend = res.Summary, res.Model, backend
	out.Usage.InputTokens, out.Usage.OutputTokens = res.InputTokens, res.OutputTokens
	writeJSON(w, http.StatusOK, out)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func newRequestID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}
