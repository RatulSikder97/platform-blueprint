package llm

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestFakeSummarize(t *testing.T) {
	text := "Kubernetes schedules pods. Pods run containers on nodes. " +
		"The weather is nice today. Nodes and pods are scheduled by Kubernetes."

	tests := []struct {
		name      string
		max       int
		wantCount int
	}{
		{"one sentence", 1, 1},
		{"two sentences", 2, 2},
		{"zero means all", 0, 4},
		{"more than available", 10, 4},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			res, err := NewFake().Summarize(context.Background(), Request{Text: text, MaxSentences: tc.max})
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got := len(splitSentences(res.Summary)); got != tc.wantCount {
				t.Fatalf("got %d sentences, want %d: %q", got, tc.wantCount, res.Summary)
			}
			if res.InputTokens == 0 || res.OutputTokens == 0 {
				t.Fatalf("token accounting missing: %+v", res)
			}
		})
	}
}

func TestFakeDropsLowSignalSentence(t *testing.T) {
	text := "Kubernetes schedules pods. Pods run containers on nodes. " +
		"The weather is nice today. Nodes and pods are scheduled by Kubernetes."
	res, err := NewFake().Summarize(context.Background(), Request{Text: text, MaxSentences: 3})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(res.Summary, "weather") {
		t.Fatalf("expected off-topic sentence to be dropped, got %q", res.Summary)
	}
}

func TestFakeHonoursCancelledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := NewFake().Summarize(ctx, Request{Text: "a. b."}); !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled, got %v", err)
	}
}

func TestOpenAIBackend(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Errorf("unexpected auth header %q", got)
		}
		var req chatRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode: %v", err)
		}
		if req.Model != "small-model" || len(req.Messages) != 2 {
			t.Errorf("unexpected request %+v", req)
		}
		_, _ = w.Write([]byte(`{"model":"small-model","choices":[{"message":{"role":"assistant","content":" Short. "}}],"usage":{"prompt_tokens":12,"completion_tokens":2}}`))
	}))
	defer srv.Close()

	b := NewOpenAI(srv.URL+"/v1/", "test-key", "small-model", srv.Client())
	res, err := b.Summarize(context.Background(), Request{Text: "Long text.", MaxSentences: 1})
	if err != nil {
		t.Fatal(err)
	}
	if res.Summary != "Short." || res.InputTokens != 12 || res.OutputTokens != 2 || res.Model != "small-model" {
		t.Fatalf("unexpected result %+v", res)
	}
}

func TestOpenAIBackendUpstreamError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()

	_, err := NewOpenAI(srv.URL, "", "m", srv.Client()).Summarize(context.Background(), Request{Text: "x."})
	if !errors.Is(err, ErrUpstream) {
		t.Fatalf("want ErrUpstream, got %v", err)
	}
}

func TestNew(t *testing.T) {
	if s, err := New(Config{}); err != nil || s.Name() != "fake" {
		t.Fatalf("default backend: %v %v", s, err)
	}
	if _, err := New(Config{Backend: "openai"}); err == nil {
		t.Fatal("expected error for openai without base URL/model")
	}
	if _, err := New(Config{Backend: "nope"}); err == nil {
		t.Fatal("expected error for unknown backend")
	}
	if s, err := New(Config{Backend: "openai", BaseURL: "http://x", Model: "m"}); err != nil || s.Name() != "openai" {
		t.Fatalf("openai backend: %v %v", s, err)
	}
}
