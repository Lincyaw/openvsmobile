package terminal

import (
	"strings"
	"testing"
	"time"
)

func waitForOutputChunk(t *testing.T, ch <-chan []byte, timeout time.Duration, wantSubstring string) []byte {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case chunk, ok := <-ch:
			if !ok {
				t.Fatal("attachment output closed before expected chunk arrived")
			}
			if strings.Contains(string(chunk), wantSubstring) {
				return chunk
			}
		case <-deadline:
			t.Fatalf("timed out waiting for output containing %q", wantSubstring)
		}
	}
}

func waitForManagerEvent(t *testing.T, ch <-chan Event, timeout time.Duration, wantType string) Event {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case event, ok := <-ch:
			if !ok {
				t.Fatal("event stream closed before expected event arrived")
			}
			if event.Type == wantType {
				return event
			}
		case <-deadline:
			t.Fatalf("timed out waiting for manager event %q", wantType)
		}
	}
}

func TestCreateAndAttachReplaysBacklogAcrossAttachments(t *testing.T) {
	m := NewManager()
	defer m.CloseAll()

	term, err := m.CreateSession(CreateOptions{Name: "primary", Shell: "/bin/bash", WorkDir: "/tmp", Rows: 24, Cols: 80})
	if err != nil {
		t.Fatalf("CreateSession failed: %v", err)
	}

	attachment, err := m.Attach(term.ID)
	if err != nil {
		t.Fatalf("Attach failed: %v", err)
	}
	defer attachment.Close()

	if _, err := term.Write([]byte("echo hello-from-attach\n")); err != nil {
		t.Fatalf("Write failed: %v", err)
	}
	waitForOutputChunk(t, attachment.Output(), 5*time.Second, "hello-from-attach")

	attachment.Close()
	replay, err := m.Attach(term.ID)
	if err != nil {
		t.Fatalf("reattach failed: %v", err)
	}
	defer replay.Close()
	if !strings.Contains(string(replay.Backlog()), "hello-from-attach") {
		t.Fatalf("replay backlog = %q, want substring %q", string(replay.Backlog()), "hello-from-attach")
	}
}

func TestResizeRenameSplitLifecycle(t *testing.T) {
	m := NewManager()
	defer m.CloseAll()

	parent, err := m.CreateSession(CreateOptions{Name: "main", Shell: "/bin/bash", WorkDir: "/tmp", Rows: 24, Cols: 80})
	if err != nil {
		t.Fatalf("CreateSession failed: %v", err)
	}

	if err := m.Resize(parent.ID, 30, 120); err != nil {
		t.Fatalf("Resize failed: %v", err)
	}
	resized, ok := m.Get(parent.ID)
	if !ok {
		t.Fatal("expected resized session to remain addressable")
	}
	if snapshot := resized.Snapshot(); snapshot.Rows != 30 || snapshot.Cols != 120 {
		t.Fatalf("resized session dims = %dx%d, want 30x120", snapshot.Rows, snapshot.Cols)
	}

	renamed, err := m.Rename(parent.ID, "renamed-main")
	if err != nil {
		t.Fatalf("Rename failed: %v", err)
	}
	if renamed.Name != "renamed-main" {
		t.Fatalf("renamed session name = %q, want %q", renamed.Name, "renamed-main")
	}

	split, err := m.Split(parent.ID, "split-pane")
	if err != nil {
		t.Fatalf("Split failed: %v", err)
	}
	if split.ID == parent.ID {
		t.Fatal("split session id should differ from parent id")
	}
	if split.Cwd != renamed.Cwd || split.Profile != renamed.Profile {
		t.Fatalf("split session should inherit cwd/profile, got cwd=%q profile=%q", split.Cwd, split.Profile)
	}

	listed := m.List()
	if len(listed) != 2 {
		t.Fatalf("List count = %d, want 2", len(listed))
	}
}

func TestExitStatePersistsForReattachUntilClose(t *testing.T) {
	m := NewManager()
	defer m.CloseAll()

	term, err := m.CreateSession(CreateOptions{Name: "exit-state", Shell: "/bin/bash", WorkDir: "/tmp"})
	if err != nil {
		t.Fatalf("CreateSession failed: %v", err)
	}

	if _, err := term.Write([]byte("echo before-exit\nexit 7\n")); err != nil {
		t.Fatalf("Write failed: %v", err)
	}

	select {
	case <-term.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for terminal to exit")
	}

	snapshot := term.Snapshot()
	if snapshot.State != StateExited {
		t.Fatalf("session state after exit = %q, want %q", snapshot.State, StateExited)
	}
	if snapshot.ExitCode == nil || *snapshot.ExitCode != 7 {
		t.Fatalf("stored exit code = %+v, want 7", snapshot.ExitCode)
	}

	replay, err := m.Attach(term.ID)
	if err != nil {
		t.Fatalf("reattach failed: %v", err)
	}
	defer replay.Close()
	if !strings.Contains(string(replay.Backlog()), "before-exit") {
		t.Fatalf("reattach backlog = %q, want substring %q", string(replay.Backlog()), "before-exit")
	}
	select {
	case _, ok := <-replay.Output():
		if ok {
			t.Fatal("expected exited session attachment output channel to be closed")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for exited attachment stream to close")
	}
}

func TestCloseBroadcastsClosedEventAndRemovesSession(t *testing.T) {
	m := NewManager()
	events, unsubscribe := m.SubscribeEvents()
	defer unsubscribe()

	term, err := m.CreateSession(CreateOptions{Name: "close-me", Shell: "/bin/bash", WorkDir: "/tmp"})
	if err != nil {
		t.Fatalf("CreateSession failed: %v", err)
	}
	_ = waitForManagerEvent(t, events, 3*time.Second, "terminal/session.created")

	closed, err := m.CloseSession(term.ID)
	if err != nil {
		t.Fatalf("CloseSession failed: %v", err)
	}
	if closed.State != StateExited {
		t.Fatalf("closed session state = %q, want %q", closed.State, StateExited)
	}

	event := waitForManagerEvent(t, events, 3*time.Second, "terminal/session.closed")
	if event.Session.ID != term.ID {
		t.Fatalf("closed event id = %q, want %q", event.Session.ID, term.ID)
	}

	if _, ok := m.Get(term.ID); ok {
		t.Fatal("expected closed session to be removed from manager")
	}
}

func TestErrorsForDuplicateAndMissingSessions(t *testing.T) {
	m := NewManager()
	defer m.CloseAll()

	term, err := m.CreateSession(CreateOptions{ID: "dup", Name: "dup", Shell: "/bin/bash", WorkDir: "/tmp"})
	if err != nil {
		t.Fatalf("initial CreateSession failed: %v", err)
	}
	if term.ID != "dup" {
		t.Fatalf("created id = %q, want dup", term.ID)
	}

	if _, err := m.CreateSession(CreateOptions{ID: "dup", Name: "dup", Shell: "/bin/bash", WorkDir: "/tmp"}); err == nil {
		t.Fatal("expected duplicate terminal id to be rejected")
	}
	if err := m.Resize("missing", 30, 120); err == nil {
		t.Fatal("expected resize on missing terminal to fail")
	}
	if _, err := m.CloseSession("missing"); err == nil {
		t.Fatal("expected close on missing terminal to fail")
	}
}
