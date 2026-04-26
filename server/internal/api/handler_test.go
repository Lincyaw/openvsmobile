package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/Lincyaw/vscode-mobile/server/internal/claude"
	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
)

// --- Mock FileSystem ---

type mockFS struct {
	files map[string][]byte
	dirs  map[string][]claude.DirEntry
}

func newMockFS() *mockFS {
	return &mockFS{
		files: make(map[string][]byte),
		dirs:  make(map[string][]claude.DirEntry),
	}
}

func (m *mockFS) ReadDir(path string) ([]claude.DirEntry, error) {
	entries, ok := m.dirs[path]
	if !ok {
		return nil, fmt.Errorf("directory not found: %s", path)
	}
	return entries, nil
}

func (m *mockFS) ReadFile(path string) ([]byte, error) {
	data, ok := m.files[path]
	if !ok {
		return nil, fmt.Errorf("file not found: %s", path)
	}
	return data, nil
}

func (m *mockFS) WriteFile(path string, content []byte) error {
	m.files[path] = content
	return nil
}

func (m *mockFS) Stat(path string) (*claude.FileStat, error) {
	if _, ok := m.dirs[path]; ok {
		return &claude.FileStat{Name: filepath.Base(path), IsDir: true}, nil
	}
	if _, ok := m.files[path]; ok {
		return &claude.FileStat{Name: filepath.Base(path), IsDir: false, Size: int64(len(m.files[path]))}, nil
	}
	return nil, fmt.Errorf("not found: %s", path)
}

func (m *mockFS) Delete(path string) error {
	delete(m.files, path)
	delete(m.dirs, path)
	return nil
}

func (m *mockFS) MkDir(path string) error {
	m.dirs[path] = []claude.DirEntry{}
	return nil
}

// --- Test helpers ---

// newTestServer creates a Server wired up with real SessionIndex (temp dir),
// mock FS, and a diagnostics runner. Returns the httptest.Server and cleanup func.
func newTestServer(t *testing.T, token string) (*httptest.Server, *mockFS, string) {
	t.Helper()

	tmpDir := t.TempDir()
	sessionsDir := filepath.Join(tmpDir, "sessions")
	projectsDir := filepath.Join(tmpDir, "projects")
	os.MkdirAll(sessionsDir, 0755)
	os.MkdirAll(projectsDir, 0755)

	sessionIndex := claude.NewSessionIndex(tmpDir)
	pm := claude.NewProcessManager("/nonexistent/claude", ".")
	fs := newMockFS()
	termMgr := terminal.NewManager()

	srv := NewServer(fs, sessionIndex, pm, token, nil, termMgr, nil)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	return ts, fs, tmpDir
}

// writeSessionFile creates a session metadata JSON file.
func writeSessionFile(t *testing.T, claudeDir string, pid int, sessionID, cwd, entrypoint string) {
	t.Helper()
	sessionsDir := filepath.Join(claudeDir, "sessions")
	meta := claude.SessionMeta{
		PID:        pid,
		SessionID:  sessionID,
		Cwd:        cwd,
		StartedAt:  time.Now().Add(-time.Duration(pid) * time.Hour).UnixMilli(),
		Kind:       "interactive",
		Entrypoint: entrypoint,
	}
	data, _ := json.Marshal(meta)
	os.WriteFile(filepath.Join(sessionsDir, fmt.Sprintf("%d.json", pid)), data, 0644)
}

// writeSessionJSONL creates a session conversation JSONL file.
func writeSessionJSONL(t *testing.T, claudeDir, projectSlug, sessionID string, lines []string) {
	t.Helper()
	dir := filepath.Join(claudeDir, "projects", projectSlug)
	os.MkdirAll(dir, 0755)
	content := strings.Join(lines, "\n") + "\n"
	os.WriteFile(filepath.Join(dir, sessionID+".jsonl"), []byte(content), 0644)
}

// --- Auth middleware tests ---

func TestAuthMiddleware_NoToken(t *testing.T) {
	// Server with no token should allow all requests.
	ts, _, _ := newTestServer(t, "")

	resp, err := http.Get(ts.URL + "/api/sessions")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
}

func TestAuthMiddleware_ValidTokenHeader(t *testing.T) {
	ts, _, _ := newTestServer(t, "secret-token")

	req, _ := http.NewRequest("GET", ts.URL+"/api/sessions", nil)
	req.Header.Set("Authorization", "Bearer secret-token")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
}

