package github

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newRepoProbeService(t *testing.T, handler http.HandlerFunc) *Service {
	t.Helper()
	server := httptest.NewTLSServer(handler)
	t.Cleanup(server.Close)
	client := NewClient(server.Client())
	client.SetBaseURLFuncs(func(string) string { return server.URL }, func(string) string { return server.URL + "/api/v3" })
	store := NewStore(filepath.Join(t.TempDir(), "github-auth.json"))
	service := NewService(client, store, "client-id", DefaultHost, time.Minute)
	now := time.Date(2026, 4, 20, 12, 0, 0, 0, time.UTC)
	service.SetNow(func() time.Time { return now })
	if err := store.Save(AuthRecord{
		GitHubHost:            DefaultHost,
		AccessToken:           "access-token",
		AccessTokenExpiresAt:  now.Add(30 * time.Minute),
		RefreshToken:          "refresh-token",
		RefreshTokenExpiresAt: now.Add(24 * time.Hour),
		AccountLogin:          "octocat",
		AccountID:             7,
	}); err != nil {
		t.Fatalf("store.Save() error = %v", err)
	}
	return service
}

func TestServiceRepositoryProbeSuccess(t *testing.T) {
	var authHeaders []string
	var paths []string
	service := newRepoProbeService(t, func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		authHeaders = append(authHeaders, r.Header.Get("Authorization"))
		switch r.URL.Path {
		case "/api/v3/repos/acme/rocket":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"name":      "rocket",
				"full_name": "acme/rocket",
				"private":   true,
				"owner": map[string]any{
					"login": "acme",
				},
			})
		case "/api/v3/repos/acme/rocket/installation":
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 42})
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	})

	result, err := service.ProbeRepository(context.Background(), &Repository{GitHubHost: DefaultHost, Owner: "acme", Name: "rocket", FullName: "acme/rocket"})
	if err != nil {
		t.Fatalf("ProbeRepository() error = %v", err)
	}
	if result.Status != RepoStatusOK {
		t.Fatalf("ProbeRepository() status = %q result=%#v", result.Status, result)
	}
	if result.Repository == nil || result.Repository.Owner != "acme" || result.Repository.Name != "rocket" {
		t.Fatalf("ProbeRepository() result = %#v", result)
	}
	if len(paths) == 0 || authHeaders[0] != "Bearer access-token" {
		t.Fatalf("auth headers = %v paths = %v", authHeaders, paths)
	}
	if !containsString(paths, "/api/v3/repos/acme/rocket") || !containsString(paths, "/api/v3/repos/acme/rocket/installation") {
		t.Fatalf("expected repo + installation probes, got %v", paths)
	}
}

func TestGetRepoDecodesNestedOwnerLoginPayload(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v3/repos/acme/rocket" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"name":      "rocket",
			"full_name": "acme/rocket",
			"private":   true,
			"owner": map[string]any{
				"login": "acme",
			},
		})
	}))
	defer server.Close()

	client := NewClient(server.Client())
	client.SetBaseURLFuncs(func(string) string { return server.URL }, func(string) string { return server.URL + "/api/v3" })

	repo, err := client.GetRepo(context.Background(), DefaultHost, "acme", "rocket", "token")
	if err != nil {
		t.Fatalf("GetRepo() error = %v", err)
	}
	if repo.Owner != "acme" || repo.Name != "rocket" || repo.FullName != "acme/rocket" {
		t.Fatalf("GetRepo() repo = %#v", repo)
	}
}

func TestServiceRepositoryProbeMapsRepoAccessUnavailable(t *testing.T) {
	service := newRepoProbeService(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v3/repos/acme/private-repo" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		http.Error(w, "missing", http.StatusNotFound)
	})

	result, err := service.ProbeRepository(context.Background(), &Repository{GitHubHost: DefaultHost, Owner: "acme", Name: "private-repo", FullName: "acme/private-repo"})
	if err != nil {
		t.Fatalf("ProbeRepository() error = %v", err)
	}
	if result.Status != RepoStatusRepoAccessUnavailable || result.ErrorCode != RepoStatusRepoAccessUnavailable {
		t.Fatalf("ProbeRepository() result = %#v", result)
	}
}

