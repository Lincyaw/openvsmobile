package claude

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestNewProcessManager(t *testing.T) {
	pm := NewProcessManager("/usr/bin/echo", "/tmp")
	if pm.claudeBin != "/usr/bin/echo" {
		t.Fatalf("expected /usr/bin/echo, got %s", pm.claudeBin)
	}
	if pm.workingDir != "/tmp" {
		t.Fatalf("expected /tmp, got %s", pm.workingDir)
	}
}

func TestNewProcessManagerDefaults(t *testing.T) {
	pm := NewProcessManager("", "/tmp")
	if pm.claudeBin != defaultClaudeBin {
		t.Fatalf("expected default bin, got %s", pm.claudeBin)
	}
}

func TestConversationLifecycle(t *testing.T) {
	// Use "cat" as a mock binary — it echoes stdin to stdout.
	pm := NewProcessManager("/bin/cat", "/tmp")

	conv, err := pm.StartConversation("")
	if err != nil {
		t.Fatalf("failed to start: %v", err)
	}

	if conv.ID == "" {
		t.Fatal("conversation ID is empty")
	}

	// Verify it's tracked.
	if _, ok := pm.GetConversation(conv.ID); !ok {
		t.Fatal("conversation not found in active set")
	}

	// Close the conversation.
	if err := conv.Close(); err != nil {
		t.Fatalf("failed to close: %v", err)
	}

	// Remove and verify.
	pm.RemoveConversation(conv.ID)
	if _, ok := pm.GetConversation(conv.ID); ok {
		t.Fatal("conversation should be removed")
	}
}

func writeFakeClaudeCaptureScript(t *testing.T) (scriptPath, cwdLog string) {
	t.Helper()

	dir := t.TempDir()
	cwdLog = filepath.Join(dir, "cwd.log")
	scriptPath = filepath.Join(dir, "fake-claude.sh")
	script := strings.Join([]string{
		"#!/bin/sh",
		"printf '%s\\n' \"$PWD\" >> '" + cwdLog + "'",
		"while IFS= read -r _line; do :; done",
	}, "\n")
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake claude script: %v", err)
	}
	return scriptPath, cwdLog
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

func TestStartConversationUsesRequestedWorkingDir(t *testing.T) {
	claudeBin, cwdLog := writeFakeClaudeCaptureScript(t)
	pm := NewProcessManager(claudeBin, "/server/default")

	workspaceRoot := filepath.Join(t.TempDir(), "workspace")
	if err := os.MkdirAll(workspaceRoot, 0o755); err != nil {
		t.Fatalf("mkdir workspace: %v", err)
	}

	conv, err := pm.StartConversation(workspaceRoot)
	if err != nil {
		t.Fatalf("failed to start: %v", err)
	}
	if err := conv.Close(); err != nil {
		t.Fatalf("failed to close: %v", err)
	}

	if got := waitForFileLine(t, cwdLog); got != workspaceRoot {
		t.Fatalf("expected process cwd %q, got %q", workspaceRoot, got)
	}
}

func TestFormatMessageWithContextIncludesOnlyMinimalEnvelope(t *testing.T) {
	message := formatMessageWithContext("Explain this code", &ConversationContext{
		WorkspaceRoot: "/workspaces/alpha",
		ActiveFile:    "/workspaces/alpha/lib/main.dart",
		Cursor:        &CursorPosition{Line: 12, Column: 4},
		Selection: &SelectionRange{
			Start: CursorPosition{Line: 10, Column: 2},
			End:   CursorPosition{Line: 14, Column: 8},
		},
	})

	if !strings.Contains(message, "[mobile_editor_context]") {
		t.Fatalf("expected context envelope, got %q", message)
	}
	if !strings.Contains(message, `"workspaceRoot":"/workspaces/alpha"`) {
		t.Fatalf("expected workspace root in %q", message)
	}
	if !strings.Contains(message, `"activeFile":"/workspaces/alpha/lib/main.dart"`) {
		t.Fatalf("expected active file in %q", message)
	}
	if !strings.Contains(message, `"cursor":{"line":12,"column":4}`) {
		t.Fatalf("expected cursor in %q", message)
	}
	if !strings.Contains(message, `"selection":{"start":{"line":10,"column":2},"end":{"line":14,"column":8}}`) {
		t.Fatalf("expected selection in %q", message)
	}
	if strings.Contains(message, "diagnostics") || strings.Contains(message, "terminal") || strings.Contains(message, "git") {
		t.Fatalf("expected forbidden fields to be absent from %q", message)
	}
}

func TestFormatMessageWithContextPreservesNullSelection(t *testing.T) {
	message := formatMessageWithContext("Explain this code", &ConversationContext{
		WorkspaceRoot: "/workspaces/alpha",
		ActiveFile:    "/workspaces/alpha/lib/main.dart",
		Cursor:        &CursorPosition{Line: 9, Column: 7},
		Selection:     nil,
	})

	if !strings.Contains(message, `"selection":null`) {
		t.Fatalf("expected null selection in %q", message)
	}
}

func TestShutdown(t *testing.T) {
	pm := NewProcessManager("/bin/cat", "/tmp")

	_, err := pm.StartConversation("")
	if err != nil {
		t.Fatalf("failed to start: %v", err)
	}

	_, err = pm.StartConversation("")
	if err != nil {
		t.Fatalf("failed to start second: %v", err)
	}

	// Shutdown should close all conversations.
	pm.Shutdown()

	pm.mu.Lock()
	count := len(pm.active)
	pm.mu.Unlock()

	if count != 0 {
		t.Fatalf("expected 0 active conversations after shutdown, got %d", count)
	}
}

func TestConversationSendAfterClose(t *testing.T) {
	pm := NewProcessManager("/bin/cat", "/tmp")
	conv, err := pm.StartConversation("")
	if err != nil {
		t.Fatalf("failed to start: %v", err)
	}

	conv.Close()

	err = conv.Send("hello")
	if err == nil {
		t.Fatal("expected error sending to closed conversation")
	}
}
