package vscode

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type fakeVSCodeServer struct {
	failHandshakeAttempts int32
	attempts              atomic.Int32
	messages              chan *ProtocolMessage
}

func newFakeVSCodeServer(t *testing.T, failHandshakeAttempts int) (*httptest.Server, *fakeVSCodeServer) {
	t.Helper()

	fake := &fakeVSCodeServer{
		failHandshakeAttempts: int32(failHandshakeAttempts),
		messages:              make(chan *ProtocolMessage, 32),
	}
	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade failed: %v", err)
			return
		}

		attempt := fake.attempts.Add(1)
		if attempt <= atomic.LoadInt32(&fake.failHandshakeAttempts) {
			_ = conn.Close()
			return
		}

		defer conn.Close()

		auth := mustReadProtocolMessage(t, conn)
		if auth.Type != ProtocolMessageControl {
			t.Errorf("auth message type = %v, want control", auth.Type)
			return
		}
		var authReq AuthRequest
		if err := json.Unmarshal(auth.Data, &authReq); err != nil {
			t.Errorf("unmarshal auth request: %v", err)
			return
		}
		if authReq.Type != "auth" {
			t.Errorf("auth request type = %q, want auth", authReq.Type)
			return
		}

		mustWriteControlJSON(t, conn, map[string]any{
			"type":       "sign",
			"data":       "challenge",
			"signedData": "challenge",
		})

		connType := mustReadProtocolMessage(t, conn)
		if connType.Type != ProtocolMessageControl {
			t.Errorf("connectionType message type = %v, want control", connType.Type)
			return
		}
		var connReq ConnectionTypeRequest
		if err := json.Unmarshal(connType.Data, &connReq); err != nil {
			t.Errorf("unmarshal connectionType request: %v", err)
			return
		}
		if connReq.Type != "connectionType" {
			t.Errorf("connectionType request type = %q, want connectionType", connReq.Type)
			return
		}

		mustWriteControlJSON(t, conn, map[string]any{"type": "ok"})

		for {
			msg, err := readProtocolMessage(conn)
			if err != nil {
				return
			}
			select {
			case fake.messages <- msg:
			default:
			}
		}
	}))
	t.Cleanup(ts.Close)

	return ts, fake
}

func mustReadProtocolMessage(t *testing.T, conn *websocket.Conn) *ProtocolMessage {
	t.Helper()
	msg, err := readProtocolMessage(conn)
	if err != nil {
		t.Fatalf("read protocol message: %v", err)
	}
	return msg
}

func readProtocolMessage(conn *websocket.Conn) (*ProtocolMessage, error) {
	_, raw, err := conn.ReadMessage()
	if err != nil {
		return nil, err
	}
	return DecodeProtocolMessage(bytes.NewReader(raw))
}

func mustWriteControlJSON(t *testing.T, conn *websocket.Conn, payload map[string]any) {
	t.Helper()
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal control payload: %v", err)
	}
	encoded := EncodeProtocolMessage(&ProtocolMessage{Type: ProtocolMessageControl, Data: data})
	if err := conn.WriteMessage(websocket.BinaryMessage, encoded); err != nil {
		t.Fatalf("write control payload: %v", err)
	}
}

func waitForProtocolMessage(t *testing.T, messages <-chan *ProtocolMessage, want ProtocolMessageType, timeout time.Duration) *ProtocolMessage {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case msg := <-messages:
			if msg.Type == want {
				return msg
			}
		case <-deadline:
			t.Fatalf("timed out waiting for protocol message type %v", want)
		}
	}
}

func writeBridgeMetadataFile(t *testing.T, path string, metadata BridgeMetadata) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir metadata dir: %v", err)
	}
	data, err := json.Marshal(metadata)
	if err != nil {
		t.Fatalf("marshal metadata: %v", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write metadata: %v", err)
	}
}

func mustReceiveBridgeEvent(t *testing.T, ch <-chan BridgeEvent, timeout time.Duration) BridgeEvent {
	t.Helper()
	select {
	case event := <-ch:
		return event
	case <-time.After(timeout):
		t.Fatal("timed out waiting for bridge event")
		return BridgeEvent{}
	}
}

func TestBridgeManager_ColdStartReportsNotReady(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := NewBridgeManager(BridgeManagerOptions{MetadataPath: metadataPath})
	manager.poll()

	_, err := manager.Capabilities()
	if err == nil {
		t.Fatal("expected bridge capabilities to be unavailable on cold start")
	}
	var bridgeErr *BridgeError
	if !errors.As(err, &bridgeErr) {
		t.Fatalf("error type = %T, want *BridgeError", err)
	}
	if bridgeErr.Code != "bridge_not_ready" {
		t.Fatalf("bridge error code = %q, want bridge_not_ready", bridgeErr.Code)
	}
	if !errors.Is(bridgeErr, os.ErrNotExist) {
		t.Fatalf("expected cold-start error to unwrap os.ErrNotExist, got %v", bridgeErr)
	}
}

