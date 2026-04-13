package terminal

import (
	"strings"
	"testing"
	"time"
)

func TestCreate(t *testing.T) {
	m := NewManager()
	defer m.CloseAll()

	term, err := m.Create("test-1", "/bin/bash", "/tmp", 24, 80)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}

	// Write a command.
	_, err = term.Write([]byte("echo hello\n"))
	if err != nil {
		t.Fatalf("Write failed: %v", err)
	}

	// Read output with a timeout.
	buf := make([]byte, 4096)
	var output strings.Builder
	deadline := time.After(5 * time.Second)

	for {
		select {
		case <-deadline:
			t.Fatalf("timed out waiting for output; got so far: %q", output.String())
		default:
		}

		n, err := term.Read(buf)
		if err != nil {
			t.Fatalf("Read error: %v", err)
		}
		output.Write(buf[:n])
		if strings.Contains(output.String(), "hello") {
			break
		}
	}
}

func TestResize(t *testing.T) {
	m := NewManager()
	defer m.CloseAll()

	_, err := m.Create("test-resize", "/bin/bash", "/tmp", 24, 80)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}

	if err := m.Resize("test-resize", 30, 120); err != nil {
		t.Fatalf("Resize failed: %v", err)
	}
}

func TestClose(t *testing.T) {
	m := NewManager()

	term, err := m.Create("test-close", "/bin/bash", "/tmp", 24, 80)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}

	if err := m.Close("test-close"); err != nil {
		t.Fatalf("Close failed: %v", err)
	}

	// The done channel should be closed shortly after.
	select {
	case <-term.Done():
		// success
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for Done() channel to close")
	}

	// Verify the terminal is removed from the manager.
	if _, ok := m.Get("test-close"); ok {
		t.Fatal("terminal should have been removed from manager after close")
	}
}
