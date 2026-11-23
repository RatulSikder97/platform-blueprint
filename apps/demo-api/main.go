// Command demo-api is a minimal LLM-backed microservice used to exercise the
// platform's Helm chart, observability stack and CI pipeline.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/RatulSikder97/platform-blueprint/apps/demo-api/internal/llm"
	"github.com/RatulSikder97/platform-blueprint/apps/demo-api/internal/server"
)

// version is overridden at build time via -ldflags "-X main.version=...".
var version = "dev"

func main() {
	healthcheck := flag.Bool("healthcheck", false, "probe the local /healthz endpoint and exit (for container HEALTHCHECK)")
	flag.Parse()

	port := envOr("PORT", "8080")
	if *healthcheck {
		os.Exit(probe(port))
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel()}))
	if err := run(logger, port); err != nil {
		logger.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger, port string) error {
	callTimeout := durationEnv("LLM_TIMEOUT", 30*time.Second)
	summarizer, err := llm.New(llm.Config{
		Backend: os.Getenv("LLM_BACKEND"),
		BaseURL: os.Getenv("LLM_BASE_URL"),
		APIKey:  os.Getenv("LLM_API_KEY"),
		Model:   os.Getenv("LLM_MODEL"),
		Timeout: callTimeout,
	})
	if err != nil {
		return err
	}

	srv := server.New(server.Options{
		Logger:      logger,
		Summarizer:  summarizer,
		Version:     version,
		CallTimeout: callTimeout,
	})

	httpSrv := &http.Server{
		Addr:              net.JoinHostPort("", port),
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      callTimeout + 5*time.Second,
		IdleTimeout:       60 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		logger.Info("listening", "addr", httpSrv.Addr, "version", version, "llm_backend", summarizer.Name())
		errCh <- httpSrv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
	}

	// Fail readiness first, give kube-proxy / the load balancer time to
	// deregister the endpoint, then drain in-flight requests.
	srv.SetReady(false)
	drainDelay := durationEnv("SHUTDOWN_DRAIN_DELAY", 5*time.Second)
	logger.Info("shutdown signal received", "drain_delay", drainDelay.String())
	time.Sleep(drainDelay)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), durationEnv("SHUTDOWN_TIMEOUT", 20*time.Second))
	defer cancel()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}
	logger.Info("shutdown complete")
	return nil
}

func probe(port string) int {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://127.0.0.1:"+port+"/healthz", nil)
	if err != nil {
		return 1
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 1
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func durationEnv(key string, def time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	if d, err := time.ParseDuration(v); err == nil {
		return d
	}
	if secs, err := strconv.Atoi(v); err == nil {
		return time.Duration(secs) * time.Second
	}
	return def
}

func logLevel() slog.Level {
	var l slog.Level
	if err := l.UnmarshalText([]byte(envOr("LOG_LEVEL", "info"))); err != nil {
		return slog.LevelInfo
	}
	return l
}