func TestBridgeManager_ReadyTransitionPublishesCapabilities(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := NewBridgeManager(BridgeManagerOptions{MetadataPath: metadataPath})
	events, unsubscribe := manager.Subscribe(false)
	defer unsubscribe()

	writeBridgeMetadataFile(t, metadataPath, BridgeMetadata{
		ProtocolVersion: defaultBridgeProtocolVersion,
		Generation:      "gen-1",
		State:           bridgeStateReady,
		BridgeVersion:   "0.1.0",
		Capabilities: map[string]interface{}{
			"terminal": map[string]interface{}{"enabled": true},
		},
	})

	manager.poll()
	caps, err := manager.Capabilities()
	if err != nil {
		t.Fatalf("Capabilities failed after ready transition: %v", err)
	}
	if caps.ProtocolVersion != defaultBridgeProtocolVersion {
		t.Fatalf("protocolVersion = %q, want %q", caps.ProtocolVersion, defaultBridgeProtocolVersion)
	}
	if caps.BridgeVersion != "0.1.0" {
		t.Fatalf("bridgeVersion = %q, want 0.1.0", caps.BridgeVersion)
	}
	terminal, ok := caps.Capabilities["terminal"].(map[string]interface{})
	if !ok || terminal["enabled"] != true {
		t.Fatalf("terminal capability = %#v, want enabled=true", caps.Capabilities["terminal"])
	}

	ready := mustReceiveBridgeEvent(t, events, 2*time.Second)
	if ready.Type != "bridge/ready" {
		t.Fatalf("event type = %q, want bridge/ready", ready.Type)
	}
}

func TestBridgeManager_RestartDetectionBroadcastsRestartedThenReady(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := NewBridgeManager(BridgeManagerOptions{MetadataPath: metadataPath})
	events, unsubscribe := manager.Subscribe(false)
	defer unsubscribe()

	writeBridgeMetadataFile(t, metadataPath, BridgeMetadata{
		ProtocolVersion: defaultBridgeProtocolVersion,
		Generation:      "gen-1",
		State:           bridgeStateReady,
		Capabilities:    map[string]interface{}{"git": map[string]interface{}{"enabled": false}},
	})
	manager.poll()
	ready := mustReceiveBridgeEvent(t, events, 2*time.Second)
	if ready.Type != "bridge/ready" {
		t.Fatalf("initial event type = %q, want bridge/ready", ready.Type)
	}

	writeBridgeMetadataFile(t, metadataPath, BridgeMetadata{
		ProtocolVersion: defaultBridgeProtocolVersion,
		Generation:      "gen-2",
		State:           bridgeStateReady,
		Capabilities:    map[string]interface{}{"git": map[string]interface{}{"enabled": true}},
	})
	manager.poll()

	restarted := mustReceiveBridgeEvent(t, events, 2*time.Second)
	if restarted.Type != "bridge/restarted" {
		t.Fatalf("restart event type = %q, want bridge/restarted", restarted.Type)
	}
	restartPayload, ok := restarted.Payload.(map[string]interface{})
	if !ok {
		t.Fatalf("restart payload type = %T, want map", restarted.Payload)
	}
	if restartPayload["previousGeneration"] != "gen-1" || restartPayload["generation"] != "gen-2" {
		t.Fatalf("restart payload = %#v, want previousGeneration=gen-1 generation=gen-2", restartPayload)
	}

	ready = mustReceiveBridgeEvent(t, events, 2*time.Second)
	if ready.Type != "bridge/ready" {
		t.Fatalf("post-restart event type = %q, want bridge/ready", ready.Type)
	}
}

func TestBridgeManager_TransportDisconnectMarksBridgeNotReady(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	client := NewClient()
	manager := NewBridgeManager(BridgeManagerOptions{MetadataPath: metadataPath, Client: client})

	writeBridgeMetadataFile(t, metadataPath, BridgeMetadata{
		ProtocolVersion: defaultBridgeProtocolVersion,
		Generation:      "gen-1",
		State:           bridgeStateReady,
		Capabilities:    map[string]interface{}{"workspace": map[string]interface{}{"enabled": true}},
	})
	manager.poll()
	if _, err := manager.Capabilities(); err != nil {
		t.Fatalf("Capabilities before disconnect failed: %v", err)
	}

	client.onDisconnect(errors.New("transport closed"))

	_, err := manager.Capabilities()
	if err == nil {
		t.Fatal("expected bridge to become not-ready after transport loss")
	}
	var bridgeErr *BridgeError
	if !errors.As(err, &bridgeErr) {
		t.Fatalf("error type = %T, want *BridgeError", err)
	}
	if bridgeErr.Code != "bridge_not_ready" {
		t.Fatalf("bridge error code = %q, want bridge_not_ready", bridgeErr.Code)
	}
	if !strings.Contains(bridgeErr.Error(), "transport closed") {
		t.Fatalf("bridge error = %q, want transport cause", bridgeErr.Error())
	}
}

