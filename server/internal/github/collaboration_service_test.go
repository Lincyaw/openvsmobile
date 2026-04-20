package github

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	gitctx "github.com/Lincyaw/vscode-mobile/server/internal/git"
)

type collaborationServiceHarness struct {
	service       *Service
	git           *gitctx.Git
	server        *httptest.Server
	repoDir       string
	nestedDir     string
	tokenRequests []url.Values
}

func newCollaborationServiceHarness(t *testing.T, remoteURL string, handler func(*collaborationServiceHarness, http.ResponseWriter, *http.Request, []byte)) *collaborationServiceHarness {
	t.Helper()
	repoDir, nestedDir := collaborationSetupRepo(t, remoteURL)
	h := &collaborationServiceHarness{repoDir: repoDir, nestedDir: nestedDir, git: gitctx.NewGit(repoDir)}
	h.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := readJSONBody(r)
		if r.URL.Path == "/login/oauth/access_token" {
			_ = r.ParseForm()
			clone := url.Values{}
			for key, values := range r.PostForm {
				clone[key] = append([]string(nil), values...)
			}
			h.tokenRequests = append(h.tokenRequests, clone)
		}
		handler(h, w, r, body)
	}))
	t.Cleanup(h.server.Close)

	client := NewClient(h.server.Client())
	client.SetBaseURLFuncs(func(string) string { return h.server.URL }, func(string) string { return h.server.URL + "/api/v3" })
	store := NewStore(filepath.Join(t.TempDir(), "github-auth.json"))
	now := time.Date(2026, 4, 20, 12, 0, 0, 0, time.UTC)
	if err := store.Save(AuthRecord{
		GitHubHost:            DefaultHost,
		AccessToken:           "access-token",
		AccessTokenExpiresAt:  now.Add(30 * time.Minute),
		RefreshToken:          "refresh-token",
		RefreshTokenExpiresAt: now.Add(24 * time.Hour),
		AccountLogin:          "octocat",
		AccountID:             9,
	}); err != nil {
		t.Fatalf("store.Save() error = %v", err)
	}
	service := NewService(client, store, "client-id", DefaultHost, time.Minute)
	service.SetNow(func() time.Time { return now })
	h.service = service
	return h
}

func collaborationSetupRepo(t *testing.T, remoteURL string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	gitRun := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v failed: %v: %s", args, err, out)
		}
	}
	gitRun("init")
	gitRun("config", "user.email", "test@example.com")
	gitRun("config", "user.name", "Test User")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("hello\n"), 0o644); err != nil {
		t.Fatalf("write README.md: %v", err)
	}
	gitRun("add", "README.md")
	gitRun("commit", "-m", "initial")
	if remoteURL != "" {
		gitRun("remote", "add", "origin", remoteURL)
	}
	nested := filepath.Join(dir, "nested", "workspace")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("MkdirAll(%q): %v", nested, err)
	}
	return dir, nested
}

func readJSONBody(r *http.Request) ([]byte, error) {
	if r.Body == nil {
		return nil, nil
	}
	defer r.Body.Close()
	return io.ReadAll(r.Body)
}

func TestCollaborationServiceGetCurrentRepoAccountReusesFreshToken(t *testing.T) {
	h := newCollaborationServiceHarness(t, "https://github.com/acme/rocket.git", func(h *collaborationServiceHarness, w http.ResponseWriter, r *http.Request, body []byte) {
		switch r.URL.Path {
		case "/api/v3/repos/acme/rocket":
			if got := r.Header.Get("Authorization"); got != "Bearer access-token" {
				t.Fatalf("repo Authorization = %q", got)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket", "full_name": "acme/rocket", "owner": map[string]any{"login": "acme"}})
		case "/api/v3/repos/acme/rocket/installation":
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 101})
		case "/api/v3/user":
			if got := r.Header.Get("Authorization"); got != "Bearer access-token" {
				t.Fatalf("user Authorization = %q", got)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"login": "octocat", "id": 9, "avatar_url": "https://avatars.example/octocat"})
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	})

	account, repo, err := h.service.GetCurrentRepoAccount(context.Background(), h.git, h.nestedDir)
	if err != nil {
		t.Fatalf("GetCurrentRepoAccount() error = %v", err)
	}
	if len(h.tokenRequests) != 0 {
		t.Fatalf("expected no refresh token request, got %d", len(h.tokenRequests))
	}
	if repo == nil || repo.FullName != "acme/rocket" {
		t.Fatalf("repository = %#v", repo)
	}
	if account == nil || account.Login != "octocat" {
		t.Fatalf("account = %#v", account)
	}
}

