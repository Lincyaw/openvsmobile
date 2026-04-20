package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	gitauth "github.com/Lincyaw/vscode-mobile/server/internal/github"
	"github.com/Lincyaw/vscode-mobile/server/internal/git"
	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
)

type repoContextServer struct {
	server    *httptest.Server
	repoDir   string
	nestedDir string
	filePath  string
}

func repoContextGitRun(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v failed: %v: %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func repoContextSetupRepo(t *testing.T, remoteURL string) (string, string, func()) {
	t.Helper()
	dir := t.TempDir()
	repoContextGitRun(t, dir, "init")
	repoContextGitRun(t, dir, "config", "user.email", "test@test.com")
	repoContextGitRun(t, dir, "config", "user.name", "Test User")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("hello\n"), 0o644); err != nil {
		t.Fatalf("write README: %v", err)
	}
	repoContextGitRun(t, dir, "add", "README.md")
	repoContextGitRun(t, dir, "commit", "-m", "initial commit")
	if remoteURL != "" {
		repoContextGitRun(t, dir, "remote", "add", "origin", remoteURL)
	}
	nested := filepath.Join(dir, "nested", "workspace")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("mkdir nested workspace: %v", err)
	}
	return dir, nested, func() {}
}

func newRepoContextServer(t *testing.T, remoteURL string, backend http.HandlerFunc) *repoContextServer {
	t.Helper()
	repoDir, nestedDir, cleanup := repoContextSetupRepo(t, remoteURL)
	t.Cleanup(cleanup)
	filePath := filepath.Join(repoDir, "pkg", "repo_context_test.txt")
	if err := os.MkdirAll(filepath.Dir(filePath), 0o755); err != nil {
		t.Fatalf("mkdir file dir: %v", err)
	}
	if err := os.WriteFile(filePath, []byte("hello\n"), 0o644); err != nil {
		t.Fatalf("write repo file: %v", err)
	}

	backendServer := httptest.NewTLSServer(backend)
	t.Cleanup(backendServer.Close)
	client := gitauth.NewClient(backendServer.Client())
	client.SetBaseURLFuncs(func(string) string { return backendServer.URL }, func(string) string { return backendServer.URL + "/api/v3" })
	store := gitauth.NewStore(filepath.Join(t.TempDir(), "github-auth.json"))
	service := gitauth.NewService(client, store, "client-id", gitauth.DefaultHost, time.Minute)
	now := time.Date(2026, 4, 20, 12, 0, 0, 0, time.UTC)
	service.SetNow(func() time.Time { return now })
	if err := store.Save(gitauth.AuthRecord{
		GitHubHost:            gitauth.DefaultHost,
		AccessToken:           "access-token",
		AccessTokenExpiresAt:  now.Add(30 * time.Minute),
		RefreshToken:          "refresh-token",
		RefreshTokenExpiresAt: now.Add(24 * time.Hour),
		AccountLogin:          "octocat",
		AccountID:             7,
	}); err != nil {
		t.Fatalf("store.Save() error = %v", err)
	}

	srv := NewServer(newMockFS(), nil, nil, "", git.NewGit(repoDir), terminal.NewManager(), nil, service)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return &repoContextServer{server: ts, repoDir: repoDir, nestedDir: nestedDir, filePath: filePath}
}

func repoContextGET(t *testing.T, baseURL, routePrefix, workDir string) (*http.Response, map[string]any) {
	t.Helper()
	queries := []string{
		"?path=" + url.QueryEscape(workDir),
		"?workDir=" + url.QueryEscape(workDir),
		"?workspaceRoot=" + url.QueryEscape(workDir),
		"",
	}
	var lastResp *http.Response
	var lastPayload map[string]any
	for _, query := range queries {
		resp, err := http.Get(baseURL + routePrefix + "/github/repos/current" + query)
		if err != nil {
			t.Fatalf("GET repo context error: %v", err)
		}
		payload := decodeMapResponse(t, resp)
		lastResp, lastPayload = resp, payload
		if resp.StatusCode != http.StatusBadRequest || payload["error_code"] != "invalid_request" {
			return resp, payload
		}
	}
	return lastResp, lastPayload
}

