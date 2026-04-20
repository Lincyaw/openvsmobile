package git

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
)

const RepoContextStatusRepoNotGitHub = "repo_not_github"

var (
	ErrNotRepository = errors.New("not a git repository")
	ErrNoRemote      = errors.New("git remote not configured")
	ErrRepoNotGitHub = errors.New("repo remote is not github")
)

type RemoteInfo struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

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

func (g *Git) RepoRoot(path string) (string, error) {
	dir := g.resolveDir(path)
	if dir == "" {
		dir = "."
	}
	absDir, err := filepath.Abs(dir)
	if err != nil {
		return "", fmt.Errorf("resolve workspace path: %w", err)
	}
	out, err := g.run("-C", absDir, "rev-parse", "--show-toplevel")
	if err != nil {
		if strings.Contains(err.Error(), "not a git repository") {
			return "", ErrNotRepository
		}
		return "", err
	}
	return strings.TrimSpace(out), nil
}

func (g *Git) CurrentRemote(path string) (*RemoteInfo, error) {
	dir := g.resolveDir(path)
	if dir == "" {
		dir = "."
	}
	out, err := g.run("-C", dir, "remote")
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

	remoteURL, err := g.run("-C", dir, "remote", "get-url", name)
	if err != nil {
		return nil, err
	}
	return &RemoteInfo{Name: name, URL: strings.TrimSpace(remoteURL)}, nil
}

func (g *Git) RepoContext(path string) (*RepoContext, error) {
	workspacePath := g.resolveDir(path)
	if workspacePath == "" {
		workspacePath = "."
	}
	absWorkspacePath, err := filepath.Abs(workspacePath)
	if err != nil {
		return nil, fmt.Errorf("resolve workspace path: %w", err)
	}

	repoRoot, err := g.RepoRoot(absWorkspacePath)
	if err != nil {
		return &RepoContext{WorkspacePath: absWorkspacePath}, err
	}
	context := &RepoContext{WorkspacePath: absWorkspacePath, RepoRoot: repoRoot}

	remote, err := g.CurrentRemote(repoRoot)
	if err != nil {
		return context, err
	}
	context.RemoteName = remote.Name
	context.RemoteURL = remote.URL

	host, owner, name, err := ParseGitHubRemoteURL(remote.URL)
	if err != nil {
		if errors.Is(err, ErrRepoNotGitHub) {
			context.Status = RepoContextStatusRepoNotGitHub
			context.Message = err.Error()
			return context, err
		}
		return context, err
	}

	context.GitHubHost = host
	context.Owner = owner
	context.Name = name
	context.FullName = owner + "/" + name
	return context, nil
}

func (g *Git) ResolveRepoContext(path string) (*RepoContext, error) {
	return g.RepoContext(path)
}

func ParseGitHubRemoteURL(raw string) (host, owner, repo string, err error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", "", "", fmt.Errorf("remote URL must not be empty")
	}

	if strings.Contains(trimmed, "://") {
		return parseGitHubHTTPRemote(trimmed)
	}
	if strings.Contains(trimmed, "@") && strings.Contains(trimmed, ":") {
		return parseGitHubSSHRemote(trimmed)
	}
	return "", "", "", ErrRepoNotGitHub
}

func parseGitHubHTTPRemote(raw string) (string, string, string, error) {
	lower := strings.ToLower(raw)
	if !strings.HasPrefix(lower, "https://") && !strings.HasPrefix(lower, "http://") {
		return "", "", "", ErrRepoNotGitHub
	}
	noScheme := raw[strings.Index(raw, "://")+3:]
	slash := strings.Index(noScheme, "/")
	if slash < 0 {
		return "", "", "", fmt.Errorf("remote URL is malformed: %s", raw)
	}
	return splitGitHubHostPath(strings.ToLower(strings.TrimSpace(noScheme[:slash])), strings.Trim(noScheme[slash+1:], "/"))
}

func parseGitHubSSHRemote(raw string) (string, string, string, error) {
	at := strings.Index(raw, "@")
	colon := strings.Index(raw, ":")
	if at < 0 || colon < 0 || colon <= at {
		return "", "", "", fmt.Errorf("remote URL is malformed: %s", raw)
	}
	return splitGitHubHostPath(strings.ToLower(strings.TrimSpace(raw[at+1:colon])), strings.Trim(raw[colon+1:], "/"))
}

func splitGitHubHostPath(host, repoPath string) (string, string, string, error) {
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
