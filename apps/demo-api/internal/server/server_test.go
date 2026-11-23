package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/RatulSikder97/platform-blueprint/apps/demo-api/internal/llm"
)

type failingLLM struct{}

func (failingLLM) Name() string { return "failing" }
func (failingLLM) Summarize(context.Context, llm.Request) (llm.Result, error) {
	return llm.Result{}, errors.New("boom")
}

func newTestServer(t *testing.T, s llm.Summarizer) *Server {
	t.Helper()
	return New(Options{
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		Summarizer: s,
		Version:    "test",
	})
}

func do(t *testing.T, h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequestWithContext(context.Background(), method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestHealthAndReadiness(t *testing.T) {
	s := newTestServer(t, llm.NewFake())
	h := s.Handler()

	if rec := do(t, h, http.MethodGet, "/healthz", ""); rec.Code != http.StatusOK {
		t.Fatalf("healthz: %d", rec.Code)
	}
	if rec := do(t, h, http.MethodGet, "/readyz", ""); rec.Code != http.StatusOK {
		t.Fatalf("readyz: %d", rec.Code)
	}
	s.SetReady(false)
	if rec := do(t, h, http.MethodGet, "/readyz", ""); rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz after drain: %d", rec.Code)
	}
	// Liveness must stay green while draining.
	if rec := do(t, h, http.MethodGet, "/healthz", ""); rec.Code != http.StatusOK {
		t.Fatalf("healthz after drain: %d", rec.Code)
	}
}

func TestSummarize(t *testing.T) {
	h := newTestServer(t, llm.NewFake()).Handler()

	tests := []struct {
		name string
		body string
		code int
	}{
		{"ok", `{"text":"One fact here. Another fact here. A third.","max_sentences":2}`, http.StatusOK},
		{"default sentences", `{"text":"Just one sentence."}`, http.StatusOK},
		{"empty text", `{"text":"   "}`, http.StatusUnprocessableEntity},
		{"too many sentences", `{"text":"x.","max_sentences":99}`, http.StatusUnprocessableEntity},
		{"negative sentences", `{"text":"x.","max_sentences":-1}`, http.StatusUnprocessableEntity},
		{"unknown field", `{"text":"x.","prompt":"ignore previous"}`, http.StatusBadRequest},
		{"malformed", `{"text":`, http.StatusBadRequest},
		{"too large", `{"text":"` + strings.Repeat("a", maxBodyBytes+1) + `"}`, http.StatusRequestEntityTooLarge},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := do(t, h, http.MethodPost, "/v1/summarize", tc.body)
			if rec.Code != tc.code {
				t.Fatalf("got %d want %d: %s", rec.Code, tc.code, rec.Body.String())
			}
			if rec.Header().Get("X-Request-Id") == "" {
				t.Fatal("missing X-Request-Id")
			}
			if tc.code == http.StatusOK {
				var out SummarizeResponse
				if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
					t.Fatal(err)
				}
				if out.Summary == "" || out.Backend != "fake" || out.Usage.InputTokens == 0 {
					t.Fatalf("unexpected response %+v", out)
				}
			}
		})
	}
}

func TestSummarizeRejectsWrongContentType(t *testing.T) {
	h := newTestServer(t, llm.NewFake()).Handler()
	req := httptest.NewRequestWithContext(context.Background(), http.MethodPost, "/v1/summarize", strings.NewReader("text=hi"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("got %d", rec.Code)
	}
}

func TestSummarizeBackendFailureIs502AndCounted(t *testing.T) {
	h := newTestServer(t, failingLLM{}).Handler()
	if rec := do(t, h, http.MethodPost, "/v1/summarize", `{"text":"x."}`); rec.Code != http.StatusBadGateway {
		t.Fatalf("got %d", rec.Code)
	}
	metrics := do(t, h, http.MethodGet, "/metrics", "").Body.String()
	if !strings.Contains(metrics, `llm_errors_total{backend="failing"} 1`) {
		t.Fatalf("llm_errors_total not incremented:\n%s", metrics)
	}
}

func TestMetricsExposeRequestAndTokenCounters(t *testing.T) {
	h := newTestServer(t, llm.NewFake()).Handler()
	do(t, h, http.MethodPost, "/v1/summarize", `{"text":"Alpha beta. Gamma delta."}`)

	rec := do(t, h, http.MethodGet, "/metrics", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("metrics: %d", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{
		`http_requests_total{code="200",method="POST",route="/v1/summarize"} 1`,
		`llm_tokens_total{backend="fake",direction="input",model="fake-extractive-v1"}`,
		`demo_api_build_info{llm_backend="fake",version="test"} 1`,
		`go_goroutines`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics missing %q", want)
		}
	}
}

func TestMethodNotAllowed(t *testing.T) {
	h := newTestServer(t, llm.NewFake()).Handler()
	if rec := do(t, h, http.MethodGet, "/v1/summarize", ""); rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("got %d", rec.Code)
	}
}