func TestReconnectWithRetry_RetriesAfterTransientFailure(t *testing.T) {
	ts, fake := newFakeVSCodeServer(t, 1)
	client := NewClient()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	start := time.Now()
	if err := client.ReconnectWithRetry(ctx, ts.URL, "", 3); err != nil {
		t.Fatalf("ReconnectWithRetry failed: %v", err)
	}
	defer client.Close()

	if got := fake.attempts.Load(); got != 2 {
		t.Fatalf("handshake attempts = %d, want 2", got)
	}
	if elapsed := time.Since(start); elapsed < time.Second {
		t.Fatalf("ReconnectWithRetry elapsed = %v, want at least one backoff interval", elapsed)
	}

	ctxMsg := waitForProtocolMessage(t, fake.messages, ProtocolMessageRegular, 2*time.Second)
	if len(ctxMsg.Data) == 0 {
		t.Fatal("expected IPC context bootstrap message after reconnect")
	}
}

func TestReconnectWithRetry_RecoversAfterDisconnectAndTransientReconnectFailure(t *testing.T) {
	ts, fake := newFakeVSCodeServer(t, 0)
	client := NewClient()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := client.Connect(ctx, ts.URL, ""); err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer client.Close()

	waitForProtocolMessage(t, fake.messages, ProtocolMessageRegular, 2*time.Second)

	// Fail the next reconnect handshake once, then allow the retry to succeed.
	atomic.StoreInt32(&fake.failHandshakeAttempts, fake.attempts.Load()+1)

	reconnectCtx, reconnectCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer reconnectCancel()

	start := time.Now()
	if err := client.ReconnectWithRetry(reconnectCtx, ts.URL, "", 3); err != nil {
		t.Fatalf("ReconnectWithRetry failed: %v", err)
	}

	if got := fake.attempts.Load(); got != 3 {
		t.Fatalf("handshake attempts = %d, want 3 (initial connect + failed reconnect + successful reconnect)", got)
	}
	if elapsed := time.Since(start); elapsed < time.Second {
		t.Fatalf("ReconnectWithRetry elapsed = %v, want at least one backoff interval", elapsed)
	}

	ctxMsg := waitForProtocolMessage(t, fake.messages, ProtocolMessageRegular, 2*time.Second)
	if len(ctxMsg.Data) == 0 {
		t.Fatal("expected IPC context bootstrap message after reconnect recovery")
	}
}

func TestReconnectWithRetry_StopsWhenContextExpires(t *testing.T) {
	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()

	start := time.Now()
	err := client.ReconnectWithRetry(ctx, "http://127.0.0.1:1", "", 5)
	if err == nil {
		t.Fatal("expected reconnect failure when context expires")
	}
	if err != context.DeadlineExceeded {
		t.Fatalf("ReconnectWithRetry error = %v, want %v", err, context.DeadlineExceeded)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("ReconnectWithRetry elapsed = %v, want prompt context cancellation", elapsed)
	}
}

func TestClientClose_SendsDisconnectFrame(t *testing.T) {
	ts, fake := newFakeVSCodeServer(t, 0)
	client := NewClient()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := client.Connect(ctx, ts.URL, ""); err != nil {
		t.Fatalf("Connect failed: %v", err)
	}

	waitForProtocolMessage(t, fake.messages, ProtocolMessageRegular, 2*time.Second)

	if err := client.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}

	disconnect := waitForProtocolMessage(t, fake.messages, ProtocolMessageDisconnect, 2*time.Second)
	if disconnect.Type != ProtocolMessageDisconnect {
		t.Fatalf("disconnect type = %v, want %v", disconnect.Type, ProtocolMessageDisconnect)
	}
}