func TestAuthMiddleware_ValidTokenQuery(t *testing.T) {
	ts, _, _ := newTestServer(t, "secret-token")

	resp, err := http.Get(ts.URL + "/api/sessions?token=secret-token")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
}

func TestAuthMiddleware_InvalidToken(t *testing.T) {
	ts, _, _ := newTestServer(t, "secret-token")

	resp, err := http.Get(ts.URL + "/api/sessions")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

func TestAuthMiddleware_WrongToken(t *testing.T) {
	ts, _, _ := newTestServer(t, "secret-token")

	req, _ := http.NewRequest("GET", ts.URL+"/api/sessions", nil)
	req.Header.Set("Authorization", "Bearer wrong-token")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

// --- File handler tests ---

func TestFilesGet_ListDirectory(t *testing.T) {
	ts, fs, _ := newTestServer(t, "")
	fs.dirs["/src"] = []claude.DirEntry{
		{Name: "main.go", IsDir: false, Size: 100},
		{Name: "lib", IsDir: true, Size: 0},
	}

	resp, err := http.Get(ts.URL + "/api/files/src")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode, body)
	}

	var entries []claude.DirEntry
	if err := json.NewDecoder(resp.Body).Decode(&entries); err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}
	if entries[0].Name != "main.go" {
		t.Fatalf("expected main.go, got %s", entries[0].Name)
	}
}

func TestFilesGet_ReadFile(t *testing.T) {
	ts, fs, _ := newTestServer(t, "")
	fs.files["/src/main.go"] = []byte("package main\n")
	fs.dirs["/src"] = nil // not a dir at exact path

	resp, err := http.Get(ts.URL + "/api/files/src/main.go")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode, body)
	}

	body, _ := io.ReadAll(resp.Body)
	if string(body) != "package main\n" {
		t.Fatalf("expected 'package main\\n', got %q", string(body))
	}
}

func TestFilesGet_NotFound(t *testing.T) {
	ts, _, _ := newTestServer(t, "")

	resp, err := http.Get(ts.URL + "/api/files/nonexistent")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

func TestFilesPut_WriteFile(t *testing.T) {
	ts, fs, _ := newTestServer(t, "")
	// Stat needs to work for the file (or the handler doesn't check — let's test the write path)
	fs.files["/test.txt"] = []byte("old content")

	req, _ := http.NewRequest("PUT", ts.URL+"/api/files/test.txt", strings.NewReader("new content"))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 204, got %d: %s", resp.StatusCode, body)
	}

	// Verify the mock FS was updated.
	if string(fs.files["/test.txt"]) != "new content" {
		t.Fatalf("expected 'new content', got %q", string(fs.files["/test.txt"]))
	}
}

func TestFilesDelete(t *testing.T) {
	ts, fs, _ := newTestServer(t, "")
	fs.files["/deleteme.txt"] = []byte("gone")

	req, _ := http.NewRequest("DELETE", ts.URL+"/api/files/deleteme.txt", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", resp.StatusCode)
	}

	if _, ok := fs.files["/deleteme.txt"]; ok {
		t.Fatal("expected file to be deleted")
	}
}

// --- Session handler tests (E2E with real SessionIndex) ---

func TestSessionsList_Empty(t *testing.T) {
	ts, _, _ := newTestServer(t, "")

	resp, err := http.Get(ts.URL + "/api/sessions")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var sessions []claude.SessionMeta
	if err := json.NewDecoder(resp.Body).Decode(&sessions); err != nil {
		t.Fatal(err)
	}
	if len(sessions) != 0 {
		t.Fatalf("expected 0 sessions, got %d", len(sessions))
	}
}

