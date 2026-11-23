// Package llm defines the summarization backend contract and its implementations.
package llm

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"
)

// ErrUpstream is returned when the backing model provider fails or misbehaves.
var ErrUpstream = errors.New("llm upstream error")

// Request is a single summarization job.
type Request struct {
	Text         string
	MaxSentences int
}

// Result is the backend output plus accounting metadata used for metrics.
type Result struct {
	Summary      string
	Model        string
	InputTokens  int
	OutputTokens int
}

// Summarizer is implemented by every backend.
type Summarizer interface {
	Name() string
	Summarize(ctx context.Context, req Request) (Result, error)
}

// Config selects and configures a backend.
type Config struct {
	Backend string // "fake" (default) or "openai"
	BaseURL string // OpenAI-compatible endpoint, e.g. https://api.openai.com/v1 or a vLLM/Ollama gateway
	APIKey  string
	Model   string
	Timeout time.Duration
}

// New builds the backend described by cfg.
func New(cfg Config) (Summarizer, error) {
	switch cfg.Backend {
	case "", "fake":
		return NewFake(), nil
	case "openai":
		if cfg.BaseURL == "" || cfg.Model == "" {
			return nil, fmt.Errorf("openai backend requires LLM_BASE_URL and LLM_MODEL")
		}
		timeout := cfg.Timeout
		if timeout <= 0 {
			timeout = 30 * time.Second
		}
		return NewOpenAI(cfg.BaseURL, cfg.APIKey, cfg.Model, &http.Client{Timeout: timeout}), nil
	default:
		return nil, fmt.Errorf("unknown LLM backend %q (want fake|openai)", cfg.Backend)
	}
}

// approxTokens is a cheap, deterministic token estimate (~4 chars/token) used
// when a backend does not report usage.
func approxTokens(s string) int {
	if s == "" {
		return 0
	}
	return (len(s) + 3) / 4
}
