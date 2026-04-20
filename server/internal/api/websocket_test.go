package api

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/Lincyaw/vscode-mobile/server/internal/claude"
	"github.com/Lincyaw/vscode-mobile/server/internal/diagnostics"
	"github.com/Lincyaw/vscode-mobile/server/internal/git"
	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
)

func writeFakeClaudeCaptureScript(t *testing.T) (scriptPath, cwdLog, stdinLog string) {
	t.Helper()

	dir := t.TempDir()
	cwdLog = filepath.Join(dir, "cwd.log")
	stdinLog = filepath.Join(dir, "stdin.log")
	scriptPath = filepath.Join(dir, "fake-claude.sh")
	script := strings.Join([]string{
		"#!/bin/sh",
		"printf '%s\\n' \"$PWD\" >> '" + cwdLog + "'",
		"while IFS= read -r line; do",
		"  printf '%s\\n' \"$line\" >> '" + stdinLog + "'",
		"done",
	}, "\n")
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake claude script: %v", err)
	}
	return scriptPath, cwdLog, stdinLog
}

func newWebsocketTestServer(t *testing.T, claudeBin, defaultDir string) *httptest.Server {
	t.Helper()
	sessionIndex := claude.NewSessionIndex(t.TempDir())
	pm := claude.NewProcessManager(claudeBin, defaultDir)
	diagRunner := diagnostics.NewRunner(10 * time.Second)
	srv := NewServer(newMockFS(), sessionIndex, pm, "", git.NewGit(t.TempDir()), terminal.NewManager(), diagRunner)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return ts
}

func waitForFileLine(t *testing.T, path string) string {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil && strings.TrimSpace(string(data)) != "" {
			lines := strings.Split(strings.TrimSpace(string(data)), "\n")
			return lines[len(lines)-1]
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for file %s", path)
	return ""
}

func dialChatSocket(t *testing.T, serverURL string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(serverURL, "http") + "/ws/chat"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	return conn
}

func TestWSChatStartBindsConversationToRequestedWorkspace(t *testing.T) {
	claudeBin, cwdLog, _ := writeFakeClaudeCaptureScript(t)
	ts := newWebsocketTestServer(t, claudeBin, "/server/default")

	workspaceRoot := filepath.Join(t.TempDir(), "workspace-a")
	if err := os.MkdirAll(workspaceRoot, 0o755); err != nil {
		t.Fatalf("mkdir workspace: %v", err)
	}

	conn := dialChatSocket(t, ts.URL)
	defer conn.Close()

	if err := conn.WriteJSON(map[string]any{
		"type":          "start",
		"workspaceRoot": workspaceRoot,
	}); err != nil {
		t.Fatalf("write start message: %v", err)
	}

	var started map[string]any
	if err := conn.ReadJSON(&started); err != nil {
		t.Fatalf("read started message: %v", err)
	}
	if started["type"] != "started" {
		t.Fatalf("expected started response, got %#v", started)
	}

	if got := waitForFileLine(t, cwdLog); got != workspaceRoot {
		t.Fatalf("expected claude process cwd %q, got %q", workspaceRoot, got)
	}
}

func TestWSChatSendStripsUnknownFieldsAndPreservesNullSelection(t *testing.T) {
	claudeBin, _, stdinLog := writeFakeClaudeCaptureScript(t)
	ts := newWebsocketTestServer(t, claudeBin, "/server/default")

	workspaceRoot := filepath.Join(t.TempDir(), "workspace-b")
	if err := os.MkdirAll(workspaceRoot, 0o755); err != nil {
		t.Fatalf("mkdir workspace: %v", err)
	}

	conn := dialChatSocket(t, ts.URL)
	defer conn.Close()

	if err := conn.WriteJSON(map[string]any{
		"type":          "start",
		"workspaceRoot": workspaceRoot,
	}); err != nil {
		t.Fatalf("write start message: %v", err)
	}

	var started map[string]any
	if err := conn.ReadJSON(&started); err != nil {
		t.Fatalf("read started message: %v", err)
	}
	sessionID, _ := started["conversationId"].(string)
	if sessionID == "" {
		t.Fatalf("expected conversation id in %#v", started)
	}

	if err := conn.WriteJSON(map[string]any{
		"type":          "send",
		"sessionId":     sessionID,
		"message":       "Explain this function",
		"workspaceRoot": workspaceRoot,
		"activeFile":    filepath.Join(workspaceRoot, "lib", "main.dart"),
		"cursor": map[string]any{
			"line":   21,
			"column": 6,
		},
		"selection":   nil,
		"diagnostics": []string{"forbidden"},
		"terminal":    map[string]any{"cwd": "/tmp"},
		"git":         map[string]any{"branch": "forbidden"},
	}); err != nil {
		t.Fatalf("write send message: %v", err)
	}

	logged := waitForFileLine(t, stdinLog)
	var payload map[string]any
	if err := json.Unmarshal([]byte(logged), &payload); err != nil {
		t.Fatalf("unmarshal claude stdin payload: %v\nraw: %s", err, logged)
	}

	message, ok := payload["message"].(map[string]any)
	if !ok {
		t.Fatalf("expected stream-json message object, got %#v", payload)
	}
	content, _ := message["content"].(string)
	if !strings.Contains(content, "workspaceRoot") {
		t.Fatalf("expected content to include workspaceRoot, got %q", content)
	}
	if !strings.Contains(content, "activeFile") {
		t.Fatalf("expected content to include activeFile, got %q", content)
	}
	if !strings.Contains(content, "cursor") {
		t.Fatalf("expected content to include cursor, got %q", content)
	}
	if !strings.Contains(content, "\"selection\":null") {
		t.Fatalf("expected content to preserve null selection, got %q", content)
	}
	if strings.Contains(content, "diagnostics") || strings.Contains(content, "terminal") || strings.Contains(content, "git") {
		t.Fatalf("expected forbidden fields to be stripped from %q", content)
	}
}
