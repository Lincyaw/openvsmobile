package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/Lincyaw/vscode-mobile/server/internal/claude"
	"github.com/Lincyaw/vscode-mobile/server/internal/diagnostics"
	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

func writeBridgeMetadata(t *testing.T, path string, metadata vscode.BridgeMetadata) {
	t.Helper()
	if metadata.ProtocolVersion == "" {
		metadata.ProtocolVersion = "2026-04-20"
	}
	if metadata.Capabilities == nil {
		metadata.Capabilities = map[string]any{}
	}
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

func newBridgeEnabledServer(t *testing.T, manager *vscode.BridgeManager) *httptest.Server {
	t.Helper()
	sessionIndex := claude.NewSessionIndex(t.TempDir())
	pm := claude.NewProcessManager("/nonexistent/claude", ".")
	srv := NewServer(newMockFS(), sessionIndex, pm, "", nil, terminal.NewManager(), diagnostics.NewRunner(10*time.Second))
	srv.SetBridgeManager(manager)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return ts
}

func waitForReadyCapabilities(t *testing.T, baseURL string) vscode.BridgeCapabilitiesDocument {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(baseURL + "/bridge/capabilities")
		if err != nil {
			time.Sleep(20 * time.Millisecond)
			continue
		}
		if resp.StatusCode == http.StatusOK {
			defer resp.Body.Close()
			var doc vscode.BridgeCapabilitiesDocument
			if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
				t.Fatalf("decode capabilities: %v", err)
			}
			return doc
		}
		_ = resp.Body.Close()
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timed out waiting for bridge capabilities")
	return vscode.BridgeCapabilitiesDocument{}
}

func waitForNotReadyBridgeError(t *testing.T, baseURL string) bridgeErrorDetail {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := http.Get(baseURL + "/bridge/capabilities")
		if err != nil {
			time.Sleep(20 * time.Millisecond)
			continue
		}
		if resp.StatusCode == http.StatusServiceUnavailable {
			defer resp.Body.Close()
			var body bridgeErrorDetail
			if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
				t.Fatalf("decode bridge error: %v", err)
			}
			if body.Code == "bridge_not_ready" {
				return body
			}
		} else {
			_ = resp.Body.Close()
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timed out waiting for bridge_not_ready error")
	return bridgeErrorDetail{}
}

func dialBridgeEvents(t *testing.T, baseURL string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(baseURL, "http") + "/bridge/ws/events"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial bridge events websocket: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func readBridgeEvent(t *testing.T, conn *websocket.Conn) vscode.BridgeEvent {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	var event vscode.BridgeEvent
	if err := conn.ReadJSON(&event); err != nil {
		t.Fatalf("read bridge event: %v", err)
	}
	return event
}

func requirePayloadValue(t *testing.T, payload map[string]any, key string) any {
	t.Helper()
	value, ok := payload[key]
	if !ok {
		t.Fatalf("payload missing %q: %#v", key, payload)
	}
	return value
}

func requireBoolCapability(t *testing.T, payload map[string]any, capability string, want bool) {
	t.Helper()
	capabilities, ok := requirePayloadValue(t, payload, "capabilities").(map[string]any)
	if !ok {
		t.Fatalf("payload capabilities = %#v, want map[string]any", payload["capabilities"])
	}
	entry, ok := capabilities[capability].(map[string]any)
	if !ok {
		t.Fatalf("capability %q = %#v, want map[string]any", capability, capabilities[capability])
	}
	if entry["enabled"] != want {
		t.Fatalf("capability %q enabled = %#v, want %v", capability, entry["enabled"], want)
	}
}

func requireEventPayload(t *testing.T, event vscode.BridgeEvent) map[string]any {
	t.Helper()
	payload, ok := event.Payload.(map[string]any)
	if !ok {
		t.Fatalf("event payload = %#v, want map[string]any", event.Payload)
	}
	return payload
}

func TestBridgeCapabilities_NotReadyReturnsStructuredError(t *testing.T) {
	ts, _, _ := newTestServer(t, "")

	resp, err := http.Get(ts.URL + "/bridge/capabilities")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusServiceUnavailable)
	}

	var body bridgeErrorDetail
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if body.Code != "bridge_not_ready" {
		t.Fatalf("error code = %q, want %q", body.Code, "bridge_not_ready")
	}
	if body.Message == "" {
		t.Fatal("expected bridge_not_ready message to be non-empty")
	}
}