func TestServiceRepositoryProbeMapsAppNotInstalled(t *testing.T) {
	service := newRepoProbeService(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v3/repos/acme/rocket":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"name":      "rocket",
				"full_name": "acme/rocket",
				"owner": map[string]any{
					"login": "acme",
				},
			})
		case "/api/v3/repos/acme/rocket/installation":
			http.Error(w, "missing installation", http.StatusNotFound)
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	})

	result, err := service.ProbeRepository(context.Background(), &Repository{GitHubHost: DefaultHost, Owner: "acme", Name: "rocket", FullName: "acme/rocket"})
	if err != nil {
		t.Fatalf("ProbeRepository() error = %v", err)
	}
	if result.Status != RepoStatusAppNotInstalled || result.ErrorCode != RepoStatusAppNotInstalled {
		t.Fatalf("ProbeRepository() result = %#v", result)
	}
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func TestParseRepositoryRemoteSupportsHTTPSAndSSH(t *testing.T) {
	for _, tc := range []struct {
		name      string
		remoteURL string
		host      string
		owner     string
		repo      string
	}{
		{name: "https", remoteURL: "https://github.com/acme/rocket.git", host: "github.com", owner: "acme", repo: "rocket"},
		{name: "ssh", remoteURL: "git@github.com:acme/rocket.git", host: "github.com", owner: "acme", repo: "rocket"},
		{name: "enterprise https", remoteURL: "https://github.enterprise.local/acme/rocket.git", host: "github.enterprise.local", owner: "acme", repo: "rocket"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			repo, err := ParseRepositoryRemote("origin", tc.remoteURL, "/tmp/work")
			if err != nil {
				t.Fatalf("ParseRepositoryRemote() error = %v", err)
			}
			if repo.GitHubHost != tc.host || repo.Owner != tc.owner || repo.Name != tc.repo {
				t.Fatalf("parsed repo = %#v", repo)
			}
		})
	}
}

func TestGetRepoEscapesOwnerAndRepoSegments(t *testing.T) {
	var gotPath string
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.EscapedPath()
		_ = json.NewEncoder(w).Encode(map[string]any{"name": "rocket/core", "owner": map[string]any{"login": "acme/tools"}})
	}))
	defer server.Close()

	client := NewClient(server.Client())
	client.SetBaseURLFuncs(func(string) string { return server.URL }, func(string) string { return server.URL + "/api/v3" })
	repo, err := client.GetRepo(context.Background(), DefaultHost, "acme/tools", "rocket/core", "token")
	if err != nil {
		t.Fatalf("GetRepo() error = %v", err)
	}
	if !strings.Contains(gotPath, "/api/v3/repos/acme%2Ftools/rocket%2Fcore") {
		t.Fatalf("escaped path = %q", gotPath)
	}
	if repo.Owner != "acme/tools" || repo.Name != "rocket/core" {
		t.Fatalf("parsed repo = %#v", repo)
	}
}

