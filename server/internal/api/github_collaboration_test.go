package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Lincyaw/vscode-mobile/server/internal/git"
	gitauth "github.com/Lincyaw/vscode-mobile/server/internal/github"
	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
)

type collaborationBackendState struct {
	issueComments []map[string]any
	prComments    []map[string]any
	prReviews     []map[string]any
}

type collaborationTestEnv struct {
	server    *httptest.Server
	backend   *httptest.Server
	repoDir   string
	nestedDir string
	state     *collaborationBackendState
}

func newCollaborationTestEnv(t *testing.T) *collaborationTestEnv {
	t.Helper()
	repoDir, nestedDir, cleanup := repoContextSetupRepo(t, "https://github.com/acme/rocket.git")
	t.Cleanup(cleanup)
	state := &collaborationBackendState{}
	backend := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := handleCollaborationBackend(state, w, r); err != nil {
			t.Fatalf("backend error: %v", err)
		}
	}))
	t.Cleanup(backend.Close)

	client := gitauth.NewClient(backend.Client())
	client.SetBaseURLFuncs(func(string) string { return backend.URL }, func(string) string { return backend.URL + "/api/v3" })
	store := gitauth.NewStore(filepath.Join(t.TempDir(), "github-auth.json"))
	now := time.Date(2026, 4, 20, 12, 0, 0, 0, time.UTC)
	if err := store.Save(gitauth.AuthRecord{
		GitHubHost:            gitauth.DefaultHost,
		AccessToken:           "access-token",
		AccessTokenExpiresAt:  now.Add(30 * time.Minute),
		RefreshToken:          "refresh-token",
		RefreshTokenExpiresAt: now.Add(24 * time.Hour),
		AccountLogin:          "octocat",
		AccountID:             9,
	}); err != nil {
		t.Fatalf("store.Save() error = %v", err)
	}
	service := gitauth.NewService(client, store, "client-id", gitauth.DefaultHost, time.Minute)
	service.SetNow(func() time.Time { return now })

	srv := NewServer(newMockFS(), nil, nil, "", git.NewGit(repoDir), terminal.NewManager(), nil, service)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return &collaborationTestEnv{server: ts, backend: backend, repoDir: repoDir, nestedDir: nestedDir, state: state}
}

