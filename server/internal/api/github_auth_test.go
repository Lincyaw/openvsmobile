package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	gitauth "github.com/Lincyaw/vscode-mobile/server/internal/github"
)

type fakeGitHubBackend struct {
	server *httptest.Server
}

func newFakeGitHubBackend(t *testing.T) *fakeGitHubBackend {
	backend := &fakeGitHubBackend{}
	backend.server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/login/device/code":
			_ = json.NewEncoder(w).Encode(gitauth.DeviceCodeResponse{
				DeviceCode:      "device-code",
				UserCode:        "ABCD-EFGH",
				VerificationURI: "https://github.com/login/device",
				ExpiresIn:       900,
				Interval:        5,
			})
		case "/login/oauth/access_token":
			_ = r.ParseForm()
			if r.PostForm.Get("grant_type") == "urn:ietf:params:oauth:grant-type:device_code" {
				switch r.PostForm.Get("device_code") {
				case "pending-code":
					_ = json.NewEncoder(w).Encode(gitauth.TokenResponse{Error: "authorization_pending"})
				case "deny-code":
					_ = json.NewEncoder(w).Encode(gitauth.TokenResponse{Error: "access_denied"})
				default:
					_ = json.NewEncoder(w).Encode(gitauth.TokenResponse{AccessToken: "access-1", RefreshToken: "refresh-1", ExpiresIn: 60, RefreshTokenExpiresIn: 3600})
				}
				return
			}
			if r.PostForm.Get("refresh_token") == "bad-refresh" {
				_ = json.NewEncoder(w).Encode(gitauth.TokenResponse{Error: "bad_refresh_token"})
				return
			}
			_ = json.NewEncoder(w).Encode(gitauth.TokenResponse{AccessToken: "access-2", RefreshToken: "refresh-2", ExpiresIn: 300, RefreshTokenExpiresIn: 7200})
		case "/api/v3/user":
			_ = json.NewEncoder(w).Encode(map[string]any{"login": "octocat", "id": 9})
		default:
			t.Fatalf("unexpected backend path %s", r.URL.Path)
		}
	}))
	return backend
}

func TestGitHubAuthDisabledService(t *testing.T) {
	ts, _, _ := newTestServer(t, "")
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/github/auth/status")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status code = %d, want %d", resp.StatusCode, http.StatusServiceUnavailable)
	}
	var payload map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatalf("Decode() error = %v", err)
	}
	if payload["error_code"] != "github_auth_disabled" {
		t.Fatalf("error_code = %v", payload["error_code"])
	}
}