func TestSessionsList_WithSessions(t *testing.T) {
	_, _, claudeDir := newTestServer(t, "")

	writeSessionFile(t, claudeDir, 1001, "sess-aaa", "/home/user/projectA", "cli")
	writeSessionFile(t, claudeDir, 1002, "sess-bbb", "/home/user/projectB", "api")
	writeSessionFile(t, claudeDir, 1003, "sess-ccc", "/home/user/projectA", "cli")

	// Re-scan after writing files — the index was built empty at server creation.
	// Build a new server with pre-populated sessions.
	sessIndex := claude.NewSessionIndex(claudeDir)
	if err := sessIndex.ScanSessions(); err != nil {
		t.Fatal(err)
	}

	pm := claude.NewProcessManager("/nonexistent", ".")
	srv := NewServer(nil, sessIndex, pm, "", nil, terminal.NewManager(), nil)
	ts2 := httptest.NewServer(srv.Handler())
	defer ts2.Close()

	resp, err := http.Get(ts2.URL + "/api/sessions")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var sessions []claude.SessionMeta
	if err := json.NewDecoder(resp.Body).Decode(&sessions); err != nil {
		t.Fatal(err)
	}
	if len(sessions) != 3 {
		t.Fatalf("expected 3 sessions, got %d", len(sessions))
	}
}

func TestSessionsSearch_ByQuery(t *testing.T) {
	claudeDir := t.TempDir()
	sessionsDir := filepath.Join(claudeDir, "sessions")
	os.MkdirAll(sessionsDir, 0755)

	writeSessionFile(t, claudeDir, 1, "s1", "/home/user/frontend-app", "cli")
	writeSessionFile(t, claudeDir, 2, "s2", "/home/user/backend-server", "cli")
	writeSessionFile(t, claudeDir, 3, "s3", "/home/user/frontend-app", "api")

	sessIndex := claude.NewSessionIndex(claudeDir)
	sessIndex.ScanSessions()

	pm := claude.NewProcessManager("/nonexistent", ".")
	srv := NewServer(nil, sessIndex, pm, "", nil, terminal.NewManager(), nil)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// Search for "frontend".
	resp, err := http.Get(ts.URL + "/api/sessions?q=frontend")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var sessions []claude.SessionMeta
	json.NewDecoder(resp.Body).Decode(&sessions)
	if len(sessions) != 2 {
		t.Fatalf("expected 2 sessions matching 'frontend', got %d", len(sessions))
	}

	// Search for "backend".
	resp2, err := http.Get(ts.URL + "/api/sessions?q=backend")
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()

	var sessions2 []claude.SessionMeta
	json.NewDecoder(resp2.Body).Decode(&sessions2)
	if len(sessions2) != 1 {
		t.Fatalf("expected 1 session matching 'backend', got %d", len(sessions2))
	}

	// Search with no match.
	resp3, err := http.Get(ts.URL + "/api/sessions?q=nonexistent")
	if err != nil {
		t.Fatal(err)
	}
	defer resp3.Body.Close()

	var sessions3 []claude.SessionMeta
	json.NewDecoder(resp3.Body).Decode(&sessions3)
	if len(sessions3) != 0 {
		t.Fatalf("expected 0 sessions, got %d", len(sessions3))
	}
}

func TestSessionsSearch_ProjectUsesExactWorkspaceRoot(t *testing.T) {
	claudeDir := t.TempDir()
	sessionsDir := filepath.Join(claudeDir, "sessions")
	os.MkdirAll(sessionsDir, 0o755)

	writeSessionFile(t, claudeDir, 1, "s1", "/tmp/workspaces/app", "cli")
	writeSessionFile(t, claudeDir, 2, "s2", "/var/tmp/app", "cli")
	writeSessionFile(t, claudeDir, 3, "s3", "/tmp/workspaces/app-nested", "cli")

	sessIndex := claude.NewSessionIndex(claudeDir)
	if err := sessIndex.ScanSessions(); err != nil {
		t.Fatal(err)
	}

	pm := claude.NewProcessManager("/nonexistent", ".")
	srv := NewServer(nil, sessIndex, pm, "", nil, terminal.NewManager(), nil)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/api/sessions?project=/tmp/workspaces/app")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var sessions []claude.SessionMeta
	if err := json.NewDecoder(resp.Body).Decode(&sessions); err != nil {
		t.Fatal(err)
	}
	if len(sessions) != 1 {
		t.Fatalf("expected 1 exact-root session, got %d", len(sessions))
	}
	if sessions[0].SessionID != "s1" {
		t.Fatalf("expected session s1, got %#v", sessions)
	}
}

