package llm

import (
	"context"
	"sort"
	"strings"
	"unicode"
)

// Fake is a deterministic extractive summarizer. It needs no network access,
// which makes it the default for local clusters, CI and load tests.
type Fake struct{}

// NewFake returns the offline backend.
func NewFake() *Fake { return &Fake{} }

// Name implements Summarizer.
func (*Fake) Name() string { return "fake" }

var stopwords = map[string]struct{}{
	"a": {}, "an": {}, "and": {}, "are": {}, "as": {}, "at": {}, "be": {}, "by": {}, "for": {},
	"from": {}, "has": {}, "in": {}, "is": {}, "it": {}, "its": {}, "of": {}, "on": {}, "or": {},
	"that": {}, "the": {}, "this": {}, "to": {}, "was": {}, "were": {}, "will": {}, "with": {},
}

// Summarize scores sentences by the frequency of their non-stopword terms and
// returns the top N in their original order.
func (*Fake) Summarize(ctx context.Context, req Request) (Result, error) {
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	sentences := splitSentences(req.Text)
	n := req.MaxSentences
	if n <= 0 || n > len(sentences) {
		n = len(sentences)
	}

	freq := map[string]int{}
	tokenized := make([][]string, len(sentences))
	for i, s := range sentences {
		for _, w := range words(s) {
			if _, stop := stopwords[w]; stop {
				continue
			}
			freq[w]++
			tokenized[i] = append(tokenized[i], w)
		}
	}

	type scored struct {
		idx   int
		score float64
	}
	ranked := make([]scored, len(sentences))
	for i, toks := range tokenized {
		total := 0
		for _, w := range toks {
			total += freq[w]
		}
		score := 0.0
		if len(toks) > 0 {
			score = float64(total) / float64(len(toks))
		}
		ranked[i] = scored{idx: i, score: score}
	}
	sort.SliceStable(ranked, func(a, b int) bool { return ranked[a].score > ranked[b].score })

	picked := make([]int, 0, n)
	for _, r := range ranked[:n] {
		picked = append(picked, r.idx)
	}
	sort.Ints(picked)

	out := make([]string, 0, n)
	for _, i := range picked {
		out = append(out, sentences[i])
	}
	summary := strings.Join(out, " ")
	return Result{
		Summary:      summary,
		Model:        "fake-extractive-v1",
		InputTokens:  approxTokens(req.Text),
		OutputTokens: approxTokens(summary),
	}, nil
}

func splitSentences(text string) []string {
	var out []string
	var b strings.Builder
	runes := []rune(strings.TrimSpace(text))
	for i, r := range runes {
		b.WriteRune(r)
		end := r == '.' || r == '!' || r == '?'
		if end && (i+1 == len(runes) || unicode.IsSpace(runes[i+1])) {
			if s := strings.TrimSpace(b.String()); s != "" {
				out = append(out, s)
			}
			b.Reset()
		}
	}
	if s := strings.TrimSpace(b.String()); s != "" {
		out = append(out, s)
	}
	return out
}

func words(s string) []string {
	return strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
}