func TestCollaborationServiceIssueFiltersDefaultWorkspaceRepo(t *testing.T) {
	var seenPath string
	var seenQuery url.Values
	h := newCollaborationServiceHarness(t, "https://github.com/acme/rocket.git", func(h *collaborationServiceHarness, w http.ResponseWriter, r *http.Request, body []byte) {
		switch r.URL.Path {
		case "/api/v3/repos/acme/rocket":
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket", "full_name": "acme/rocket", "owner": map[string]any{"login": "acme"}})
		case "/api/v3/repos/acme/rocket/installation":
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 101})
		case "/api/v3/repos/acme/rocket/issues":
			seenPath = r.URL.Path
			seenQuery = r.URL.Query()
			_ = json.NewEncoder(w).Encode([]map[string]any{{"number": 7, "title": "Issue title", "state": "open"}})
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	})

	issues, repo, err := h.service.ListCurrentRepoIssues(context.Background(), h.git, h.nestedDir, IssueListOptions{
		State:     "open",
		Assignee:  "octocat",
		Creator:   "octocat",
		Mentioned: "octocat",
		Page:      2,
		PerPage:   25,
	})
	if err != nil {
		t.Fatalf("ListCurrentRepoIssues() error = %v", err)
	}
	if repo == nil || repo.FullName != "acme/rocket" {
		t.Fatalf("repository = %#v", repo)
	}
	if len(issues) != 1 || issues[0].Number != 7 {
		t.Fatalf("issues = %#v", issues)
	}
	if seenPath != "/api/v3/repos/acme/rocket/issues" {
		t.Fatalf("issues path = %q", seenPath)
	}
	for key, want := range map[string]string{"state": "open", "assignee": "octocat", "creator": "octocat", "mentioned": "octocat", "page": "2", "per_page": "25"} {
		if got := seenQuery.Get(key); got != want {
			t.Fatalf("query[%q] = %q, want %q", key, got, want)
		}
	}
}

func TestCollaborationServicePullRequestsAndChecksAggregation(t *testing.T) {
	var listQuery url.Values
	h := newCollaborationServiceHarness(t, "https://github.com/acme/rocket.git", func(h *collaborationServiceHarness, w http.ResponseWriter, r *http.Request, body []byte) {
		switch r.URL.Path {
		case "/api/v3/repos/acme/rocket":
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket", "full_name": "acme/rocket", "owner": map[string]any{"login": "acme"}})
		case "/api/v3/repos/acme/rocket/installation":
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 101})
		case "/api/v3/repos/acme/rocket/pulls":
			listQuery = r.URL.Query()
			_ = json.NewEncoder(w).Encode([]map[string]any{{"number": 12, "title": "PR title", "state": "open", "head": map[string]any{"sha": "deadbeef"}}})
		case "/api/v3/repos/acme/rocket/pulls/12":
			_ = json.NewEncoder(w).Encode(map[string]any{"number": 12, "title": "PR title", "state": "open", "head": map[string]any{"sha": "deadbeef"}})
		case "/api/v3/repos/acme/rocket/commits/deadbeef/status":
			_ = json.NewEncoder(w).Encode(map[string]any{"state": "failure", "total_count": 2, "statuses": []map[string]any{{"context": "ci/unit", "state": "success"}, {"context": "ci/e2e", "state": "failure"}}})
		case "/api/v3/repos/acme/rocket/commits/deadbeef/check-runs":
			_ = json.NewEncoder(w).Encode(map[string]any{"total_count": 2, "check_runs": []map[string]any{{"name": "lint", "status": "completed", "conclusion": "success"}, {"name": "integration", "status": "completed", "conclusion": "failure"}}})
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	})

	pulls, _, err := h.service.ListCurrentRepoPullRequests(context.Background(), h.git, h.nestedDir, PullRequestListOptions{State: "closed", Base: "main", Head: "feature", PerPage: 10})
	if err != nil {
		t.Fatalf("ListCurrentRepoPullRequests() error = %v", err)
	}
	if len(pulls) != 1 || pulls[0].Number != 12 {
		t.Fatalf("pulls = %#v", pulls)
	}
	for key, want := range map[string]string{"state": "closed", "base": "main", "head": "feature", "per_page": "10"} {
		if got := listQuery.Get(key); got != want {
			t.Fatalf("query[%q] = %q, want %q", key, got, want)
		}
	}

	pull, repo, err := h.service.GetCurrentRepoPullRequest(context.Background(), h.git, h.nestedDir, 12)
	if err != nil {
		t.Fatalf("GetCurrentRepoPullRequest() error = %v", err)
	}
	if repo == nil || repo.FullName != "acme/rocket" {
		t.Fatalf("repository = %#v", repo)
	}
	if pull == nil || pull.Checks == nil {
		t.Fatalf("pull = %#v", pull)
	}
	if pull.Checks.State != "failure" || pull.Checks.TotalCount != 4 || pull.Checks.FailureCount != 2 || pull.Checks.SuccessCount != 2 {
		t.Fatalf("checks = %#v", pull.Checks)
	}
}