func TestBridgeCapabilities_ReadyReturnsRFCDocument(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{MetadataPath: metadataPath, PollInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager.Start(ctx)
	defer manager.Close()

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:    "gen-1",
		State:         "ready",
		BridgeVersion: "0.1.0",
		Capabilities:  map[string]any{},
	})

	ts := newBridgeEnabledServer(t, manager)
	doc := waitForReadyCapabilities(t, ts.URL)
	if doc.ProtocolVersion == "" {
		t.Fatal("expected protocolVersion in capabilities response")
	}
	if doc.BridgeVersion != "0.1.0" {
		t.Fatalf("bridgeVersion = %q, want %q", doc.BridgeVersion, "0.1.0")
	}
	if len(doc.Capabilities) != 0 {
		t.Fatalf("capabilities len = %d, want 0", len(doc.Capabilities))
	}
}

func TestBridgeCapabilities_PreservesEditorFeatureMatrix(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{MetadataPath: metadataPath, PollInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager.Start(ctx)
	defer manager.Close()

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:      "gen-editor",
		State:           "ready",
		ProtocolVersion: "2026-04-20",
		BridgeVersion:   "0.3.0",
		Capabilities: map[string]any{
			"diagnostics": map[string]any{"enabled": true, "push": true},
			"completion":  map[string]any{"enabled": true, "insertTextFormat": true, "textEdit": true},
			"hover":       map[string]any{"enabled": true},
			"definition":  map[string]any{"enabled": true},
			"references":  map[string]any{"enabled": true},
			"signatureHelp": map[string]any{
				"enabled": true,
			},
			"formatting":      map[string]any{"enabled": false},
			"codeActions":     map[string]any{"enabled": true},
			"rename":          map[string]any{"enabled": false},
			"documentSymbols": map[string]any{"enabled": true},
		},
	})

	ts := newBridgeEnabledServer(t, manager)
	doc := waitForReadyCapabilities(t, ts.URL)

	if doc.BridgeVersion != "0.3.0" {
		t.Fatalf("bridgeVersion = %q, want %q", doc.BridgeVersion, "0.3.0")
	}
	requireBoolCapability(t, map[string]any{"capabilities": doc.Capabilities}, "diagnostics", true)
	requireBoolCapability(t, map[string]any{"capabilities": doc.Capabilities}, "completion", true)
	requireBoolCapability(t, map[string]any{"capabilities": doc.Capabilities}, "formatting", false)
	requireBoolCapability(t, map[string]any{"capabilities": doc.Capabilities}, "rename", false)
	requireBoolCapability(t, map[string]any{"capabilities": doc.Capabilities}, "documentSymbols", true)
}

func TestBridgeCapabilities_NotReadyWindowRecoversToUpdatedCapabilities(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{MetadataPath: metadataPath, PollInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager.Start(ctx)
	defer manager.Close()

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation: "gen-1",
		State:      "ready",
		Capabilities: map[string]any{
			"workspace": map[string]any{"enabled": false},
		},
	})

	ts := newBridgeEnabledServer(t, manager)
	initial := waitForReadyCapabilities(t, ts.URL)
	workspace, ok := initial.Capabilities["workspace"].(map[string]any)
	if !ok || workspace["enabled"] != false {
		t.Fatalf("initial workspace capability = %#v, want enabled=false", initial.Capabilities["workspace"])
	}

	if err := os.Remove(metadataPath); err != nil {
		t.Fatalf("remove metadata: %v", err)
	}

	notReady := waitForNotReadyBridgeError(t, ts.URL)
	if notReady.Message == "" {
		t.Fatal("expected bridge_not_ready message during reconnect window")
	}

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation: "gen-2",
		State:      "ready",
		Capabilities: map[string]any{
			"workspace": map[string]any{"enabled": true},
		},
	})

	recovered := waitForReadyCapabilities(t, ts.URL)
	workspace, ok = recovered.Capabilities["workspace"].(map[string]any)
	if !ok || workspace["enabled"] != true {
		t.Fatalf("recovered workspace capability = %#v, want enabled=true", recovered.Capabilities["workspace"])
	}
}

func TestBridgeEventsWebSocket_ReplaysReadyThenBroadcastsRestartSequence(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{MetadataPath: metadataPath, PollInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager.Start(ctx)
	defer manager.Close()

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:   "gen-1",
		State:        "ready",
		Capabilities: map[string]any{},
	})

	ts := newBridgeEnabledServer(t, manager)
	conn := dialBridgeEvents(t, ts.URL)

	ready := readBridgeEvent(t, conn)
	if ready.Type != "bridge/ready" {
		t.Fatalf("first event type = %q, want bridge/ready", ready.Type)
	}

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:   "gen-2",
		State:        "ready",
		Capabilities: map[string]any{},
	})

	restarted := readBridgeEvent(t, conn)
	if restarted.Type != "bridge/restarted" {
		t.Fatalf("second event type = %q, want bridge/restarted", restarted.Type)
	}
	ready = readBridgeEvent(t, conn)
	if ready.Type != "bridge/ready" {
		t.Fatalf("third event type = %q, want bridge/ready", ready.Type)
	}
}

