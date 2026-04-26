package bridge

import (
	"context"
	"net/url"
)

// Range mirrors the JSON range emitted by the extension.
type Range struct {
	Start Position `json:"start"`
	End   Position `json:"end"`
}

// Position is a 0-based line/character pair.
type Position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

// Diagnostic mirrors a single diagnostic emitted by the extension. We reuse
// language-server style severity strings (`error`/`warning`/`info`/`hint`).
type Diagnostic struct {
	URI      string `json:"uri"`
	FilePath string `json:"filePath"`
	Range    *Range `json:"range,omitempty"`
	Severity string `json:"severity"`
	Message  string `json:"message"`
	Source   string `json:"source"`
	Code     string `json:"code,omitempty"`
}

// DiagnosticsList fetches diagnostics from the live extension host. `path` and
// `workDir` are optional filters that the extension applies to fsPath prefixes.
func (c *Client) DiagnosticsList(ctx context.Context, path, workDir string) ([]Diagnostic, error) {
	q := url.Values{}
	if path != "" {
		q.Set("path", path)
	}
	if workDir != "" {
		q.Set("workDir", workDir)
	}
	var out []Diagnostic
	if err := c.Get(ctx, "/diagnostics", q, &out); err != nil {
		return nil, err
	}
	return out, nil
}