func TestCollaborationServicePullRequestFiltersUseRepoScopedSearch(t *testing.T) {
	for _, tc := range []struct {
		name      string
		filter    CollaborationFilter
		wantTerms []string
	}{
		{
			name:      "assigned to me",
			filter:    CollaborationFilter{AssignedToMe: true},
			wantTerms: []string{"repo:acme/rocket", "is:pr", "is:open", "assignee:octocat"},
		},
		{
			name:      "created by me",
			filter:    CollaborationFilter{CreatedByMe: true, State: "closed"},
			wantTerms: []string{"repo:acme/rocket", "is:pr", "is:closed", "author:octocat"},
		},
		{
			name:      "mixed assigned and created",
			filter:    CollaborationFilter{AssignedToMe: true, CreatedByMe: true},
			wantTerms: []string{"repo:acme/rocket", "is:pr", "is:open", "assignee:octocat", "author:octocat"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var seenPath string
			var seenQuery url.Values
			h := newCollaborationServiceHarness(t, "https://github.com/acme/rocket.git", func(h *collaborationServiceHarness, w http.ResponseWriter, r *http.Request, body []byte) {
				switch r.URL.Path {
				case "/api/v3/repos/acme/rocket":
					_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket", "full_name": "acme/rocket", "owner": map[string]any{"login": "acme"}})
				case "/api/v3/repos/acme/rocket/installation":
					_ = json.NewEncoder(w).Encode(map[string]any{"id": 101})
				case "/api/v3/search/issues":
					seenPath = r.URL.Path
					seenQuery = r.URL.Query()
					_ = json.NewEncoder(w).Encode(map[string]any{
						"total_count": 1,
						"items":       []map[string]any{{"number": 12, "title": "PR title", "state": "open"}},
					})
				default:
					t.Fatalf("unexpected path %s", r.URL.Path)
				}
			})

			pulls, err := h.service.ListPullRequests(context.Background(), h.nestedDir, tc.filter)
			if err != nil {
				t.Fatalf("ListPullRequests() error = %v", err)
			}
			if len(pulls) != 1 || pulls[0].Number != 12 {
				t.Fatalf("pulls = %#v", pulls)
			}
			if seenPath != "/api/v3/search/issues" {
				t.Fatalf("filters should force repo-scoped search, got path %q query=%v", seenPath, seenQuery)
			}
			q := seenQuery.Get("q")
			for _, want := range tc.wantTerms {
				if !strings.Contains(q, want) {
					t.Fatalf("search query missing %q in %q", want, q)
				}
			}
		})
	}
}