func TestBridgeEventsWebSocket_StableEnvelopeCarriesLifecyclePayloads(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{MetadataPath: metadataPath, PollInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager.Start(ctx)
	defer manager.Close()

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:      "gen-1",
		State:           "ready",
		ProtocolVersion: "2026-04-20",
		BridgeVersion:   "0.1.0",
		Capabilities: map[string]any{
			"workspace": map[string]any{"enabled": false},
		},
	})

	ts := newBridgeEnabledServer(t, manager)
	conn := dialBridgeEvents(t, ts.URL)

	ready := readBridgeEvent(t, conn)
	if ready.Type != "bridge/ready" {
		t.Fatalf("first event type = %q, want bridge/ready", ready.Type)
	}
	readyPayload := requireEventPayload(t, ready)
	if got := requirePayloadValue(t, readyPayload, "generation"); got != "gen-1" {
		t.Fatalf("ready generation = %#v, want %q", got, "gen-1")
	}
	if capabilities, ok := readyPayload["capabilities"]; ok {
		if got := requirePayloadValue(t, readyPayload, "bridgeVersion"); got != "0.1.0" {
			t.Fatalf("initial ready bridgeVersion = %#v, want %q", got, "0.1.0")
		}
		requireBoolCapability(t, map[string]any{"capabilities": capabilities}, "workspace", false)
	}

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:      "gen-2",
		State:           "ready",
		ProtocolVersion: "2026-04-20",
		BridgeVersion:   "0.2.0",
		Capabilities: map[string]any{
			"workspace": map[string]any{"enabled": true},
		},
	})

	restarted := readBridgeEvent(t, conn)
	if restarted.Type != "bridge/restarted" {
		t.Fatalf("second event type = %q, want bridge/restarted", restarted.Type)
	}
	restartedPayload := requireEventPayload(t, restarted)
	if got := requirePayloadValue(t, restartedPayload, "generation"); got != "gen-2" {
		t.Fatalf("restarted generation = %#v, want %q", got, "gen-2")
	}
	if got := requirePayloadValue(t, restartedPayload, "previousGeneration"); got != "gen-1" {
		t.Fatalf("restarted previousGeneration = %#v, want %q", got, "gen-1")
	}

	ready = readBridgeEvent(t, conn)
	if ready.Type != "bridge/ready" {
		t.Fatalf("third event type = %q, want bridge/ready", ready.Type)
	}
	readyPayload = requireEventPayload(t, ready)
	if got := requirePayloadValue(t, readyPayload, "generation"); got != "gen-2" {
		t.Fatalf("recovered ready generation = %#v, want %q", got, "gen-2")
	}
	if got := requirePayloadValue(t, readyPayload, "bridgeVersion"); got != "0.2.0" {
		t.Fatalf("recovered ready bridgeVersion = %#v, want %q", got, "0.2.0")
	}
	requireBoolCapability(t, readyPayload, "workspace", true)
}

func TestBridgeEventsWebSocket_ForwardsDiagnosticsChangedEvents(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{MetadataPath: metadataPath, PollInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager.Start(ctx)
	defer manager.Close()

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:      "gen-1",
		State:           "ready",
		ProtocolVersion: "2026-04-20",
		Capabilities: map[string]any{
			"diagnostics": map[string]any{"enabled": true},
		},
	})

	ts := newBridgeEnabledServer(t, manager)
	conn := dialBridgeEvents(t, ts.URL)
	ready := readBridgeEvent(t, conn)
	if ready.Type != "bridge/ready" {
		t.Fatalf("first event type = %q, want bridge/ready", ready.Type)
	}

	manager.Publish(vscode.BridgeEvent{
		Type: "bridge/diagnosticsChanged",
		Payload: map[string]any{
			"path":    "/workspace/lib/main.dart",
			"version": 9,
			"diagnostics": []any{
				map[string]any{
					"severity": "warning",
					"message":  "Unused import",
					"source":   "dart-analyzer",
				},
			},
		},
	})

	event := readBridgeEvent(t, conn)
	if event.Type != "bridge/diagnosticsChanged" {
		t.Fatalf("event type = %q, want bridge/diagnosticsChanged", event.Type)
	}
	payload := requireEventPayload(t, event)
	if got := requirePayloadValue(t, payload, "path"); got != "/workspace/lib/main.dart" {
		t.Fatalf("path = %#v, want %q", got, "/workspace/lib/main.dart")
	}
	if got := requirePayloadValue(t, payload, "version"); got != float64(9) {
		t.Fatalf("version = %#v, want 9", got)
	}
	diagnostics, ok := requirePayloadValue(t, payload, "diagnostics").([]any)
	if !ok || len(diagnostics) != 1 {
		t.Fatalf("diagnostics = %#v, want 1 entry", payload["diagnostics"])
	}
	first, ok := diagnostics[0].(map[string]any)
	if !ok {
		t.Fatalf("diagnostic[0] = %#v, want map[string]any", diagnostics[0])
	}
	if first["message"] != "Unused import" {
		t.Fatalf("diagnostic message = %#v, want %q", first["message"], "Unused import")
	}
}