func TestSessionMessages_E2E(t *testing.T) {
	claudeDir := t.TempDir()
	sessionsDir := filepath.Join(claudeDir, "sessions")
	os.MkdirAll(sessionsDir, 0755)

	writeSessionFile(t, claudeDir, 100, "sess-msg-test", "/home/user/myproject", "cli")
	writeSessionJSONL(t, claudeDir, "myproject-slug", "sess-msg-test", []string{
		`{"type":"user","content":"hello claude"}`,
		`{"type":"assistant","content":[{"type":"text","text":"Hello! How can I help?"}]}`,
		`{"type":"system","subtype":"turn_end","stopReason":"end_turn","durationMs":1200}`,
	})

	sessIndex := claude.NewSessionIndex(claudeDir)
	sessIndex.ScanSessions()

	pm := claude.NewProcessManager("/nonexistent", ".")
	srv := NewServer(nil, sessIndex, pm, "", nil, terminal.NewManager(), nil)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/api/sessions/sess-msg-test/messages")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode, body)
	}

	var messages []claude.Message
	if err := json.NewDecoder(resp.Body).Decode(&messages); err != nil {
		t.Fatal(err)
	}
	if len(messages) != 3 {
		t.Fatalf("expected 3 messages, got %d", len(messages))
	}
	if messages[0].Type != "user" {
		t.Fatalf("expected user, got %s", messages[0].Type)
	}
	if messages[1].Type != "assistant" {
		t.Fatalf("expected assistant, got %s", messages[1].Type)
	}
	if len(messages[1].ContentBlocks) != 1 || messages[1].ContentBlocks[0].Text != "Hello! How can I help?" {
		t.Fatalf("unexpected assistant content: %+v", messages[1].ContentBlocks)
	}
	if messages[2].Type != "system" {
		t.Fatalf("expected system, got %s", messages[2].Type)
	}
}

func TestSessionMessages_NotFound(t *testing.T) {
	ts, _, _ := newTestServer(t, "")

	resp, err := http.Get(ts.URL + "/api/sessions/nonexistent-id/messages")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

func TestGitLegacyAPIEndpointsAreNotRegistered(t *testing.T) {
	ts, _, _ := newTestServer(t, "")

	tests := []string{
		"/api/git/status?path=" + t.TempDir(),
		"/api/git/log?path=" + t.TempDir() + "&count=10",
		"/api/git/diff?path=" + t.TempDir() + "&file=file.txt",
	}

	for _, path := range tests {
		t.Run(path, func(t *testing.T) {
			resp, err := http.Get(ts.URL + path)
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != http.StatusNotFound {
				body, _ := io.ReadAll(resp.Body)
				t.Fatalf("expected 404 for %s, got %d: %s", path, resp.StatusCode, body)
			}
		})
	}
}

func TestHandler_LegacyTerminalWebSocketRouteRemoved(t *testing.T) {
	ts, _, _ := newTestServer(t, "")

	// /bridge/ws/terminal/{id} was renamed to /ws/terminal/{id} alongside the
	// REST path moves (decisions.md 2026-04-26). Confirm the legacy bridge URL
	// is no longer registered, while the new path upgrades successfully.
	legacyURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/bridge/ws/terminal/some-id"
	conn, resp, err := websocket.DefaultDialer.Dial(legacyURL, nil)
	if conn != nil {
		_ = conn.Close()
	}
	if err == nil {
		t.Fatal("expected legacy /bridge/ws/terminal/{id} route to be removed")
	}
	if resp != nil && resp.StatusCode == http.StatusSwitchingProtocols {
		t.Fatalf("legacy /bridge/ws/terminal unexpectedly upgraded with status %d", resp.StatusCode)
	}

	// The new /ws/terminal/{id} should still upgrade — even if the session
	// id is unknown, the dial itself completes; the handler closes the
	// connection after writing an error.
	newURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/terminal/some-id"
	conn2, resp2, err := websocket.DefaultDialer.Dial(newURL, nil)
	if conn2 != nil {
		_ = conn2.Close()
	}
	if err != nil {
		t.Fatalf("expected /ws/terminal/{id} route to be registered, got dial error: %v", err)
	}
	if resp2 == nil || resp2.StatusCode != http.StatusSwitchingProtocols {
		status := 0
		if resp2 != nil {
			status = resp2.StatusCode
		}
		t.Fatalf("/ws/terminal/{id} should upgrade, got status %d", status)
	}
}