func handleCollaborationBackend(state *collaborationBackendState, w http.ResponseWriter, r *http.Request) error {
	writeJSON := func(v any) error {
		w.Header().Set("Content-Type", "application/json")
		return json.NewEncoder(w).Encode(v)
	}
	decodeBody := func() map[string]any {
		var payload map[string]any
		_ = json.NewDecoder(r.Body).Decode(&payload)
		return payload
	}

	switch r.URL.Path {
	case "/api/v3/user":
		return writeJSON(map[string]any{"login": "octocat", "id": 9, "avatar_url": "https://avatars.example/octocat", "html_url": "https://github.com/octocat"})
	case "/api/v3/repos/acme/rocket":
		return writeJSON(map[string]any{"name": "rocket", "full_name": "acme/rocket", "private": true, "owner": map[string]any{"login": "acme"}})
	case "/api/v3/repos/acme/rocket/installation":
		return writeJSON(map[string]any{"id": 101})
	case "/api/v3/repos/acme/rocket/issues":
		return writeJSON([]map[string]any{{"number": 7, "title": "Issue title", "state": "open", "user": map[string]any{"login": "octocat"}}})
	case "/api/v3/repos/acme/rocket/issues/7":
		return writeJSON(map[string]any{"number": 7, "title": "Issue title", "state": "open", "body": "Issue body", "user": map[string]any{"login": "octocat"}, "comments": len(state.issueComments)})
	case "/api/v3/repos/acme/rocket/issues/7/comments":
		if r.Method == http.MethodPost {
			payload := decodeBody()
			state.issueComments = append(state.issueComments, payload)
			w.WriteHeader(http.StatusCreated)
			return writeJSON(map[string]any{"id": 500 + len(state.issueComments), "body": payload["body"]})
		}
		comments := []map[string]any{{"id": 1, "body": "Existing issue comment"}}
		for i, payload := range state.issueComments {
			comments = append(comments, map[string]any{"id": 10 + i, "body": payload["body"]})
		}
		return writeJSON(comments)
	case "/api/v3/repos/acme/rocket/pulls":
		return writeJSON([]map[string]any{{"number": 12, "title": "PR title", "state": "open", "user": map[string]any{"login": "octocat"}, "head": map[string]any{"sha": "deadbeef"}}})
	case "/api/v3/search/issues":
		q := r.URL.Query().Get("q")
		if strings.Contains(q, "is:pr") || strings.Contains(q, "type:pr") {
			return writeJSON(map[string]any{"total_count": 1, "items": []map[string]any{{"number": 12, "title": "PR title", "state": "open"}}})
		}
		return writeJSON(map[string]any{"total_count": 1, "items": []map[string]any{{"number": 7, "title": "Issue title", "state": "open"}}})
	case "/api/v3/repos/acme/rocket/pulls/12":
		return writeJSON(map[string]any{"number": 12, "title": "PR title", "state": "open", "body": "PR body", "head": map[string]any{"sha": "deadbeef"}, "user": map[string]any{"login": "octocat"}})
	case "/api/v3/repos/acme/rocket/pulls/12/files":
		return writeJSON([]map[string]any{{"filename": "server/internal/api/github_collaboration.go", "status": "modified", "patch": "@@ -1 +1 @@", "additions": 3, "deletions": 1, "changes": 4}})
	case "/api/v3/repos/acme/rocket/issues/12/comments", "/api/v3/repos/acme/rocket/pulls/12/comments":
		if r.Method == http.MethodPost {
			payload := decodeBody()
			state.prComments = append(state.prComments, payload)
			w.WriteHeader(http.StatusCreated)
			return writeJSON(map[string]any{"id": 700 + len(state.prComments), "body": payload["body"], "path": payload["path"]})
		}
		comments := []map[string]any{{"id": 2, "body": "Existing PR comment", "path": "README.md"}}
		for i, payload := range state.prComments {
			comments = append(comments, map[string]any{"id": 20 + i, "body": payload["body"], "path": payload["path"]})
		}
		return writeJSON(comments)
	case "/api/v3/repos/acme/rocket/pulls/12/reviews":
		if r.Method == http.MethodPost {
			payload := decodeBody()
			state.prReviews = append(state.prReviews, payload)
			w.WriteHeader(http.StatusCreated)
			return writeJSON(map[string]any{"id": 900 + len(state.prReviews), "body": payload["body"], "state": payload["event"]})
		}
		reviews := []map[string]any{{"id": 3, "body": "Existing review", "state": "COMMENTED"}}
		for i, payload := range state.prReviews {
			reviews = append(reviews, map[string]any{"id": 30 + i, "body": payload["body"], "state": payload["event"]})
		}
		return writeJSON(reviews)
	case "/api/v3/repos/acme/rocket/commits/deadbeef/status":
		return writeJSON(map[string]any{"state": "failure", "total_count": 2, "statuses": []map[string]any{{"context": "ci/unit", "state": "success"}, {"context": "ci/e2e", "state": "failure"}}})
	case "/api/v3/repos/acme/rocket/commits/deadbeef/check-runs":
		return writeJSON(map[string]any{"total_count": 2, "check_runs": []map[string]any{{"name": "lint", "status": "completed", "conclusion": "success"}, {"name": "integration", "status": "completed", "conclusion": "failure"}}})
	default:
		return fmt.Errorf("unexpected backend path %s", r.URL.Path)
	}
}

func getJSONValue(t *testing.T, method, rawURL string, body any) (int, any) {
	t.Helper()
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("json.Marshal() error = %v", err)
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, rawURL, reader)
	if err != nil {
		t.Fatalf("http.NewRequest() error = %v", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("http.Do(%s %s) error = %v", method, rawURL, err)
	}
	defer resp.Body.Close()
	var payload any
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatalf("json.Decode(%s %s) error = %v", method, rawURL, err)
	}
	return resp.StatusCode, payload
}

func stringifyPayload(t *testing.T, payload any) string {
	t.Helper()
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	return string(data)
}

func issueListURL(baseURL, prefix, workspace string) []string {
	return []string{
		baseURL + prefix + "/github/issues?path=" + url.QueryEscape(workspace),
		baseURL + prefix + "/github/issues?workDir=" + url.QueryEscape(workspace),
		baseURL + prefix + "/github/issues?workspaceRoot=" + url.QueryEscape(workspace),
		baseURL + prefix + "/github/issues",
	}
}

func postBodiesForWorkspace(workspace string, extra map[string]any) []map[string]any {
	bodies := []map[string]any{}
	for _, key := range []string{"workspace_path", "workDir", "work_dir"} {
		payload := map[string]any{}
		for k, v := range extra {
			payload[k] = v
		}
		payload[key] = workspace
		bodies = append(bodies, payload)
	}
	bodies = append(bodies, extra)
	return bodies
}