func TestCollaborationServiceWriteBodiesMatchContract(t *testing.T) {
	var issueCommentBody map[string]any
	var prCommentBody map[string]any
	var reviewBody map[string]any
	h := newCollaborationServiceHarness(t, "https://github.com/acme/rocket.git", func(h *collaborationServiceHarness, w http.ResponseWriter, r *http.Request, body []byte) {
		switch r.URL.Path {
		case "/api/v3/repos/acme/rocket":
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket", "full_name": "acme/rocket", "owner": map[string]any{"login": "acme"}})
		case "/api/v3/repos/acme/rocket/installation":
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 101})
		case "/api/v3/repos/acme/rocket/issues/7/comments":
			_ = json.Unmarshal(body, &issueCommentBody)
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 701, "body": issueCommentBody["body"]})
		case "/api/v3/repos/acme/rocket/pulls/12/comments":
			_ = json.Unmarshal(body, &prCommentBody)
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 1201, "body": prCommentBody["body"], "path": prCommentBody["path"], "line": prCommentBody["line"]})
		case "/api/v3/repos/acme/rocket/pulls/12/reviews":
			_ = json.Unmarshal(body, &reviewBody)
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 1202, "body": reviewBody["body"], "state": reviewBody["event"]})
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	})

	if _, _, err := h.service.CreateCurrentRepoIssueComment(context.Background(), h.git, h.nestedDir, 7, CreateIssueCommentInput{Body: "Issue comment from test"}); err != nil {
		t.Fatalf("CreateCurrentRepoIssueComment() error = %v", err)
	}
	if issueCommentBody["body"] != "Issue comment from test" {
		t.Fatalf("issue comment body = %#v", issueCommentBody)
	}

	if _, _, err := h.service.CreateCurrentRepoPullRequestComment(context.Background(), h.git, h.nestedDir, 12, CreatePullRequestCommentInput{Body: "Inline note", Path: "server/main.go", CommitID: "deadbeef", Side: "RIGHT", Line: 27}); err != nil {
		t.Fatalf("CreateCurrentRepoPullRequestComment() error = %v", err)
	}
	for key, want := range map[string]any{"body": "Inline note", "path": "server/main.go", "commit_id": "deadbeef", "line": float64(27)} {
		if prCommentBody[key] != want {
			t.Fatalf("pull request comment body[%q] = %#v body=%#v", key, prCommentBody[key], prCommentBody)
		}
	}

	if _, _, err := h.service.CreateCurrentRepoPullRequestReview(context.Background(), h.git, h.nestedDir, 12, CreatePullRequestReviewInput{Body: "Looks good", Event: "APPROVE", CommitID: "deadbeef", Comments: []PullRequestReviewDraftComment{{Body: "nit", Path: "server/main.go", Line: 8, Side: "RIGHT"}}}); err != nil {
		t.Fatalf("CreateCurrentRepoPullRequestReview() error = %v", err)
	}
	if reviewBody["body"] != "Looks good" || reviewBody["event"] != "APPROVE" || reviewBody["commit_id"] != "deadbeef" {
		t.Fatalf("review body = %#v", reviewBody)
	}
	comments, ok := reviewBody["comments"].([]any)
	if !ok || len(comments) != 1 {
		t.Fatalf("review comments = %#v", reviewBody["comments"])
	}
}