func repoContextResolveLocalFile(t *testing.T, baseURL, routePrefix, workDir, relPath string) (*http.Response, map[string]any) {
	t.Helper()
	candidates := []map[string]any{
		{"path": relPath, "workspace_path": workDir},
		{"relative_path": relPath, "workspace_path": workDir},
		{"path": relPath},
		{"relative_path": relPath},
		{"path": relPath, "workDir": workDir},
		{"relative_path": relPath, "workDir": workDir},
		{"path": relPath, "work_dir": workDir},
		{"relative_path": relPath, "work_dir": workDir},
	}
	var lastResp *http.Response
	var lastPayload map[string]any
	for _, payload := range candidates {
		body, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("Marshal() error = %v", err)
		}
		resp, err := http.Post(baseURL+routePrefix+"/github/resolve-local-file", "application/json", bytes.NewReader(body))
		if err != nil {
			t.Fatalf("POST resolve-local-file error: %v", err)
		}
		decoded := decodeMapResponse(t, resp)
		lastResp, lastPayload = resp, decoded
		if resp.StatusCode == http.StatusBadRequest && decoded["error_code"] == "invalid_request" && strings.Contains(strings.ToLower(asString(decoded["message"])), "unknown") {
			continue
		}
		return resp, decoded
	}
	return lastResp, lastPayload
}

func decodeMapResponse(t *testing.T, resp *http.Response) map[string]any {
	t.Helper()
	defer resp.Body.Close()
	var payload map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatalf("Decode() error = %v", err)
	}
	return payload
}

func asString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprintf("%v", v)
}

func requireRepoContextTuple(t *testing.T, payload map[string]any) {
	t.Helper()
	body, _ := json.Marshal(payload)
	text := string(body)
	for _, part := range []string{"github.com", "acme", "rocket"} {
		if !strings.Contains(text, part) {
			t.Fatalf("expected payload %s to contain %q", text, part)
		}
	}
	if strings.Contains(text, "access_token") || strings.Contains(text, "refresh_token") {
		t.Fatalf("payload leaked tokens: %s", text)
	}
}

func requireErrorCodeContains(t *testing.T, payload map[string]any, codes ...string) {
	t.Helper()
	body, _ := json.Marshal(payload)
	text := string(body)
	for _, code := range codes {
		if strings.Contains(text, code) {
			return
		}
	}
	t.Fatalf("expected payload %s to contain one of %v", text, codes)
}

func TestGitHubRepoContextCurrentRepoSupportsBothRoutePrefixes(t *testing.T) {
	rcs := newRepoContextServer(t, "https://github.com/acme/rocket.git", func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v3/repos/acme/rocket":
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket", "full_name": "acme/rocket", "private": true, "owner": map[string]any{"login": "acme"}})
		case "/api/v3/repos/acme/rocket/installation":
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 99})
		default:
			t.Fatalf("unexpected backend path %s", r.URL.Path)
		}
	})

	for _, prefix := range []string{"", "/api"} {
		resp, payload := repoContextGET(t, rcs.server.URL, prefix, rcs.nestedDir)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("prefix %q status = %d payload=%#v", prefix, resp.StatusCode, payload)
		}
		requireRepoContextTuple(t, payload)
	}
}

