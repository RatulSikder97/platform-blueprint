package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// OpenAI talks to any OpenAI-compatible /chat/completions endpoint
// (OpenAI, Azure OpenAI proxies, vLLM, Ollama, LiteLLM, Bedrock gateways).
type OpenAI struct {
	baseURL string
	apiKey  string
	model   string
	client  *http.Client
}

// NewOpenAI returns an OpenAI-compatible backend.
func NewOpenAI(baseURL, apiKey, model string, client *http.Client) *OpenAI {
	return &OpenAI{baseURL: strings.TrimRight(baseURL, "/"), apiKey: apiKey, model: model, client: client}
}

// Name implements Summarizer.
func (*OpenAI) Name() string { return "openai" }

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatRequest struct {
	Model       string        `json:"model"`
	Messages    []chatMessage `json:"messages"`
	Temperature float64       `json:"temperature"`
}

type chatResponse struct {
	Model   string `json:"model"`
	Choices []struct {
		Message chatMessage `json:"message"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
}

// Summarize implements Summarizer.
func (o *OpenAI) Summarize(ctx context.Context, req Request) (Result, error) {
	n := req.MaxSentences
	if n <= 0 {
		n = 3
	}
	body, err := json.Marshal(chatRequest{
		Model:       o.model,
		Temperature: 0,
		Messages: []chatMessage{
			{Role: "system", Content: fmt.Sprintf("Summarize the user's text in at most %d sentences. Output only the summary.", n)},
			{Role: "user", Content: req.Text},
		},
	})
	if err != nil {
		return Result{}, err
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, o.baseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return Result{}, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if o.apiKey != "" {
		httpReq.Header.Set("Authorization", "Bearer "+o.apiKey)
	}

	resp, err := o.client.Do(httpReq)
	if err != nil {
		return Result{}, fmt.Errorf("%w: %w", ErrUpstream, err)
	}
	defer func() { _ = resp.Body.Close() }()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return Result{}, fmt.Errorf("%w: read body: %w", ErrUpstream, err)
	}
	if resp.StatusCode != http.StatusOK {
		return Result{}, fmt.Errorf("%w: status %d", ErrUpstream, resp.StatusCode)
	}

	var cr chatResponse
	if err := json.Unmarshal(raw, &cr); err != nil {
		return Result{}, fmt.Errorf("%w: decode: %w", ErrUpstream, err)
	}
	if len(cr.Choices) == 0 {
		return Result{}, fmt.Errorf("%w: no choices returned", ErrUpstream)
	}

	summary := strings.TrimSpace(cr.Choices[0].Message.Content)
	res := Result{
		Summary:      summary,
		Model:        cr.Model,
		InputTokens:  cr.Usage.PromptTokens,
		OutputTokens: cr.Usage.CompletionTokens,
	}
	if res.Model == "" {
		res.Model = o.model
	}
	if res.InputTokens == 0 {
		res.InputTokens = approxTokens(req.Text)
	}
	if res.OutputTokens == 0 {
		res.OutputTokens = approxTokens(summary)
	}
	return res, nil
}