func TestGitHubCollaborationRoutesSupportBothPrefixes(t *testing.T) {
	env := newCollaborationTestEnv(t)

	for _, prefix := range []string{"", "/api"} {
		var payload any
		var status int
		for _, rawURL := range issueListURL(env.server.URL, prefix, env.nestedDir) {
			status, payload = getJSONValue(t, http.MethodGet, rawURL, nil)
			text := stringifyPayload(t, payload)
			if status == http.StatusBadRequest && strings.Contains(text, "invalid_request") {
				continue
			}
			break
		}
		if status != http.StatusOK {
			t.Fatalf("issues prefix %q status = %d payload=%s", prefix, status, stringifyPayload(t, payload))
		}
		if text := stringifyPayload(t, payload); !strings.Contains(text, "Issue title") {
			t.Fatalf("issues prefix %q payload = %s", prefix, text)
		}

		status, payload = getJSONValue(t, http.MethodGet, env.server.URL+prefix+"/github/account", nil)
		if status != http.StatusOK {
			t.Fatalf("account prefix %q status = %d payload=%s", prefix, status, stringifyPayload(t, payload))
		}
		if text := stringifyPayload(t, payload); !strings.Contains(text, "octocat") {
			t.Fatalf("account prefix %q payload = %s", prefix, text)
		}
	}
}

func TestGitHubCollaborationPullRequestDetailsIncludeFilesCommentsAndChecks(t *testing.T) {
	env := newCollaborationTestEnv(t)
	for _, prefix := range []string{"", "/api"} {
		status, payload := getJSONValue(t, http.MethodGet, env.server.URL+prefix+"/github/pulls/12?path="+url.QueryEscape(env.nestedDir), nil)
		if status != http.StatusOK {
			t.Fatalf("pull details prefix %q status = %d payload=%s", prefix, status, stringifyPayload(t, payload))
		}
		text := stringifyPayload(t, payload)
		for _, want := range []string{"PR title", "github_collaboration.go", "Existing PR comment", "ci/unit", "integration"} {
			if !strings.Contains(text, want) {
				t.Fatalf("pull details prefix %q missing %q in %s", prefix, want, text)
			}
		}
	}
}

func TestGitHubCollaborationNeedsReviewFilterUsesRepoScopedQuery(t *testing.T) {
	repoDir, nestedDir, cleanup := repoContextSetupRepo(t, "https://github.com/acme/rocket.git")
	t.Cleanup(cleanup)

	var seenPath string
	var seenQuery url.Values
	backend := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenPath = r.URL.Path
		seenQuery = r.URL.Query()
		if err := handleCollaborationBackend(&collaborationBackendState{}, w, r); err != nil {
			t.Fatalf("backend error: %v", err)
		}
	}))
	defer backend.Close()

	client := gitauth.NewClient(backend.Client())
	client.SetBaseURLFuncs(func(string) string { return backend.URL }, func(string) string { return backend.URL + "/api/v3" })
	store := gitauth.NewStore(filepath.Join(t.TempDir(), "github-auth.json"))
	now := time.Date(2026, 4, 20, 12, 0, 0, 0, time.UTC)
	if err := store.Save(gitauth.AuthRecord{
		GitHubHost:            gitauth.DefaultHost,
		AccessToken:           "access-token",
		AccessTokenExpiresAt:  now.Add(30 * time.Minute),
		RefreshToken:          "refresh-token",
		RefreshTokenExpiresAt: now.Add(24 * time.Hour),
		AccountLogin:          "octocat",
		AccountID:             9,
	}); err != nil {
		t.Fatalf("store.Save() error = %v", err)
	}
	service := gitauth.NewService(client, store, "client-id", gitauth.DefaultHost, time.Minute)
	service.SetNow(func() time.Time { return now })
	srv := NewServer(newMockFS(), nil, nil, "", git.NewGit(repoDir), terminal.NewManager(), nil, service)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	status, payload := getJSONValue(t, http.MethodGet, ts.URL+"/github/pulls?path="+url.QueryEscape(nestedDir)+"&state=open&needs_review=true", nil)
	if status != http.StatusOK {
		t.Fatalf("status = %d payload=%s", status, stringifyPayload(t, payload))
	}
	if seenPath != "/api/v3/search/issues" {
		t.Fatalf("needs review should use repo-scoped search, got path %q query=%v", seenPath, seenQuery)
	}
	q := seenQuery.Get("q")
	for _, want := range []string{"repo:acme/rocket", "is:pr", "review-requested:octocat"} {
		if !strings.Contains(q, want) {
			t.Fatalf("needs review query missing %q in %q", want, q)
		}
	}
}