func TestServiceRepositoryProbeRefreshesExpiredTokenBeforeAccessChecks(t *testing.T) {
	var tokenRequests []url.Values
	var authHeaders []string
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/login/oauth/access_token":
			_ = r.ParseForm()
			clone := url.Values{}
			for key, values := range r.PostForm {
				clone[key] = append([]string(nil), values...)
			}
			tokenRequests = append(tokenRequests, clone)
			_ = json.NewEncoder(w).Encode(TokenResponse{AccessToken: "fresh-access", RefreshToken: "fresh-refresh", ExpiresIn: 300, RefreshTokenExpiresIn: 3600})
		case "/api/v3/repos/acme/rocket":
			authHeaders = append(authHeaders, r.Header.Get("Authorization"))
			_ = json.NewEncoder(w).Encode(map[string]any{
				"name":      "rocket",
				"full_name": "acme/rocket",
				"owner": map[string]any{
					"login": "acme",
				},
			})
		case "/api/v3/repos/acme/rocket/installation":
			authHeaders = append(authHeaders, r.Header.Get("Authorization"))
			_ = json.NewEncoder(w).Encode(map[string]any{"id": 88})
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()

	client := NewClient(server.Client())
	client.SetBaseURLFuncs(func(string) string { return server.URL }, func(string) string { return server.URL + "/api/v3" })
	store := NewStore(filepath.Join(t.TempDir(), "github-auth.json"))
	service := NewService(client, store, "client-id", DefaultHost, time.Minute)
	now := time.Date(2026, 4, 20, 12, 0, 0, 0, time.UTC)
	service.SetNow(func() time.Time { return now })
	if err := store.Save(AuthRecord{GitHubHost: DefaultHost, AccessToken: "stale-access", AccessTokenExpiresAt: now.Add(-time.Minute), RefreshToken: "stale-refresh", RefreshTokenExpiresAt: now.Add(time.Hour)}); err != nil {
		t.Fatalf("store.Save() error = %v", err)
	}

	result, err := service.ProbeRepository(context.Background(), &Repository{GitHubHost: DefaultHost, Owner: "acme", Name: "rocket", FullName: "acme/rocket"})
	if err != nil {
		t.Fatalf("ProbeRepository() error = %v", err)
	}
	if result.Status != RepoStatusOK {
		t.Fatalf("ProbeRepository() result = %#v", result)
	}
	if len(tokenRequests) == 0 {
		t.Fatalf("expected refresh token request before repo probe")
	}
	for _, header := range authHeaders {
		if header != "Bearer fresh-access" {
			t.Fatalf("authorization header = %q, want Bearer fresh-access", header)
		}
	}
}

func TestServiceStartPollAndRefresh(t *testing.T) {
	var tokenRequests []url.Values
	var userAuthHeaders []string
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/login/device/code":
			_ = json.NewEncoder(w).Encode(DeviceCodeResponse{
				DeviceCode:      "device-code",
				UserCode:        "ABCD-EFGH",
				VerificationURI: "https://github.com/login/device",
				ExpiresIn:       900,
				Interval:        5,
			})
		case "/login/oauth/access_token":
			_ = r.ParseForm()
			clone := url.Values{}
			for key, values := range r.PostForm {
				clone[key] = append([]string(nil), values...)
			}
			tokenRequests = append(tokenRequests, clone)
			grantType := r.PostForm.Get("grant_type")
			switch grantType {
			case "urn:ietf:params:oauth:grant-type:device_code":
				if r.PostForm.Get("device_code") == "pending-code" {
					_ = json.NewEncoder(w).Encode(TokenResponse{Error: "authorization_pending"})
					return
				}
				if r.PostForm.Get("device_code") == "denied-code" {
					_ = json.NewEncoder(w).Encode(TokenResponse{Error: "access_denied"})
					return
				}
				_ = json.NewEncoder(w).Encode(TokenResponse{
					AccessToken:           "access-1",
					RefreshToken:          "refresh-1",
					ExpiresIn:             60,
					RefreshTokenExpiresIn: 3600,
				})
			case "refresh_token":
				if r.PostForm.Get("refresh_token") == "bad-refresh" {
					_ = json.NewEncoder(w).Encode(TokenResponse{Error: "bad_refresh_token"})
					return
				}
				_ = json.NewEncoder(w).Encode(TokenResponse{
					AccessToken:           "access-2",
					RefreshToken:          "refresh-2",
					ExpiresIn:             300,
					RefreshTokenExpiresIn: 7200,
				})
			default:
				t.Fatalf("unexpected grant_type %q", grantType)
			}
		case "/api/v3/user":
			userAuthHeaders = append(userAuthHeaders, r.Header.Get("Authorization"))
			_ = json.NewEncoder(w).Encode(User{Login: "octocat", ID: 7})
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()

	client := NewClient(server.Client())
	client.SetBaseURLFuncs(func(string) string { return server.URL }, func(string) string { return server.URL + "/api/v3" })
	store := NewStore(filepath.Join(t.TempDir(), "github-auth.json"))
	service := NewService(client, store, "client-id", "enterprise.example.com", 2*time.Minute)
	baseTime := time.Date(2026, 4, 20, 10, 0, 0, 0, time.UTC)
	service.SetNow(func() time.Time { return baseTime })

	start, err := service.StartDeviceFlow(context.Background(), "")
	if err != nil {
		t.Fatalf("StartDeviceFlow() error = %v", err)
	}
	if start.DeviceCode != "device-code" || start.UserCode != "ABCD-EFGH" {
		t.Fatalf("unexpected start response: %#v", start)
	}
	if service.ResolveHost("") != "enterprise.example.com" {
		t.Fatalf("ResolveHost() = %q", service.ResolveHost(""))
	}

	poll, err := service.PollDeviceFlow(context.Background(), "", "pending-code")
	if err != nil {
		t.Fatalf("PollDeviceFlow(pending) error = %v", err)
	}
	if poll.Status != "pending" {
		t.Fatalf("pending poll status = %q", poll.Status)
	}

	poll, err = service.PollDeviceFlow(context.Background(), "", "authorized-code")
	if err != nil {
		t.Fatalf("PollDeviceFlow(authorized) error = %v", err)
	}
	if poll.Status != "authorized" || poll.Auth == nil || poll.Auth.AccountLogin != "octocat" {
		t.Fatalf("authorized poll = %#v", poll)
	}
	stored, err := store.Load("enterprise.example.com")
	if err != nil {
		t.Fatalf("store.Load() error = %v", err)
	}
	if stored == nil || stored.AccessToken != "access-1" || stored.RefreshToken != "refresh-1" || stored.AccountID != 7 {
		t.Fatalf("stored record = %#v", stored)
	}

	service.SetNow(func() time.Time { return baseTime.Add(59 * time.Second) })
	refreshed, err := service.EnsureFreshToken(context.Background(), "")
	if err != nil {
		t.Fatalf("EnsureFreshToken() error = %v", err)
	}
	if refreshed.AccessToken != "access-2" || refreshed.RefreshToken != "refresh-2" {
		t.Fatalf("refreshed record = %#v", refreshed)
	}
	if userAuthHeaders[len(userAuthHeaders)-1] != "Bearer access-1" {
		t.Fatalf("GetUser auth header = %q", userAuthHeaders[len(userAuthHeaders)-1])
	}
	if len(tokenRequests) < 3 {
		t.Fatalf("expected at least 3 token requests, got %d", len(tokenRequests))
	}
	if tokenRequests[0].Get("client_id") != "client-id" {
		t.Fatalf("client_id missing from token request: %#v", tokenRequests[0])
	}
}

