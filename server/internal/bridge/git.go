package bridge

import (
	"context"
	"net/url"
)

// RepositoryState mirrors the JSON returned by the extension's
// `git.bridge.getRepositoryState` command. It uses interface{} fields so the
// API layer can simply forward the structure to clients without re-typing
// every field.
type RepositoryState = map[string]any

// DiffResponse mirrors the extension diff payload.
type DiffResponse struct {
	Path   string `json:"path"`
	Diff   string `json:"diff"`
	Staged bool   `json:"staged"`
}

// FileCommandRequest is the body shape used by stage/unstage/discard.
type FileCommandRequest struct {
	Path  string   `json:"path"`
	File  string   `json:"file,omitempty"`
	Files []string `json:"files,omitempty"`
}

// CommitRequest is the body for commit.
type CommitRequest struct {
	Path    string `json:"path"`
	Message string `json:"message"`
}

// CheckoutRequest is the body for checkout.
type CheckoutRequest struct {
	Path   string `json:"path"`
	Ref    string `json:"ref,omitempty"`
	Branch string `json:"branch,omitempty"`
	Create bool   `json:"create,omitempty"`
}

// RemoteCommandRequest is the body for fetch/pull/push.
type RemoteCommandRequest struct {
	Path        string `json:"path"`
	Remote      string `json:"remote,omitempty"`
	Branch      string `json:"branch,omitempty"`
	SetUpstream bool   `json:"setUpstream,omitempty"`
}

// StashRequest is the body for stash.
type StashRequest struct {
	Path             string `json:"path"`
	Message          string `json:"message,omitempty"`
	IncludeUntracked bool   `json:"includeUntracked,omitempty"`
}

// StashApplyRequest is the body for stash apply / pop.
type StashApplyRequest struct {
	Path  string `json:"path"`
	Stash string `json:"stash,omitempty"`
	Pop   bool   `json:"pop,omitempty"`
}

// GitGetRepository fetches the full repository state for `repoPath`.
func (c *Client) GitGetRepository(ctx context.Context, repoPath string) (RepositoryState, error) {
	q := url.Values{"path": {repoPath}}
	var out RepositoryState
	if err := c.Get(ctx, "/git/repository", q, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// GitDiff fetches the diff for a file.
func (c *Client) GitDiff(ctx context.Context, repoPath, file string, staged bool) (*DiffResponse, error) {
	q := url.Values{
		"path": {repoPath},
		"file": {file},
	}
	if staged {
		q.Set("staged", "true")
	}
	var out DiffResponse
	if err := c.Get(ctx, "/git/diff", q, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

// GitStage stages files.
func (c *Client) GitStage(ctx context.Context, req FileCommandRequest) (RepositoryState, error) {
	return c.gitFileCommand(ctx, "/git/stage", req)
}

// GitUnstage unstages files.
func (c *Client) GitUnstage(ctx context.Context, req FileCommandRequest) (RepositoryState, error) {
	return c.gitFileCommand(ctx, "/git/unstage", req)
}

// GitDiscard discards local changes for files.
func (c *Client) GitDiscard(ctx context.Context, req FileCommandRequest) (RepositoryState, error) {
	return c.gitFileCommand(ctx, "/git/discard", req)
}

// GitCommit creates a commit with the given message.
func (c *Client) GitCommit(ctx context.Context, req CommitRequest) (RepositoryState, error) {
	var out RepositoryState
	if err := c.Post(ctx, "/git/commit", req, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// GitCheckout checks out (or creates and checks out) a ref.
func (c *Client) GitCheckout(ctx context.Context, req CheckoutRequest) (RepositoryState, error) {
	var out RepositoryState
	if err := c.Post(ctx, "/git/checkout", req, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// GitFetch performs `git fetch`.
func (c *Client) GitFetch(ctx context.Context, req RemoteCommandRequest) (RepositoryState, error) {
	var out RepositoryState
	if err := c.Post(ctx, "/git/fetch", req, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// GitPull performs `git pull`.
func (c *Client) GitPull(ctx context.Context, req RemoteCommandRequest) (RepositoryState, error) {
	var out RepositoryState
	if err := c.Post(ctx, "/git/pull", req, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// GitPush performs `git push`.
func (c *Client) GitPush(ctx context.Context, req RemoteCommandRequest) (RepositoryState, error) {
	var out RepositoryState
	if err := c.Post(ctx, "/git/push", req, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// GitStash performs `git stash push`.
func (c *Client) GitStash(ctx context.Context, req StashRequest) (RepositoryState, error) {
	var out RepositoryState
	if err := c.Post(ctx, "/git/stash", req, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// GitStashApply applies (or pops) a stash.
func (c *Client) GitStashApply(ctx context.Context, req StashApplyRequest) (RepositoryState, error) {
	var out RepositoryState
	if err := c.Post(ctx, "/git/stash/apply", req, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func (c *Client) gitFileCommand(ctx context.Context, p string, req FileCommandRequest) (RepositoryState, error) {
	var out RepositoryState
	if err := c.Post(ctx, p, req, &out); err != nil {
		return nil, err
	}
	return out, nil
}
