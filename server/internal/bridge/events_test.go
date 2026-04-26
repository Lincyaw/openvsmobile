package bridge

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeSSEServer writes a sequence of frames to /events on each connection. It
// records how many connections it has accepted so reconnect tests can wait.
type fakeSSEServer struct {
	mu        sync.Mutex
	frames    []string
	conns     int32
	keepOpen  bool          // when true, the handler blocks instead of returning EOF
	holdEvery time.Duration // optional sleep between frames
	openCh    chan struct{} // signalled on each new connection (drop-on-full)
}

func newFakeSSEServer(t *testing.T, frames []string) (*httptest.Server, *fakeSSEServer) {
	t.Helper()
	fake := &fakeSSEServer{
		frames: frames,
		openCh: make(chan struct{}, 8),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/events", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&fake.conns, 1)
		select {
		case fake.openCh <- struct{}{}:
		default:
		}
		flusher, ok := w.(http.Flusher)
		if !ok {
			t.Errorf("ResponseWriter does not support flush")
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fake.mu.Lock()
		framesSnapshot := append([]string(nil), fake.frames...)
		hold := fake.keepOpen
		every := fake.holdEvery
		fake.mu.Unlock()
		for _, frame := range framesSnapshot {
			if _, err := w.Write([]byte(frame)); err != nil {
				return
			}
			flusher.Flush()
			if every > 0 {
				time.Sleep(every)
			}
		}
		if hold {
			<-r.Context().Done()
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, fake
}

func (f *fakeSSEServer) ConnCount() int32 {
	return atomic.LoadInt32(&f.conns)
}

func writeRuntimeInfoForFakeServer(t *testing.T, srv *httptest.Server) string {
	t.Helper()
	u, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatalf("parse server URL: %v", err)
	}
	port := 0
	if _, err := jsonNumberToInt(u.Port(), &port); err != nil {
		t.Fatalf("parse port: %v", err)
	}
	return writeRuntimeInfoForTest(t, RuntimeInfo{
		Host:  u.Hostname(),
		Port:  port,
		Token: "stream-token",
	})
}

func eventFrame(name string, payload any) string {
	data, _ := json.Marshal(payload)
	return fmt.Sprintf("event: %s\ndata: %s\n\n", name, string(data))
}

func newTestStream(client *Client) *EventStream {
	s := NewEventStream(client)
	// Tighten timings so the test suite stays fast.
	s.initialBackoff = 5 * time.Millisecond
	s.maxBackoff = 50 * time.Millisecond
	s.missingPollEvery = 20 * time.Millisecond
	s.mtimePollEvery = 50 * time.Millisecond
	return s
}

func TestEventStreamReceivesEvents(t *testing.T) {
	frames := []string{
		eventFrame("ready", map[string]any{"pid": 42}),
		eventFrame("git.repositoryChanged", map[string]any{"rootPath": "/tmp/repo"}),
		eventFrame("diagnostics.changed", map[string]any{"uris": []string{"file:///x.go"}}),
	}
	srv, _ := newFakeSSEServer(t, frames)

	infoPath := writeRuntimeInfoForFakeServer(t, srv)
	client := NewClientWithPath(infoPath)
	stream := newTestStream(client)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ch, unsub := stream.Subscribe()
	defer unsub()

	stream.Start(ctx)

	got := make([]Event, 0, 2)
	deadline := time.After(2 * time.Second)
	for len(got) < 2 {
		select {
		case ev, ok := <-ch:
			if !ok {
				t.Fatalf("subscriber channel closed unexpectedly after %d events", len(got))
			}
			got = append(got, ev)
		case <-deadline:
			t.Fatalf("timed out waiting for events; got %d", len(got))
		}
	}

	if got[0].Type != "git.repositoryChanged" {
		t.Fatalf("event[0].Type = %q, want git.repositoryChanged", got[0].Type)
	}
	if got[1].Type != "diagnostics.changed" {
		t.Fatalf("event[1].Type = %q, want diagnostics.changed", got[1].Type)
	}
	if !strings.Contains(string(got[0].Data), "/tmp/repo") {
		t.Fatalf("event[0].Data missing rootPath: %s", string(got[0].Data))
	}
	if stream.LastReadyAt().IsZero() {
		t.Fatalf("LastReadyAt was not updated despite ready frame")
	}
}

func TestEventStreamReconnectsOnConnectionClose(t *testing.T) {
	frames := []string{
		eventFrame("ready", map[string]any{"pid": 1}),
		eventFrame("git.repositoryChanged", map[string]any{"rootPath": "/r"}),
	}
	srv, fake := newFakeSSEServer(t, frames)

	infoPath := writeRuntimeInfoForFakeServer(t, srv)
	client := NewClientWithPath(infoPath)
	stream := newTestStream(client)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ch, unsub := stream.Subscribe()
	defer unsub()

	stream.Start(ctx)

	// We expect at least 2 reconnects within a short window because each
	// connection closes after writing the static frames.
	deadline := time.After(2 * time.Second)
	want := int32(2)
	for fake.ConnCount() < want {
		select {
		case <-ch:
			// drain so the broadcast loop doesn't fill up
		case <-time.After(20 * time.Millisecond):
		case <-deadline:
			t.Fatalf("timed out waiting for reconnects; got %d", fake.ConnCount())
		}
	}
}

func TestEventStreamReconnectsOnRuntimeInfoMtime(t *testing.T) {
	frames := []string{
		eventFrame("ready", map[string]any{"pid": 1}),
	}
	srv, fake := newFakeSSEServer(t, frames)
	fake.mu.Lock()
	fake.keepOpen = true // the handler holds the connection open
	fake.mu.Unlock()

	infoPath := writeRuntimeInfoForFakeServer(t, srv)
	client := NewClientWithPath(infoPath)
	stream := newTestStream(client)
	// The mtime watcher polls every 2s in production; for tests we need to
	// override it via a faster initial-backoff cadence — but the mtime
	// poll itself is hardcoded. Instead we wait long enough for it to fire.
	// Bump max timeout to accommodate.

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	stream.Start(ctx)

	// Wait for the first connection.
	select {
	case <-fake.openCh:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for first SSE connection")
	}
	// Give the watcher goroutine time to capture the file's original mtime
	// before we mutate it; otherwise it captures the post-mutation value
	// and never sees a change.
	time.Sleep(100 * time.Millisecond)

	// Touch the runtime-info file with a future mtime. The watcher fires
	// every mtimePollEvery ms (50ms in tests).
	future := time.Now().Add(5 * time.Second)
	if err := os.Chtimes(infoPath, future, future); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	deadline := time.After(5 * time.Second)
	for {
		select {
		case <-fake.openCh:
			return
		case <-time.After(200 * time.Millisecond):
			t.Logf("waiting; conns=%d", fake.ConnCount())
		case <-deadline:
			t.Fatalf("expected reconnect after mtime change; conns=%d", fake.ConnCount())
		}
	}
}

func TestEventStreamWaitsForRuntimeInfo(t *testing.T) {
	tempDir := t.TempDir()
	missing := filepath.Join(tempDir, "bridge-runtime.json")

	client := NewClientWithPath(missing)
	stream := newTestStream(client)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	stream.Start(ctx)

	// Give the consumer a few iterations against the missing file.
	time.Sleep(60 * time.Millisecond)

	// Now make the file appear, pointing at a real fake SSE server.
	frames := []string{
		eventFrame("ready", map[string]any{"pid": 1}),
		eventFrame("git.repositoryChanged", map[string]any{"rootPath": "/late"}),
	}
	srv, _ := newFakeSSEServer(t, frames)
	u, _ := url.Parse(srv.URL)
	port := 0
	_, _ = jsonNumberToInt(u.Port(), &port)

	info := RuntimeInfo{Host: u.Hostname(), Port: port, Token: "tok"}
	data, _ := json.Marshal(info)
	if err := os.WriteFile(missing, data, 0o600); err != nil {
		t.Fatalf("write info: %v", err)
	}

	ch, unsub := stream.Subscribe()
	defer unsub()

	deadline := time.After(3 * time.Second)
	for {
		select {
		case ev, ok := <-ch:
			if !ok {
				t.Fatal("channel closed before receiving event")
			}
			if ev.Type == "git.repositoryChanged" {
				return
			}
		case <-deadline:
			t.Fatal("timed out waiting for event after runtime-info appeared")
		}
	}
}

func TestEventStreamSubscribeUnsubscribeIsLeakFree(t *testing.T) {
	srv, _ := newFakeSSEServer(t, []string{eventFrame("ready", nil)})
	infoPath := writeRuntimeInfoForFakeServer(t, srv)
	client := NewClientWithPath(infoPath)
	stream := newTestStream(client)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream.Start(ctx)

	// Take and release 100 subscribers; the backing map should end empty.
	for i := 0; i < 100; i++ {
		_, unsub := stream.Subscribe()
		unsub()
	}
	if got := stream.SubscriberCount(); got != 0 {
		t.Fatalf("SubscriberCount = %d, want 0", got)
	}

	// Releasing twice should be safe.
	_, unsub := stream.Subscribe()
	unsub()
	unsub()
	if got := stream.SubscriberCount(); got != 0 {
		t.Fatalf("SubscriberCount after double-unsub = %d, want 0", got)
	}
}

func TestEventStreamShutdownClosesSubscribers(t *testing.T) {
	srv, _ := newFakeSSEServer(t, []string{eventFrame("ready", nil)})
	infoPath := writeRuntimeInfoForFakeServer(t, srv)
	client := NewClientWithPath(infoPath)
	stream := newTestStream(client)

	ctx, cancel := context.WithCancel(context.Background())
	stream.Start(ctx)

	ch, _ := stream.Subscribe()
	cancel()

	deadline := time.After(2 * time.Second)
	for {
		select {
		case _, ok := <-ch:
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("subscriber channel was not closed after Start ctx cancel")
		}
	}
}