func TestGitHubAuthHTTPFlow(t *testing.T) {
	backend := newFakeGitHubBackend(t)
	defer backend.server.Close()

	client := gitauth.NewClient(backend.server.Client())
	client.SetBaseURLFuncs(func(string) string { return backend.server.URL }, func(string) string { return backend.server.URL + "/api/v3" })
	store := gitauth.NewStore(t.TempDir() + "/github-auth.json")
	service := gitauth.NewService(client, store, "client-id", "github.enterprise.local", time.Minute)
	service.SetNow(func() time.Time { return time.Date(2026, 4, 20, 12, 0, 0, 0, time.UTC) })

	srv := NewServer(newMockFS(), nil, nil, "", nil, nil, service)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	postJSON := func(path string, body any) (*http.Response, map[string]any) {
		t.Helper()
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("Marshal() error = %v", err)
		}
		resp, err := http.Post(ts.URL+path, "application/json", bytes.NewReader(data))
		if err != nil {
			t.Fatalf("POST %s error = %v", path, err)
		}
		var payload map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
			resp.Body.Close()
			t.Fatalf("Decode(%s) error = %v", path, err)
		}
		resp.Body.Close()
		return resp, payload
	}

	resp, payload := postJSON("/github/auth/device/start", map[string]any{})
	if resp.StatusCode != http.StatusOK || payload["user_code"] != "ABCD-EFGH" || payload["github_host"] != "github.enterprise.local" {
		t.Fatalf("start response = %d %#v", resp.StatusCode, payload)
	}

	resp, payload = postJSON("/github/auth/device/poll", map[string]any{"device_code": "pending-code"})
	if resp.StatusCode != http.StatusOK || payload["status"] != "pending" {
		t.Fatalf("pending poll response = %d %#v", resp.StatusCode, payload)
	}

	resp, payload = postJSON("/github/auth/device/poll", map[string]any{"device_code": "authorized-code"})
	if resp.StatusCode != http.StatusOK || payload["status"] != "authorized" {
		t.Fatalf("authorized poll response = %d %#v", resp.StatusCode, payload)
	}
	auth, ok := payload["auth"].(map[string]any)
	if !ok || auth["account_login"] != "octocat" {
		t.Fatalf("authorized auth payload = %#v", payload["auth"])
	}

	resp, err := http.Get(ts.URL + "/github/auth/status")
	if err != nil {
		t.Fatal(err)
	}
	var statusPayload map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&statusPayload); err != nil {
		resp.Body.Close()
		t.Fatalf("Decode(status) error = %v", err)
	}
	resp.Body.Close()
	if statusPayload["access_token"] != nil || statusPayload["refresh_token"] != nil {
		t.Fatalf("status leaked tokens: %#v", statusPayload)
	}
	if statusPayload["account_login"] != "octocat" || statusPayload["github_host"] != "github.enterprise.local" {
		t.Fatalf("status payload = %#v", statusPayload)
	}

	resp, payload = postJSON("/github/auth/disconnect", map[string]any{})
	if resp.StatusCode != http.StatusOK || payload["disconnected"] != true {
		t.Fatalf("disconnect response = %d %#v", resp.StatusCode, payload)
	}
	resp, err = http.Get(ts.URL + "/github/auth/status")
	if err != nil {
		t.Fatal(err)
	}
	statusPayload = map[string]any{}
	if err := json.NewDecoder(resp.Body).Decode(&statusPayload); err != nil {
		resp.Body.Close()
		t.Fatalf("Decode(status after disconnect) error = %v", err)
	}
	resp.Body.Close()
	if statusPayload["authenticated"] != false {
		t.Fatalf("status after disconnect = %#v", statusPayload)
	}

	resp, payload = postJSON("/github/auth/device/poll", map[string]any{"device_code": "deny-code"})
	if resp.StatusCode != http.StatusOK || payload["status"] != "error" || payload["error_code"] != "access_denied" {
		t.Fatalf("error poll response = %d %#v", resp.StatusCode, payload)
	}
}

func TestGitHubAuthReauthErrorPayload(t *testing.T) {
	store := gitauth.NewStore(t.TempDir() + "/github-auth.json")
	now := time.Date(2026, 4, 20, 12, 0, 0, 0, time.UTC)
	if err := store.Save(gitauth.AuthRecord{GitHubHost: gitauth.DefaultHost, AccessToken: "stale", AccessTokenExpiresAt: now.Add(-time.Minute), RefreshToken: "bad-refresh", RefreshTokenExpiresAt: now.Add(time.Hour)}); err != nil {
		t.Fatalf("store.Save() error = %v", err)
	}
	backend := newFakeGitHubBackend(t)
	defer backend.server.Close()
	client := gitauth.NewClient(backend.server.Client())
	client.SetBaseURLFuncs(func(string) string { return backend.server.URL }, func(string) string { return backend.server.URL + "/api/v3" })
	service := gitauth.NewService(client, store, "client-id", gitauth.DefaultHost, time.Minute)
	service.SetNow(func() time.Time { return now })

	if _, err := service.EnsureFreshToken(context.Background(), gitauth.DefaultHost); !errors.Is(err, gitauth.ErrReauthRequired) {
		t.Fatalf("EnsureFreshToken() error = %v", err)
	}
	w := httptest.NewRecorder()
	writeGitHubAuthError(w, gitauth.ErrReauthRequired)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status code = %d, want %d", w.Code, http.StatusUnauthorized)
	}
	var payload map[string]any
	if err := json.NewDecoder(w.Body).Decode(&payload); err != nil {
		t.Fatalf("Decode() error = %v", err)
	}
	if payload["error_code"] != "reauth_required" {
		t.Fatalf("payload = %#v", payload)
	}
}
