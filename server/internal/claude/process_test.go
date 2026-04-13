package claude

import (
	"testing"
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