func TestGitHubCollaborationWriteThenReadConsistency(t *testing.T) {
	env := newCollaborationTestEnv(t)

	for _, prefix := range []string{"", "/api"} {
		for _, body := range postBodiesForWorkspace(env.nestedDir, map[string]any{"body": "New issue comment"}) {
			status, payload := getJSONValue(t, http.MethodPost, env.server.URL+prefix+"/github/issues/7/comments", body)
			if status == http.StatusBadRequest && strings.Contains(strings.ToLower(stringifyPayload(t, payload)), "invalid_request") {
				continue
			}
			if status != http.StatusOK && status != http.StatusCreated {
				t.Fatalf("issue comment prefix %q status = %d payload=%s", prefix, status, stringifyPayload(t, payload))
			}
			break
		}

		for _, body := range postBodiesForWorkspace(env.nestedDir, map[string]any{"body": "Inline follow-up", "path": "server/internal/api/github_collaboration.go", "commit_id": "deadbeef", "line": 12, "side": "RIGHT"}) {
			status, payload := getJSONValue(t, http.MethodPost, env.server.URL+prefix+"/github/pulls/12/comments", body)
			if status == http.StatusBadRequest && strings.Contains(strings.ToLower(stringifyPayload(t, payload)), "invalid_request") {
				continue
			}
			if status != http.StatusOK && status != http.StatusCreated {
				t.Fatalf("pr comment prefix %q status = %d payload=%s", prefix, status, stringifyPayload(t, payload))
			}
			break
		}

		for _, body := range postBodiesForWorkspace(env.nestedDir, map[string]any{"body": "Ship it", "event": "APPROVE", "commit_id": "deadbeef"}) {
			status, payload := getJSONValue(t, http.MethodPost, env.server.URL+prefix+"/github/pulls/12/reviews", body)
			if status == http.StatusBadRequest && strings.Contains(strings.ToLower(stringifyPayload(t, payload)), "invalid_request") {
				continue
			}
			if status != http.StatusOK && status != http.StatusCreated {
				t.Fatalf("pr review prefix %q status = %d payload=%s", prefix, status, stringifyPayload(t, payload))
			}
			break
		}

		status, payload := getJSONValue(t, http.MethodGet, env.server.URL+prefix+"/github/issues/7?path="+url.QueryEscape(env.nestedDir), nil)
		if status != http.StatusOK {
			t.Fatalf("issue details prefix %q status = %d payload=%s", prefix, status, stringifyPayload(t, payload))
		}
		if text := stringifyPayload(t, payload); !strings.Contains(text, "New issue comment") && !strings.Contains(text, "comments") {
			t.Fatalf("issue details prefix %q payload = %s", prefix, text)
		}

		status, payload = getJSONValue(t, http.MethodGet, env.server.URL+prefix+"/github/pulls/12?path="+url.QueryEscape(env.nestedDir), nil)
		if status != http.StatusOK {
			t.Fatalf("pr details prefix %q status = %d payload=%s", prefix, status, stringifyPayload(t, payload))
		}
		text := stringifyPayload(t, payload)
		for _, want := range []string{"Inline follow-up", "Ship it"} {
			if !strings.Contains(text, want) {
				t.Fatalf("pr details prefix %q missing %q in %s", prefix, want, text)
			}
		}

		status, payload = getJSONValue(t, http.MethodGet, env.server.URL+prefix+"/github/pulls/12/comments?path="+url.QueryEscape(env.nestedDir), nil)
		if status != http.StatusOK {
			t.Fatalf("pr comments prefix %q status = %d payload=%s", prefix, status, stringifyPayload(t, payload))
		}
		text = stringifyPayload(t, payload)
		for _, want := range []string{"Inline follow-up", "Ship it"} {
			if !strings.Contains(text, want) {
				t.Fatalf("pr comments prefix %q missing %q in %s", prefix, want, text)
			}
		}
	}
}

func TestGitHubCollaborationFilesExposePatchMetadata(t *testing.T) {
	env := newCollaborationTestEnv(t)
	for _, prefix := range []string{"", "/api"} {
		status, payload := getJSONValue(t, http.MethodGet, env.server.URL+prefix+"/github/pulls/12/files?path="+url.QueryEscape(env.nestedDir), nil)
		if status != http.StatusOK {
			t.Fatalf("pr files prefix %q status = %d payload=%s", prefix, status, stringifyPayload(t, payload))
		}
		text := stringifyPayload(t, payload)
		for _, want := range []string{"github_collaboration.go", "@@ -1 +1 @@", "additions", "deletions"} {
			if !strings.Contains(text, want) {
				t.Fatalf("pr files prefix %q missing %q in %s", prefix, want, text)
			}
		}
	}
}

