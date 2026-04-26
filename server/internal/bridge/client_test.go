package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeRuntimeInfoForTest(t *testing.T, info RuntimeInfo) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "bridge-runtime.json")
	data, err := json.Marshal(info)
	if err != nil {
		t.Fatalf("marshal runtime info: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write runtime info: %v", err)
	}
	return path
}

func newTestClient(t *testing.T, handler http.HandlerFunc) (*Client, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)

	u, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse server URL: %v", err)
	}
	host := u.Hostname()
	port := 0
	if _, err := fmtSScan(u.Port(), &port); err != nil {
		t.Fatalf("parse port: %v", err)
	}

	infoPath := writeRuntimeInfoForTest(t, RuntimeInfo{
		Host:  host,
		Port:  port,
		Token: "test-token",
	})
	return NewClientWithPath(infoPath), server
}

// fmtSScan is a tiny shim around fmt.Sscanf to keep the helper compact.
func fmtSScan(s string, i *int) (int, error) {
	return jsonNumberToInt(s, i)
}

func jsonNumberToInt(s string, dst *int) (int, error) {
	if s == "" {
		return 0, errors.New("empty port")
	}
	v := 0
	for _, ch := range s {
		if ch < '0' || ch > '9' {
			return 0, errors.New("invalid port: " + s)
		}
		v = v*10 + int(ch-'0')
	}
	*dst = v
	return 1, nil
}

func TestClientForwardsAuthorizationHeader(t *testing.T) {
	var seenAuth string
	client, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		seenAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})

	var out map[string]any
	if err := client.Get(context.Background(), "/healthz", nil, &out); err != nil {
		t.Fatalf("Get returned error: %v", err)
	}
	if seenAuth != "Bearer test-token" {
		t.Fatalf("expected Authorization header, got %q", seenAuth)
	}
}

func TestClientReturnsBridgeUnavailableWhenInfoMissing(t *testing.T) {
	client := NewClientWithPath(filepath.Join(t.TempDir(), "missing.json"))
	err := client.Get(context.Background(), "/healthz", nil, nil)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, ErrBridgeUnavailable) {
		t.Fatalf("expected ErrBridgeUnavailable, got %v", err)
	}
}

func TestClientDecodesErrorResponse(t *testing.T) {
	client, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"invalid_request","detail":"path required"}`))
	})

	err := client.Get(context.Background(), "/something", nil, nil)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	var bridgeErr *Error
	if !errors.As(err, &bridgeErr) {
		t.Fatalf("expected *Error, got %T: %v", err, err)
	}
	if bridgeErr.Status != http.StatusBadRequest || bridgeErr.Code != "invalid_request" || bridgeErr.Detail != "path required" {
		t.Fatalf("unexpected error fields: %+v", bridgeErr)
	}
}

func TestRuntimeInfoBaseURL(t *testing.T) {
	info := RuntimeInfo{Host: "127.0.0.1", Port: 12345}
	if got, want := info.BaseURL(), "http://127.0.0.1:12345"; got != want {
		t.Fatalf("BaseURL = %q, want %q", got, want)
	}
}

func TestResolveInfoPathRespectsEnvVar(t *testing.T) {
	custom := filepath.Join(t.TempDir(), "custom.json")
	t.Setenv(EnvInfoPath, custom)
	if got := ResolveInfoPath(); got != custom {
		t.Fatalf("ResolveInfoPath = %q, want %q", got, custom)
	}
}

func TestRuntimeInfoCacheReloadsAfterModification(t *testing.T) {
	info1 := RuntimeInfo{Host: "127.0.0.1", Port: 1, Token: "a"}
	infoPath := writeRuntimeInfoForTest(t, info1)
	cache := newRuntimeCache(infoPath)

	got, err := cache.Get()
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.Token != "a" {
		t.Fatalf("Token = %q, want %q", got.Token, "a")
	}

	// Update the file with a different token and bump mtime.
	info2 := RuntimeInfo{Host: "127.0.0.1", Port: 2, Token: "b"}
	data, _ := json.Marshal(info2)
	if err := os.WriteFile(infoPath, data, 0o600); err != nil {
		t.Fatalf("rewrite info: %v", err)
	}
	now := time.Now()
	if err := os.Chtimes(infoPath, now, now.Add(time.Second)); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	got, err = cache.Get()
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.Token != "b" {
		t.Fatalf("Token = %q, want %q", got.Token, "b")
	}
}

// Test that the error formatting is reasonable.
func TestBridgeErrorFormatting(t *testing.T) {
	cases := []struct {
		err   *Error
		check string
	}{
		{&Error{Status: 500, Code: "boom", Detail: "exploded"}, "exploded"},
		{&Error{Status: 502, Code: "boom"}, "boom"},
		{&Error{Status: 503}, "503"},
	}
	for _, tc := range cases {
		got := tc.err.Error()
		if !strings.Contains(got, tc.check) {
			t.Fatalf("error %q does not contain %q", got, tc.check)
		}
	}
}