func TestBridgeManager_DisconnectTriggersReconnectAndBroadcastsRecovery(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	writeBridgeMetadataFile(t, metadataPath, BridgeMetadata{
		ProtocolVersion: defaultBridgeProtocolVersion,
		Generation:      "gen-1",
		State:           bridgeStateReady,
		Capabilities:    map[string]interface{}{"workspace": map[string]interface{}{"enabled": true}},
	})

	client := NewClient()
	reconnectStarted := make(chan struct{})
	reconnectRelease := make(chan struct{})
	var reconnectCalls atomic.Int32
	manager := NewBridgeManager(BridgeManagerOptions{
		MetadataPath: metadataPath,
		Client:       client,
		ReconnectFn: func(ctx context.Context) error {
			reconnectCalls.Add(1)
			close(reconnectStarted)
			select {
			case <-reconnectRelease:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		},
	})
	events, unsubscribe := manager.Subscribe(false)
	defer unsubscribe()

	manager.poll()
	_ = mustReceiveBridgeEvent(t, events, 2*time.Second) // initial bridge/ready

	client.onDisconnect(errors.New("transport closed"))

	select {
	case <-reconnectStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for reconnect to start")
	}

	if reconnectCalls.Load() != 1 {
		t.Fatalf("reconnect calls = %d, want 1", reconnectCalls.Load())
	}
	if _, err := manager.Capabilities(); err == nil {
		t.Fatal("expected bridge capabilities to be unavailable during reconnect")
	}

	// The stale pre-restart metadata must not make the bridge ready again.
	manager.poll()
	if _, err := manager.Capabilities(); err == nil {
		t.Fatal("expected stale metadata to remain not-ready during reconnect")
	}

	writeBridgeMetadataFile(t, metadataPath, BridgeMetadata{
		ProtocolVersion: defaultBridgeProtocolVersion,
		Generation:      "gen-2",
		State:           bridgeStateReady,
		UpdatedAt:       time.Now().UTC(),
		Capabilities:    map[string]interface{}{"workspace": map[string]interface{}{"enabled": true}},
	})
	close(reconnectRelease)

	restarted := mustReceiveBridgeEvent(t, events, 2*time.Second)
	if restarted.Type != "bridge/restarted" {
		t.Fatalf("event type = %q, want bridge/restarted", restarted.Type)
	}
	ready := mustReceiveBridgeEvent(t, events, 2*time.Second)
	if ready.Type != "bridge/ready" {
		t.Fatalf("event type = %q, want bridge/ready", ready.Type)
	}

	caps, err := manager.Capabilities()
	if err != nil {
		t.Fatalf("Capabilities after reconnect failed: %v", err)
	}
	if caps.Capabilities["workspace"] == nil {
		t.Fatalf("expected workspace capability after reconnect, got %#v", caps.Capabilities)
	}
}

func TestBridgeManager_ReconnectFailureLeavesBridgeNotReady(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	writeBridgeMetadataFile(t, metadataPath, BridgeMetadata{
		ProtocolVersion: defaultBridgeProtocolVersion,
		Generation:      "gen-1",
		State:           bridgeStateReady,
	})

	client := NewClient()
	manager := NewBridgeManager(BridgeManagerOptions{
		MetadataPath:     metadataPath,
		Client:           client,
		ReconnectTimeout: 100 * time.Millisecond,
		ReconnectFn: func(ctx context.Context) error {
			<-ctx.Done()
			return ctx.Err()
		},
	})

	manager.poll()
	client.onDisconnect(errors.New("transport closed"))
	time.Sleep(150 * time.Millisecond)

	_, err := manager.Capabilities()
	if err == nil {
		t.Fatal("expected bridge capabilities to remain unavailable after reconnect failure")
	}
	var bridgeErr *BridgeError
	if !errors.As(err, &bridgeErr) {
		t.Fatalf("error type = %T, want *BridgeError", err)
	}
	if !strings.Contains(bridgeErr.Error(), "reconnect vscode transport") {
		t.Fatalf("bridge error = %q, want reconnect failure context", bridgeErr.Error())
	}
}

func TestClientReconnect_PreservesIPCClientReferences(t *testing.T) {
	ts, _ := newFakeVSCodeServer(t, 0)
	client := NewClient()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := client.Connect(ctx, ts.URL, ""); err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer client.Close()

	originalIPC := client.IPC()
	if originalIPC == nil {
		t.Fatal("expected IPC client after initial connect")
	}

	if err := client.Reconnect(ctx, ts.URL, ""); err != nil {
		t.Fatalf("Reconnect failed: %v", err)
	}
	if got := client.IPC(); got != originalIPC {
		t.Fatal("expected reconnect to preserve IPC client identity")
	}
}

func TestBridgeManager_ConcurrentDisconnectOnlyStartsOneReconnect(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	writeBridgeMetadataFile(t, metadataPath, BridgeMetadata{
		ProtocolVersion: defaultBridgeProtocolVersion,
		Generation:      "gen-1",
		State:           bridgeStateReady,
	})

	client := NewClient()
	reconnectRelease := make(chan struct{})
	var reconnectCalls atomic.Int32
	manager := NewBridgeManager(BridgeManagerOptions{
		MetadataPath: metadataPath,
		Client:       client,
		ReconnectFn: func(ctx context.Context) error {
			reconnectCalls.Add(1)
			select {
			case <-reconnectRelease:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		},
	})
	manager.poll()

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			client.onDisconnect(fmt.Errorf("transport closed %d", i))
		}(i)
	}
	wg.Wait()
	close(reconnectRelease)

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if reconnectCalls.Load() == 1 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("reconnect calls = %d, want 1", reconnectCalls.Load())
}