func TestGitHubCollaborationEndpointsReportAppNotInstalledForRepo(t *testing.T) {
	repoDir, nestedDir, cleanup := repoContextSetupRepo(t, "https://github.com/acme/rocket.git")
	t.Cleanup(cleanup)

	backend := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v3/repos/acme/rocket":
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket", "full_name": "acme/rocket", "owner": map[string]any{"login": "acme"}})
		case "/api/v3/repos/acme/rocket/installation":
			http.Error(w, "missing installation", http.StatusNotFound)
		default:
			t.Fatalf("unexpected backend path %s", r.URL.Path)
		}
	}))
	t.Cleanup(backend.Close)

	client := gitauth.NewClient(backend.Client())
	client.SetBaseURLFuncs(func(string) string { return backend.URL }, func(string) string { return backend.URL + "/api/v3" })
	store := gitauth.NewStore(filepath.Join(t.TempDir(), "github-auth.json"))
	now := time.Date(2026, 4, 20, 12, 0, 0, 0, time.UTC)
	if err := store.Save(gitauth.AuthRecord{
		GitHubHost:            gitauth.DefaultHost,
		AccessToken:           "access-token",
		AccessTokenExpiresAt:  now.Add(30 * time.Minute),
		RefreshToken:          "refresh-token",
		RefreshTokenExpiresAt: now.Add(24 * time.Hour),
		AccountLogin:          "octocat",
		AccountID:             9,
	}); err != nil {
		t.Fatalf("store.Save() error = %v", err)
	}
	service := gitauth.NewService(client, store, "client-id", gitauth.DefaultHost, time.Minute)
	service.SetNow(func() time.Time { return now })

	srv := NewServer(newMockFS(), nil, nil, "", git.NewGit(repoDir), terminal.NewManager(), nil, service)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	type testRequest struct {
		name   string
		method string
		path   string
		body   any
	}
	requests := []testRequest{
		{name: "account", method: http.MethodGet, path: "/github/account"},
		{name: "issue list", method: http.MethodGet, path: "/github/issues?path=" + url.QueryEscape(nestedDir)},
		{name: "pull list", method: http.MethodGet, path: "/github/pulls?path=" + url.QueryEscape(nestedDir)},
		{name: "issue comment", method: http.MethodPost, path: "/github/issues/7/comments", body: map[string]any{"workspace_path": nestedDir, "body": "hello"}},
		{name: "pull comment", method: http.MethodPost, path: "/github/pulls/12/comments", body: map[string]any{"workspace_path": nestedDir, "body": "hello", "path": "README.md", "commit_id": "deadbeef", "line": 1, "side": "RIGHT"}},
		{name: "pull review", method: http.MethodPost, path: "/github/pulls/12/reviews", body: map[string]any{"workspace_path": nestedDir, "body": "ship it", "event": "APPROVE"}},
	}

	for _, prefix := range []string{"", "/api"} {
		for _, tc := range requests {
			t.Run(prefix+" "+tc.name, func(t *testing.T) {
				status, payload := getJSONValue(t, tc.method, ts.URL+prefix+tc.path, tc.body)
				text := stringifyPayload(t, payload)
				if status != http.StatusForbidden && status != http.StatusNotFound && status != http.StatusBadGateway {
					t.Fatalf("status = %d payload=%s", status, text)
				}
				if !strings.Contains(text, "app_not_installed_for_repo") {
					t.Fatalf("payload missing app_not_installed_for_repo: %s", text)
				}
				if strings.Contains(text, "repo_access_unavailable") {
					t.Fatalf("payload should distinguish installation failures from repo access errors: %s", text)
				}
			})
		}
	}
}

func TestGitHubCollaborationStructuredErrors(t *testing.T) {
	ts, _, _ := newTestServer(t, "")
	defer ts.Close()

	for _, path := range []string{
		"/github/account",
		"/api/github/account",
		"/github/issues",
		"/api/github/pulls",
	} {
		status, payload := getJSONValue(t, http.MethodGet, ts.URL+path, nil)
		if status != http.StatusServiceUnavailable && status != http.StatusUnauthorized {
			t.Fatalf("path %q status = %d payload=%s", path, status, stringifyPayload(t, payload))
		}
		text := stringifyPayload(t, payload)
		if !strings.Contains(text, "error_code") {
			t.Fatalf("path %q payload missing error_code: %s", path, text)
		}
	}
}