func TestCollaborationServiceErrorTranslation(t *testing.T) {
	t.Run("not authenticated", func(t *testing.T) {
		repoDir, nestedDir := collaborationSetupRepo(t, "https://github.com/acme/rocket.git")
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}))
		defer server.Close()
		client := NewClient(server.Client())
		client.SetBaseURLFuncs(func(string) string { return server.URL }, func(string) string { return server.URL + "/api/v3" })
		service := NewService(client, NewStore(filepath.Join(t.TempDir(), "github-auth.json")), "client-id", DefaultHost, time.Minute)
		_, _, err := service.GetCurrentRepoAccount(context.Background(), gitctx.NewGit(repoDir), nestedDir)
		if !errors.Is(err, ErrNotAuthenticated) {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("reauth required", func(t *testing.T) {
		h := newCollaborationServiceHarness(t, "https://github.com/acme/rocket.git", func(h *collaborationServiceHarness, w http.ResponseWriter, r *http.Request, body []byte) {
			if r.URL.Path != "/login/oauth/access_token" {
				t.Fatalf("unexpected path %s", r.URL.Path)
			}
			_ = json.NewEncoder(w).Encode(TokenResponse{Error: "bad_refresh_token"})
		})
		now := time.Date(2026, 4, 20, 12, 0, 0, 0, time.UTC)
		if err := h.service.store.Save(AuthRecord{GitHubHost: DefaultHost, AccessToken: "stale", AccessTokenExpiresAt: now.Add(-time.Minute), RefreshToken: "bad-refresh", RefreshTokenExpiresAt: now.Add(time.Hour)}); err != nil {
			t.Fatalf("store.Save() error = %v", err)
		}
		_, _, err := h.service.GetCurrentRepoAccount(context.Background(), h.git, h.nestedDir)
		if !errors.Is(err, ErrReauthRequired) {
			t.Fatalf("error = %v", err)
		}
	})

	for _, tc := range []struct {
		name   string
		status int
		path   string
		call   func(*testing.T, *collaborationServiceHarness) error
		assert func(*testing.T, error)
	}{
		{
			name:   "repo access unavailable on 403",
			status: http.StatusForbidden,
			path:   "/api/v3/repos/acme/rocket/pulls/12",
			call: func(t *testing.T, h *collaborationServiceHarness) error {
				_, _, err := h.service.GetCurrentRepoPullRequest(context.Background(), h.git, h.nestedDir, 12)
				return err
			},
			assert: func(t *testing.T, err error) {
				if !errors.Is(err, ErrRepoAccessUnavailable) {
					t.Fatalf("error = %v", err)
				}
			},
		},
		{
			name:   "not found on 404",
			status: http.StatusNotFound,
			path:   "/api/v3/repos/acme/rocket/issues/404",
			call: func(t *testing.T, h *collaborationServiceHarness) error {
				_, _, err := h.service.GetCurrentRepoIssue(context.Background(), h.git, h.nestedDir, 404)
				return err
			},
			assert: func(t *testing.T, err error) {
				if !errors.Is(err, ErrNotFound) {
					t.Fatalf("error = %v", err)
				}
			},
		},
		{
			name:   "invalid request on 422",
			status: http.StatusUnprocessableEntity,
			path:   "/api/v3/repos/acme/rocket/pulls/12/comments",
			call: func(t *testing.T, h *collaborationServiceHarness) error {
				_, _, err := h.service.CreateCurrentRepoPullRequestComment(context.Background(), h.git, h.nestedDir, 12, CreatePullRequestCommentInput{Body: "bad", Path: "server/main.go", CommitID: "deadbeef", Line: 9})
				return err
			},
			assert: func(t *testing.T, err error) {
				if !errors.Is(err, ErrInvalidRequest) {
					t.Fatalf("error = %v", err)
				}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newCollaborationServiceHarness(t, "https://github.com/acme/rocket.git", func(h *collaborationServiceHarness, w http.ResponseWriter, r *http.Request, body []byte) {
				switch r.URL.Path {
				case "/api/v3/repos/acme/rocket":
					_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket", "full_name": "acme/rocket", "owner": map[string]any{"login": "acme"}})
				case "/api/v3/repos/acme/rocket/installation":
					_ = json.NewEncoder(w).Encode(map[string]any{"id": 101})
				case tc.path:
					http.Error(w, "backend failure", tc.status)
				default:
					t.Fatalf("unexpected path %s", r.URL.Path)
				}
			})
			err := tc.call(t, h)
			if err == nil {
				t.Fatalf("expected error")
			}
			tc.assert(t, err)
		})
	}

	t.Run("non github workspace maps to invalid request", func(t *testing.T) {
		h := newCollaborationServiceHarness(t, "https://gitlab.com/acme/rocket.git", func(h *collaborationServiceHarness, w http.ResponseWriter, r *http.Request, body []byte) {
			t.Fatalf("backend should not be called: %s", r.URL.Path)
		})
		_, _, err := h.service.GetCurrentRepoAccount(context.Background(), h.git, h.nestedDir)
		if !errors.Is(err, ErrInvalidRequest) {
			t.Fatalf("error = %v", err)
		}
	})
}
