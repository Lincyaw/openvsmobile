package github

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"testing"
	"time"
)

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
			_ = json.NewEncoder(w).Encode(map[string]any{"login": "octocat", "id": 7})
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
		t.Fatalf("getUser auth header = %q", userAuthHeaders[len(userAuthHeaders)-1])
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
