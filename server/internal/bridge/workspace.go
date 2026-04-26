package bridge

import (
	"context"
	"net/url"
	"strconv"
)

// WorkspaceFolder describes a single VS Code workspace folder.
type WorkspaceFolder struct {
	URI    string `json:"uri"`
	Name   string `json:"name"`
	Index  int    `json:"index"`
	FSPath string `json:"fsPath"`
}

// FileMatch is returned by /workspace/findFiles.
type FileMatch struct {
	URI    string `json:"uri"`
	FSPath string `json:"fsPath"`
}

// TextMatch is returned by /workspace/findText.
type TextMatch struct {
	URI     string `json:"uri"`
	FSPath  string `json:"fsPath"`
	Range   *Range `json:"range,omitempty"`
	Preview string `json:"preview,omitempty"`
}

// WorkspaceFolders returns the live VS Code workspace folders.
func (c *Client) WorkspaceFolders(ctx context.Context) ([]WorkspaceFolder, error) {
	var out []WorkspaceFolder
	if err := c.Get(ctx, "/workspace/folders", nil, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// FindFilesOptions controls /workspace/findFiles.
type FindFilesOptions struct {
	Glob       string
	Excludes   string
	MaxResults int
}

// FindFiles forwards to vscode.workspace.findFiles inside the extension host.
func (c *Client) FindFiles(ctx context.Context, opts FindFilesOptions) ([]FileMatch, error) {
	q := url.Values{}
	glob := opts.Glob
	if glob == "" {
		glob = "**/*"
	}
	q.Set("glob", glob)
	if opts.Excludes != "" {
		q.Set("excludes", opts.Excludes)
	}
	if opts.MaxResults > 0 {
		q.Set("maxResults", strconv.Itoa(opts.MaxResults))
	}
	var out []FileMatch
	if err := c.Get(ctx, "/workspace/findFiles", q, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// FindTextOptions controls /workspace/findText.
type FindTextOptions struct {
	Query           string
	IsRegex         bool
	IsCaseSensitive bool
	IsWordMatch     bool
	Include         string
	Exclude         string
}

// FindText forwards to vscode.workspace.findTextInFiles (with a manual
// fallback inside the extension when that proposed API is unavailable).
func (c *Client) FindText(ctx context.Context, opts FindTextOptions) ([]TextMatch, error) {
	q := url.Values{"query": {opts.Query}}
	if opts.IsRegex {
		q.Set("isRegex", "true")
	}
	if opts.IsCaseSensitive {
		q.Set("isCaseSensitive", "true")
	}
	if opts.IsWordMatch {
		q.Set("isWordMatch", "true")
	}
	if opts.Include != "" {
		q.Set("include", opts.Include)
	}
	if opts.Exclude != "" {
		q.Set("exclude", opts.Exclude)
	}
	var out []TextMatch
	if err := c.Get(ctx, "/workspace/findText", q, &out); err != nil {
		return nil, err
	}
	return out, nil
}
