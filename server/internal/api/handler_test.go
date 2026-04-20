package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Lincyaw/vscode-mobile/server/internal/claude"
	"github.com/Lincyaw/vscode-mobile/server/internal/diagnostics"
	"github.com/Lincyaw/vscode-mobile/server/internal/git"
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
	gitClient := git.NewGit(t.TempDir()) // dummy, tests needing git will override
	termMgr := terminal.NewManager()
	diagRunner := diagnostics.NewRunner(10 * time.Second)

	srv := NewServer(fs, sessionIndex, pm, token, gitClient, termMgr, diagRunner)
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
	diagRunner := diagnostics.NewRunner(10 * time.Second)
	srv := NewServer(nil, sessIndex, pm, "", git.NewGit("."), terminal.NewManager(), diagRunner)
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
	diagRunner := diagnostics.NewRunner(10 * time.Second)
	srv := NewServer(nil, sessIndex, pm, "", git.NewGit("."), terminal.NewManager(), diagRunner)
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
	diagRunner := diagnostics.NewRunner(10 * time.Second)
	srv := NewServer(nil, sessIndex, pm, "", git.NewGit("."), terminal.NewManager(), diagRunner)
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
	diagRunner := diagnostics.NewRunner(10 * time.Second)
	srv := NewServer(nil, sessIndex, pm, "", git.NewGit("."), terminal.NewManager(), diagRunner)
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

// --- Diagnostics handler test ---

func TestDiagnostics_NoRunner(t *testing.T) {
	// Server with nil diagnostics runner.
	sessIndex := claude.NewSessionIndex(t.TempDir())
	pm := claude.NewProcessManager("/nonexistent", ".")
	srv := NewServer(nil, sessIndex, pm, "", git.NewGit("."), terminal.NewManager(), nil)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/api/diagnostics?workDir=/tmp")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 for nil runner, got %d", resp.StatusCode)
	}
}

func TestDiagnostics_UnknownExtension(t *testing.T) {
	ts, _, _ := newTestServer(t, "")

	// Request diagnostics for a file with no known linter.
	resp, err := http.Get(ts.URL + "/api/diagnostics?path=/tmp/foo.xyz&workDir=/tmp")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 (empty results), got %d", resp.StatusCode)
	}
}

// --- Git handler test ---

func TestGitStatus_E2E(t *testing.T) {
	// Create a real git repo.
	tmpDir := t.TempDir()

	runGitIn(t, tmpDir, "init")
	runGitIn(t, tmpDir, "config", "user.email", "test@test.com")
	runGitIn(t, tmpDir, "config", "user.name", "Test")
	os.WriteFile(filepath.Join(tmpDir, "file.txt"), []byte("hello"), 0644)
	runGitIn(t, tmpDir, "add", "file.txt")
	runGitIn(t, tmpDir, "commit", "-m", "init")

	// Create a modification.
	os.WriteFile(filepath.Join(tmpDir, "file.txt"), []byte("modified"), 0644)
	os.WriteFile(filepath.Join(tmpDir, "new.txt"), []byte("new"), 0644)

	// Build server with this real git.
	sessIndex := claude.NewSessionIndex(t.TempDir())
	pm := claude.NewProcessManager("/nonexistent", ".")
	diagRunner := diagnostics.NewRunner(10 * time.Second)
	gitClient := git.NewGit(tmpDir)
	srv := NewServer(nil, sessIndex, pm, "", gitClient, terminal.NewManager(), diagRunner)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/api/git/status?path=" + tmpDir)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode, body)
	}

	var entries []git.StatusEntry
	if err := json.NewDecoder(resp.Body).Decode(&entries); err != nil {
		t.Fatal(err)
	}

	// Should have at least the modified file and the untracked file.
	if len(entries) < 1 {
		t.Fatalf("expected at least 1 status entry, got %d", len(entries))
	}

	// Look for the modified file.
	found := false
	for _, e := range entries {
		if e.Path == "file.txt" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected file.txt in status, got: %+v", entries)
	}
}

func TestGitLog_E2E(t *testing.T) {
	tmpDir := t.TempDir()

	runGitIn(t, tmpDir, "init")
	runGitIn(t, tmpDir, "config", "user.email", "test@test.com")
	runGitIn(t, tmpDir, "config", "user.name", "Test")
	os.WriteFile(filepath.Join(tmpDir, "a.txt"), []byte("a"), 0644)
	runGitIn(t, tmpDir, "add", "a.txt")
	runGitIn(t, tmpDir, "commit", "-m", "first commit")
	os.WriteFile(filepath.Join(tmpDir, "b.txt"), []byte("b"), 0644)
	runGitIn(t, tmpDir, "add", "b.txt")
	runGitIn(t, tmpDir, "commit", "-m", "second commit")

	sessIndex := claude.NewSessionIndex(t.TempDir())
	pm := claude.NewProcessManager("/nonexistent", ".")
	diagRunner := diagnostics.NewRunner(10 * time.Second)
	gitClient := git.NewGit(tmpDir)
	srv := NewServer(nil, sessIndex, pm, "", gitClient, terminal.NewManager(), diagRunner)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/api/git/log?path=" + tmpDir + "&count=10")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode, body)
	}

	var logEntries []git.LogEntry
	if err := json.NewDecoder(resp.Body).Decode(&logEntries); err != nil {
		t.Fatal(err)
	}
	if len(logEntries) != 2 {
		t.Fatalf("expected 2 log entries, got %d", len(logEntries))
	}
	if logEntries[0].Message != "second commit" {
		t.Fatalf("expected 'second commit', got %q", logEntries[0].Message)
	}
}

func TestGitDiff_E2E(t *testing.T) {
	tmpDir := t.TempDir()

	runGitIn(t, tmpDir, "init")
	runGitIn(t, tmpDir, "config", "user.email", "test@test.com")
	runGitIn(t, tmpDir, "config", "user.name", "Test")
	os.WriteFile(filepath.Join(tmpDir, "file.txt"), []byte("old content\n"), 0644)
	runGitIn(t, tmpDir, "add", "file.txt")
	runGitIn(t, tmpDir, "commit", "-m", "init")
	os.WriteFile(filepath.Join(tmpDir, "file.txt"), []byte("new content\n"), 0644)

	sessIndex := claude.NewSessionIndex(t.TempDir())
	pm := claude.NewProcessManager("/nonexistent", ".")
	diagRunner := diagnostics.NewRunner(10 * time.Second)
	gitClient := git.NewGit(tmpDir)
	srv := NewServer(nil, sessIndex, pm, "", gitClient, terminal.NewManager(), diagRunner)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/api/git/diff?path=" + tmpDir + "&file=file.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode, body)
	}

	body, _ := io.ReadAll(resp.Body)
	diff := string(body)
	if !strings.Contains(diff, "-old content") || !strings.Contains(diff, "+new content") {
		t.Fatalf("expected diff with old/new content, got:\n%s", diff)
	}
}

// --- Helper to run shell commands for git setup ---

// runGitIn runs a git command in the given directory.
func runGitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v failed: %v\n%s", args, err, out)
	}
}
