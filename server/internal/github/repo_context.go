package github

import (
	"fmt"
	"net/url"
	"path"
	"strings"
)

type APIError struct {
	Host       string
	StatusCode int
	Message    string
}

func (e *APIError) Error() string {
	if e == nil {
		return ""
	}
	if e.Host == "" {
		return fmt.Sprintf("github api request failed: status=%d message=%s", e.StatusCode, e.Message)
	}
	return fmt.Sprintf("%s: github api request failed: status=%d message=%s", e.Host, e.StatusCode, e.Message)
}

func ParseRepositoryRemote(remoteName, remoteURL, repoRoot string) (*Repository, error) {
	remoteURL = strings.TrimSpace(remoteURL)
	if remoteURL == "" {
		return nil, fmt.Errorf("remote URL must not be empty")
	}

	host, repoPath, err := parseGitRemoteURL(remoteURL)
	if err != nil {
		return nil, err
	}
	repoPath = strings.Trim(repoPath, "/")
	parts := strings.Split(repoPath, "/")
	if len(parts) < 2 {
		return nil, fmt.Errorf("remote URL does not include owner and repository: %s", remoteURL)
	}

	owner := parts[len(parts)-2]
	name := strings.TrimSuffix(parts[len(parts)-1], ".git")
	if owner == "" || name == "" {
		return nil, fmt.Errorf("remote URL does not include owner and repository: %s", remoteURL)
	}

	return &Repository{
		GitHubHost: NormalizeHost(host),
		Owner:      owner,
		Name:       name,
		FullName:   owner + "/" + name,
		RemoteName: remoteName,
		RemoteURL:  remoteURL,
		RepoRoot:   repoRoot,
	}, nil
}

func parseGitRemoteURL(raw string) (string, string, error) {
	if strings.Contains(raw, "://") {
		parsed, err := url.Parse(raw)
		if err != nil {
			return "", "", fmt.Errorf("parse remote URL: %w", err)
		}
		if parsed.Host == "" {
			return "", "", fmt.Errorf("remote URL is missing a host: %s", raw)
		}
		return parsed.Host, strings.TrimPrefix(path.Clean(parsed.Path), "/"), nil
	}

	at := strings.LastIndex(raw, "@")
	colon := strings.LastIndex(raw, ":")
	if colon <= at {
		return "", "", fmt.Errorf("unsupported remote URL: %s", raw)
	}
	return raw[at+1 : colon], raw[colon+1:], nil
}