func TestBridgeEventsWebSocket_DropsDisconnectedClientsWithoutBlockingLiveOnes(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{MetadataPath: metadataPath, PollInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager.Start(ctx)
	defer manager.Close()

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:   "gen-1",
		State:        "ready",
		Capabilities: map[string]any{},
	})

	ts := newBridgeEnabledServer(t, manager)
	deadConn := dialBridgeEvents(t, ts.URL)
	liveConn := dialBridgeEvents(t, ts.URL)
	_ = readBridgeEvent(t, deadConn)
	_ = readBridgeEvent(t, liveConn)
	_ = deadConn.Close()

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:   "gen-2",
		State:        "ready",
		Capabilities: map[string]any{},
	})

	restarted := readBridgeEvent(t, liveConn)
	if restarted.Type != "bridge/restarted" {
		t.Fatalf("live event type = %q, want bridge/restarted", restarted.Type)
	}
	ready := readBridgeEvent(t, liveConn)
	if ready.Type != "bridge/ready" {
		t.Fatalf("live event type = %q, want bridge/ready", ready.Type)
	}
}

func TestBridgeEventsWebSocket_BroadcastsRestartedThenReadyAfterNotReadyWindow(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{MetadataPath: metadataPath, PollInterval: 20 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager.Start(ctx)
	defer manager.Close()

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:   "gen-1",
		State:        "ready",
		Capabilities: map[string]any{},
	})

	ts := newBridgeEnabledServer(t, manager)
	conn := dialBridgeEvents(t, ts.URL)

	ready := readBridgeEvent(t, conn)
	if ready.Type != "bridge/ready" {
		t.Fatalf("first event type = %q, want bridge/ready", ready.Type)
	}

	if err := os.Remove(metadataPath); err != nil {
		t.Fatalf("remove metadata: %v", err)
	}
	_ = waitForNotReadyBridgeError(t, ts.URL)

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:   "gen-2",
		State:        "ready",
		Capabilities: map[string]any{},
	})

	restarted := readBridgeEvent(t, conn)
	if restarted.Type != "bridge/restarted" {
		t.Fatalf("second event type = %q, want bridge/restarted", restarted.Type)
	}
	ready = readBridgeEvent(t, conn)
	if ready.Type != "bridge/ready" {
		t.Fatalf("third event type = %q, want bridge/ready", ready.Type)
	}
}

func TestBridgeCapabilities_ReconnectWindowReturnsNotReadyUntilRecoveryCompletes(t *testing.T) {
	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:   "gen-1",
		State:        "ready",
		Capabilities: map[string]any{},
	})

	client := vscode.NewClient()
	reconnectStarted := make(chan struct{})
	reconnectRelease := make(chan struct{})
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{
		MetadataPath: metadataPath,
		Client:       client,
		ReconnectFn: func(ctx context.Context) error {
			close(reconnectStarted)
			select {
			case <-reconnectRelease:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		},
	})
	manager.Start(context.Background())
	defer manager.Close()

	ts := newBridgeEnabledServer(t, manager)
	_ = waitForReadyCapabilities(t, ts.URL)

	manager.NotifyTransportLost(errors.New("transport closed"))

	select {
	case <-reconnectStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for reconnect to start")
	}

	resp, err := http.Get(ts.URL + "/bridge/capabilities")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusServiceUnavailable)
	}
	var errBody bridgeErrorDetail
	if err := json.NewDecoder(resp.Body).Decode(&errBody); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errBody.Code != "bridge_not_ready" {
		t.Fatalf("error code = %q, want bridge_not_ready", errBody.Code)
	}

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:   "gen-2",
		State:        "ready",
		UpdatedAt:    time.Now().UTC(),
		Capabilities: map[string]any{},
	})
	close(reconnectRelease)

	doc := waitForReadyCapabilities(t, ts.URL)
	if doc.ProtocolVersion == "" {
		t.Fatal("expected ready capabilities after reconnect")
	}
}
