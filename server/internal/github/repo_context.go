package github

import (
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
)

// RepoContextStatusRepoNotGitHub identifies a repository whose remote is not
// hosted on GitHub.
const RepoContextStatusRepoNotGitHub = "repo_not_github"

// Git context errors. These mirror the errors previously exported from
// internal/git which has been removed; only the github auth flow consumes them
// today, so keeping them here keeps the dependency surface small.
// ErrRepoNotGitHub is defined alongside the other github errors in types.go.
var (
	ErrNotRepository = errors.New("not a git repository")
	ErrNoRemote      = errors.New("git remote not configured")
)

// RemoteInfo describes a single git remote configured on the repository.
type RemoteInfo struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

// RepoContext captures the workspace + repository details that the GitHub auth
// flow needs in order to probe a workspace's authentication state.
type RepoContext struct {
	Status        string `json:"status,omitempty"`
	WorkspacePath string `json:"workspace_path,omitempty"`
	GitHubHost    string `json:"github_host,omitempty"`
	Owner         string `json:"owner,omitempty"`
	Name          string `json:"name,omitempty"`
	FullName      string `json:"full_name,omitempty"`
	RemoteName    string `json:"remote_name,omitempty"`
	RemoteURL     string `json:"remote_url,omitempty"`
	RepoRoot      string `json:"repo_root,omitempty"`
	Message       string `json:"message,omitempty"`
}

// RepoLocator inspects the local git repository at a given workspace path. It
// is exposed as an interface so callers can substitute a fake implementation
// (e.g. one backed by the openvsmobile-bridge) for tests or future refactors.
type RepoLocator interface {
	ResolveRepoContext(path string) (*RepoContext, error)
}

// LocalRepoLocator implements RepoLocator by shelling out to the local git
// binary. The github auth code is the only caller of this code path; the
// bridge-backed git endpoints do not use it.
type LocalRepoLocator struct{}

// ResolveRepoContext implements RepoLocator.
func (LocalRepoLocator) ResolveRepoContext(path string) (*RepoContext, error) {
	return resolveRepoContext(path)
}

func resolveRepoContext(workspacePath string) (*RepoContext, error) {
	if workspacePath == "" {
		workspacePath = "."
	}
	abs, err := filepath.Abs(workspacePath)
	if err != nil {
		return nil, fmt.Errorf("resolve workspace path: %w", err)
	}
	repoRoot, err := repoRoot(abs)
	if err != nil {
		return &RepoContext{WorkspacePath: abs}, err
	}
	ctx := &RepoContext{WorkspacePath: abs, RepoRoot: repoRoot}

	remote, err := currentRemote(repoRoot)
	if err != nil {
		return ctx, err
	}
	ctx.RemoteName = remote.Name
	ctx.RemoteURL = remote.URL

	host, owner, name, err := ParseGitHubRemoteURL(remote.URL)
	if err != nil {
		if errors.Is(err, ErrRepoNotGitHub) {
			ctx.Status = RepoContextStatusRepoNotGitHub
			ctx.Message = err.Error()
			return ctx, err
		}
		return ctx, err
	}
	ctx.GitHubHost = host
	ctx.Owner = owner
	ctx.Name = name
	ctx.FullName = owner + "/" + name
	return ctx, nil
}

func repoRoot(dir string) (string, error) {
	out, err := runGit(dir, "rev-parse", "--show-toplevel")
	if err != nil {
		if strings.Contains(err.Error(), "not a git repository") {
			return "", ErrNotRepository
		}
		return "", err
	}
	return strings.TrimSpace(out), nil
}

func currentRemote(dir string) (*RemoteInfo, error) {
	out, err := runGit(dir, "remote")
	if err != nil {
		return nil, err
	}

	var remotes []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			remotes = append(remotes, line)
		}
	}
	if len(remotes) == 0 {
		return nil, ErrNoRemote
	}

	name := remotes[0]
	for _, candidate := range remotes {
		if candidate == "origin" {
			name = candidate
			break
		}
	}

	urlOut, err := runGit(dir, "remote", "get-url", name)
	if err != nil {
		return nil, err
	}
	return &RemoteInfo{Name: name, URL: strings.TrimSpace(urlOut)}, nil
}

func runGit(dir string, args ...string) (string, error) {
	full := append([]string{"-C", dir}, args...)
	cmd := exec.Command("git", full...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// ParseGitHubRemoteURL extracts (host, owner, repo) from an HTTPS or SSH git
// remote URL.
func ParseGitHubRemoteURL(raw string) (host, owner, repo string, err error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", "", "", fmt.Errorf("remote URL must not be empty")
	}

	if strings.Contains(trimmed, "://") {
		return parseHTTPRemote(trimmed)
	}
	if strings.Contains(trimmed, "@") && strings.Contains(trimmed, ":") {
		return parseSSHRemote(trimmed)
	}
	return "", "", "", ErrRepoNotGitHub
}

func parseHTTPRemote(raw string) (string, string, string, error) {
	lower := strings.ToLower(raw)
	if !strings.HasPrefix(lower, "https://") && !strings.HasPrefix(lower, "http://") {
		return "", "", "", ErrRepoNotGitHub
	}
	noScheme := raw[strings.Index(raw, "://")+3:]
	slash := strings.Index(noScheme, "/")
	if slash < 0 {
		return "", "", "", fmt.Errorf("remote URL is malformed: %s", raw)
	}
	return splitHostPath(strings.ToLower(strings.TrimSpace(noScheme[:slash])), strings.Trim(noScheme[slash+1:], "/"))
}

func parseSSHRemote(raw string) (string, string, string, error) {
	at := strings.Index(raw, "@")
	colon := strings.Index(raw, ":")
	if at < 0 || colon < 0 || colon <= at {
		return "", "", "", fmt.Errorf("remote URL is malformed: %s", raw)
	}
	return splitHostPath(strings.ToLower(strings.TrimSpace(raw[at+1:colon])), strings.Trim(raw[colon+1:], "/"))
}

func splitHostPath(host, repoPath string) (string, string, string, error) {
	if !looksLikeGitHubHost(host) {
		return "", "", "", ErrRepoNotGitHub
	}
	parts := strings.Split(repoPath, "/")
	if len(parts) < 2 {
		return "", "", "", fmt.Errorf("remote URL does not include owner and repository: %s", repoPath)
	}
	owner := strings.TrimSpace(parts[len(parts)-2])
	repo := strings.TrimSuffix(strings.TrimSpace(parts[len(parts)-1]), ".git")
	if owner == "" || repo == "" {
		return "", "", "", fmt.Errorf("remote URL does not include owner and repository: %s", repoPath)
	}
	return host, owner, repo, nil
}

func looksLikeGitHubHost(host string) bool {
	return host == "github.com" || strings.Contains(host, "github.")
}