func TestGitHubRepoContextCurrentRepoReportsStructuredErrors(t *testing.T) {
	t.Run("non github remote", func(t *testing.T) {
		rcs := newRepoContextServer(t, "https://gitlab.com/acme/rocket.git", func(w http.ResponseWriter, r *http.Request) {
			t.Fatalf("backend should not be called for non-GitHub remote: %s", r.URL.Path)
		})
		resp, payload := repoContextGET(t, rcs.server.URL, "", rcs.nestedDir)
		if resp.StatusCode != http.StatusBadRequest && resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d payload=%#v", resp.StatusCode, payload)
		}
		requireErrorCodeContains(t, payload, "repo_not_github")
	})

	t.Run("repo access unavailable", func(t *testing.T) {
		rcs := newRepoContextServer(t, "git@github.com:acme/private-repo.git", func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/api/v3/repos/acme/private-repo" {
				t.Fatalf("unexpected backend path %s", r.URL.Path)
			}
			http.Error(w, "missing", http.StatusNotFound)
		})
		resp, payload := repoContextGET(t, rcs.server.URL, "", rcs.nestedDir)
		if resp.StatusCode != http.StatusBadGateway && resp.StatusCode != http.StatusNotFound && resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d payload=%#v", resp.StatusCode, payload)
		}
		requireErrorCodeContains(t, payload, "repo_access_unavailable")
	})

	t.Run("app not installed", func(t *testing.T) {
		rcs := newRepoContextServer(t, "https://github.com/acme/rocket.git", func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/api/v3/repos/acme/rocket":
				_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket", "full_name": "acme/rocket", "owner": map[string]any{"login": "acme"}})
			case "/api/v3/repos/acme/rocket/installation":
				http.Error(w, "missing installation", http.StatusNotFound)
			default:
				t.Fatalf("unexpected backend path %s", r.URL.Path)
			}
		})
		resp, payload := repoContextGET(t, rcs.server.URL, "", rcs.nestedDir)
		if resp.StatusCode != http.StatusBadGateway && resp.StatusCode != http.StatusNotFound && resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d payload=%#v", resp.StatusCode, payload)
		}
		requireErrorCodeContains(t, payload, "app_not_installed_for_repo")
	})
}

func TestGitHubResolveLocalFileHandlesExistingMissingAndEscapingPaths(t *testing.T) {
	rcs := newRepoContextServer(t, "https://github.com/acme/rocket.git", func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v3/repos/acme/rocket":
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket", "full_name": "acme/rocket", "owner": map[string]any{"login": "acme"}})
		case "/api/v3/repos/acme/rocket/installation":
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 99})
		default:
			t.Fatalf("unexpected backend path %s", r.URL.Path)
		}
	})

	for _, prefix := range []string{"", "/api"} {
		resp, payload := repoContextResolveLocalFile(t, rcs.server.URL, prefix, rcs.nestedDir, "pkg/repo_context_test.txt")
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("existing path prefix %q status = %d payload=%#v", prefix, resp.StatusCode, payload)
		}
		if path := asString(payload["local_path"]); path != rcs.filePath {
			if path := asString(payload["path"]); path != rcs.filePath {
				t.Fatalf("existing path payload = %#v want local path %q", payload, rcs.filePath)
			}
		}
		if payload["exists"] != true {
			t.Fatalf("existing path exists = %#v payload=%#v", payload["exists"], payload)
		}
	}

	resp, payload := repoContextResolveLocalFile(t, rcs.server.URL, "", rcs.nestedDir, "pkg/missing.txt")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("missing path status = %d payload=%#v", resp.StatusCode, payload)
	}
	if payload["exists"] != false {
		t.Fatalf("missing path exists = %#v payload=%#v", payload["exists"], payload)
	}
	missingPath := filepath.Join(rcs.repoDir, "pkg", "missing.txt")
	if path := asString(payload["local_path"]); path != missingPath {
		if path := asString(payload["path"]); path != missingPath {
			t.Fatalf("missing path payload = %#v want local path %q", payload, missingPath)
		}
	}

	resp, payload = repoContextResolveLocalFile(t, rcs.server.URL, "", rcs.nestedDir, "../secret.txt")
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("escaping path status = %d payload=%#v", resp.StatusCode, payload)
	}
	requireErrorCodeContains(t, payload, "invalid_path", "invalid_request")
}

func TestGitHubRepoContextCurrentRepoSupportsSSHRemote(t *testing.T) {
	rcs := newRepoContextServer(t, "git@github.com:acme/rocket.git", func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v3/repos/acme/rocket":
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket", "full_name": "acme/rocket", "owner": map[string]any{"login": "acme"}})
		case "/api/v3/repos/acme/rocket/installation":
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 77})
		default:
			t.Fatalf("unexpected backend path %s", r.URL.Path)
		}
	})

	resp, payload := repoContextGET(t, rcs.server.URL, "/api", rcs.nestedDir)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d payload=%#v", resp.StatusCode, payload)
	}
	requireRepoContextTuple(t, payload)
}