func TestServicePollErrorAndReauth(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/login/oauth/access_token":
			_ = r.ParseForm()
			if r.PostForm.Get("grant_type") == "urn:ietf:params:oauth:grant-type:device_code" {
				_ = json.NewEncoder(w).Encode(TokenResponse{Error: "access_denied"})
				return
			}
			_ = json.NewEncoder(w).Encode(TokenResponse{Error: "bad_refresh_token"})
		case "/api/v3/user":
			t.Fatalf("user endpoint should not be called on error")
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer server.Close()

	client := NewClient(server.Client())
	client.SetBaseURLFuncs(func(string) string { return server.URL }, func(string) string { return server.URL + "/api/v3" })
	store := NewStore(filepath.Join(t.TempDir(), "github-auth.json"))
	service := NewService(client, store, "client-id", DefaultHost, time.Minute)
	service.SetNow(func() time.Time { return time.Date(2026, 4, 20, 10, 0, 0, 0, time.UTC) })

	poll, err := service.PollDeviceFlow(context.Background(), "github.com", "denied-code")
	if err != nil {
		t.Fatalf("PollDeviceFlow(denied) error = %v", err)
	}
	if poll.Status != "error" || poll.ErrorCode != "access_denied" {
		t.Fatalf("denied poll = %#v", poll)
	}

	record := AuthRecord{
		GitHubHost:            DefaultHost,
		AccessToken:           "stale-access",
		AccessTokenExpiresAt:  service.now().Add(-time.Minute),
		RefreshToken:          "bad-refresh",
		RefreshTokenExpiresAt: service.now().Add(time.Hour),
	}
	if err := store.Save(record); err != nil {
		t.Fatalf("store.Save() error = %v", err)
	}
	if _, err := service.EnsureFreshToken(context.Background(), DefaultHost); !errors.Is(err, ErrReauthRequired) {
		t.Fatalf("EnsureFreshToken() error = %v, want %v", err, ErrReauthRequired)
	}
}
