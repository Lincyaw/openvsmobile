package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

type terminalSessionEnvelope map[string]any

type terminalStreamEnvelope struct {
	Type    string                 `json:"type"`
	Data    string                 `json:"data,omitempty"`
	Error   string                 `json:"error,omitempty"`
	Exit    any                    `json:"exit,omitempty"`
	Meta    map[string]any         `json:"meta,omitempty"`
	Ready   map[string]any         `json:"ready,omitempty"`
	Session map[string]any         `json:"session,omitempty"`
	Extra   map[string]interface{} `json:"-"`
}

type terminalLifecycleEvent struct {
	Type    string         `json:"type"`
	Payload map[string]any `json:"payload"`
}

func newReadyTerminalBridgeServer(t *testing.T) *httptest.Server {
	t.Helper()

	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{
		MetadataPath: metadataPath,
		PollInterval: 20 * time.Millisecond,
	})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	manager.Start(ctx)
	t.Cleanup(manager.Close)

	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:    "gen-terminal-tests",
		State:         "ready",
		BridgeVersion: "test",
		Capabilities: map[string]any{
			"terminal": map[string]any{"enabled": true},
		},
	})

	ts := newBridgeEnabledServer(t, manager)
	_ = waitForReadyCapabilities(t, ts.URL)
	return ts
}

func postTerminalJSON(t *testing.T, baseURL, path string, payload any) (*http.Response, map[string]any) {
	t.Helper()

	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal request body: %v", err)
	}

	resp, err := http.Post(baseURL+path, "application/json", strings.NewReader(string(body)))
	if err != nil {
		t.Fatalf("POST %s failed: %v", path, err)
	}

	var decoded map[string]any
	if resp.Header.Get("Content-Type") == "application/json" || strings.Contains(resp.Header.Get("Content-Type"), "application/json") {
		_ = json.NewDecoder(resp.Body).Decode(&decoded)
	}
	return resp, decoded
}

func mustCreateTerminalSession(t *testing.T, baseURL string) terminalSessionEnvelope {
	t.Helper()

	resp, body := postTerminalJSON(t, baseURL, "/bridge/terminal/create", map[string]any{
		"name":    "primary",
		"cwd":     t.TempDir(),
		"profile": "bash",
		"rows":    24,
		"cols":    80,
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("create status = %d, want %d body=%#v", resp.StatusCode, http.StatusOK, body)
	}
	requireTerminalSessionFields(t, body)
	return terminalSessionEnvelope(body)
}

func requireTerminalSessionFields(t *testing.T, body map[string]any) {
	t.Helper()
	for _, key := range []string{"id", "name", "cwd", "profile", "state"} {
		value, ok := body[key]
		if !ok {
			t.Fatalf("session body missing %q: %#v", key, body)
		}
		if str, ok := value.(string); ok && str == "" {
			t.Fatalf("session field %q should not be empty: %#v", key, body)
		}
	}
}

func dialTerminalStream(t *testing.T, baseURL, sessionID string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(baseURL, "http") + "/bridge/ws/terminal/" + sessionID
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial terminal websocket: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func readTerminalEnvelope(t *testing.T, conn *websocket.Conn) terminalStreamEnvelope {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	var msg terminalStreamEnvelope
	if err := conn.ReadJSON(&msg); err != nil {
		t.Fatalf("read terminal stream envelope: %v", err)
	}
	return msg
}

func waitForTerminalOutput(t *testing.T, conn *websocket.Conn, wantSubstring string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		msg := readTerminalEnvelope(t, conn)
		switch msg.Type {
		case "output":
			payload := msg.Data
			if decoded, err := base64.StdEncoding.DecodeString(payload); err == nil {
				payload = string(decoded)
			}
			if strings.Contains(payload, wantSubstring) {
				return
			}
		case "error":
			t.Fatalf("received terminal error while waiting for output: %s", msg.Error)
		}
	}
	t.Fatalf("timed out waiting for output containing %q", wantSubstring)
}

func waitForTerminalEventType(t *testing.T, conn *websocket.Conn, want string) terminalLifecycleEvent {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		var event terminalLifecycleEvent
		if err := conn.ReadJSON(&event); err != nil {
			t.Fatalf("read terminal lifecycle event: %v", err)
		}
		if event.Type == want {
			return event
		}
	}
	t.Fatalf("timed out waiting for terminal lifecycle event %q", want)
	return terminalLifecycleEvent{}
}

func waitForTerminalExitEnvelope(t *testing.T, conn *websocket.Conn) terminalStreamEnvelope {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		msg := readTerminalEnvelope(t, conn)
		switch msg.Type {
		case "exit":
			return msg
		case "error":
			t.Fatalf("received terminal error before exit: %s", msg.Error)
		}
	}
	t.Fatal("timed out waiting for terminal exit envelope")
	return terminalStreamEnvelope{}
}

func TestTerminalBridgeSessionLifecycleRESTContract(t *testing.T) {
	ts := newReadyTerminalBridgeServer(t)

	created := mustCreateTerminalSession(t, ts.URL)
	createdID, _ := created["id"].(string)
	if created["state"] != "running" {
		t.Fatalf("created session state = %#v, want running", created["state"])
	}

	resp, err := http.Get(ts.URL + "/bridge/terminal/sessions")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("sessions status = %d, want %d", resp.StatusCode, http.StatusOK)
	}

	var sessions []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&sessions); err != nil {
		t.Fatalf("decode sessions list: %v", err)
	}
	var listed map[string]any
	for _, session := range sessions {
		if session["id"] == createdID {
			listed = session
			break
		}
	}
	if listed == nil {
		t.Fatalf("created session %q not found in list %#v", createdID, sessions)
	}
	requireTerminalSessionFields(t, listed)

	attachResp, attached := postTerminalJSON(t, ts.URL, "/bridge/terminal/attach", map[string]any{"id": createdID})
	defer attachResp.Body.Close()
	if attachResp.StatusCode != http.StatusOK {
		t.Fatalf("attach status = %d, want %d body=%#v", attachResp.StatusCode, http.StatusOK, attached)
	}
	if attached["id"] != createdID {
		t.Fatalf("attach returned id = %#v, want %q", attached["id"], createdID)
	}

	renameResp, renamed := postTerminalJSON(t, ts.URL, "/bridge/terminal/rename", map[string]any{"id": createdID, "name": "renamed"})
	defer renameResp.Body.Close()
	if renameResp.StatusCode != http.StatusOK {
		t.Fatalf("rename status = %d, want %d body=%#v", renameResp.StatusCode, http.StatusOK, renamed)
	}
	if renamed["name"] != "renamed" {
		t.Fatalf("rename returned name = %#v, want renamed", renamed["name"])
	}

	resizeResp, resized := postTerminalJSON(t, ts.URL, "/bridge/terminal/resize", map[string]any{"id": createdID, "rows": 40, "cols": 120})
	defer resizeResp.Body.Close()
	if resizeResp.StatusCode != http.StatusOK {
		t.Fatalf("resize status = %d, want %d body=%#v", resizeResp.StatusCode, http.StatusOK, resized)
	}
	if resized["id"] != createdID {
		t.Fatalf("resize returned id = %#v, want %q", resized["id"], createdID)
	}

	splitResp, split := postTerminalJSON(t, ts.URL, "/bridge/terminal/split", map[string]any{"parentId": createdID})
	defer splitResp.Body.Close()
	if splitResp.StatusCode != http.StatusOK {
		t.Fatalf("split status = %d, want %d body=%#v", splitResp.StatusCode, http.StatusOK, split)
	}
	requireTerminalSessionFields(t, split)
	if split["id"] == createdID {
		t.Fatalf("split session id = %#v, want different from parent %q", split["id"], createdID)
	}

	closeResp, closeBody := postTerminalJSON(t, ts.URL, "/bridge/terminal/close", map[string]any{"id": createdID})
	defer closeResp.Body.Close()
	if closeResp.StatusCode != http.StatusOK {
		t.Fatalf("close status = %d, want %d body=%#v", closeResp.StatusCode, http.StatusOK, closeBody)
	}
	if closeBody["state"] != "exited" {
		t.Fatalf("closed session state = %#v, want exited", closeBody["state"])
	}
}

func TestTerminalBridgeWebSocketReadyInputOutputExitAndReconnect(t *testing.T) {
	ts := newReadyTerminalBridgeServer(t)
	created := mustCreateTerminalSession(t, ts.URL)
	sessionID, _ := created["id"].(string)

	conn := dialTerminalStream(t, ts.URL, sessionID)
	ready := readTerminalEnvelope(t, conn)
	if ready.Type != "ready" {
		t.Fatalf("initial stream envelope type = %q, want ready", ready.Type)
	}

	encodedInput := base64.StdEncoding.EncodeToString([]byte("echo bridge-terminal-test\n"))
	if err := conn.WriteJSON(map[string]any{"type": "input", "data": encodedInput}); err != nil {
		t.Fatalf("write input frame: %v", err)
	}
	waitForTerminalOutput(t, conn, "bridge-terminal-test")

	if err := conn.Close(); err != nil {
		t.Fatalf("close first websocket: %v", err)
	}

	reconnected := dialTerminalStream(t, ts.URL, sessionID)
	ready = readTerminalEnvelope(t, reconnected)
	if ready.Type != "ready" {
		t.Fatalf("reconnected stream envelope type = %q, want ready", ready.Type)
	}

	encodedExit := base64.StdEncoding.EncodeToString([]byte("exit\n"))
	if err := reconnected.WriteJSON(map[string]any{"type": "input", "data": encodedExit}); err != nil {
		t.Fatalf("write exit frame: %v", err)
	}

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		msg := readTerminalEnvelope(t, reconnected)
		if msg.Type == "exit" {
			return
		}
		if msg.Type == "error" {
			t.Fatalf("received terminal error before exit: %s", msg.Error)
		}
	}
	t.Fatal("timed out waiting for terminal exit envelope")
}

func TestTerminalBridgeExitedSessionReattachReplaysBacklogAndExplicitCloseEmitsClosedEvent(t *testing.T) {
	ts, _, _ := newTestServer(t, "")
	events := dialBridgeEvents(t, ts.URL)

	createdResp, created := postTerminalJSON(t, ts.URL, "/bridge/terminal/create", map[string]any{
		"name":    "exit-bridge",
		"cwd":     t.TempDir(),
		"profile": "bash",
		"rows":    24,
		"cols":    80,
	})
	defer createdResp.Body.Close()
	if createdResp.StatusCode != http.StatusOK {
		t.Fatalf("create status = %d, want %d body=%#v", createdResp.StatusCode, http.StatusOK, created)
	}
	sessionID, _ := created["id"].(string)
	_ = waitForTerminalEventType(t, events, "terminal/sessionCreated")

	conn := dialTerminalStream(t, ts.URL, sessionID)
	ready := readTerminalEnvelope(t, conn)
	if ready.Type != "ready" {
		t.Fatalf("initial stream envelope type = %q, want ready", ready.Type)
	}

	encodedExit := base64.StdEncoding.EncodeToString([]byte("echo exited-backlog\nexit 9\n"))
	if err := conn.WriteJSON(map[string]any{"type": "input", "data": encodedExit}); err != nil {
		t.Fatalf("write exit frame: %v", err)
	}
	waitForTerminalOutput(t, conn, "exited-backlog")
	_ = waitForTerminalExitEnvelope(t, conn)
	if err := conn.Close(); err != nil {
		t.Fatalf("close exited websocket: %v", err)
	}

	attachResp, attached := postTerminalJSON(t, ts.URL, "/bridge/terminal/attach", map[string]any{"id": sessionID})
	defer attachResp.Body.Close()
	if attachResp.StatusCode != http.StatusOK {
		t.Fatalf("attach exited status = %d, want %d body=%#v", attachResp.StatusCode, http.StatusOK, attached)
	}
	if attached["state"] != "exited" {
		t.Fatalf("attached exited state = %#v, want exited", attached["state"])
	}
	if got, ok := attached["exitCode"].(float64); !ok || got != 9 {
		t.Fatalf("attached exitCode = %#v, want 9", attached["exitCode"])
	}

	reconnected := dialTerminalStream(t, ts.URL, sessionID)
	ready = readTerminalEnvelope(t, reconnected)
	if ready.Type != "ready" {
		t.Fatalf("reattached stream envelope type = %q, want ready", ready.Type)
	}
	if ready.Session["state"] != "exited" {
		t.Fatalf("ready session state = %#v, want exited", ready.Session["state"])
	}
	waitForTerminalOutput(t, reconnected, "exited-backlog")
	_ = waitForTerminalExitEnvelope(t, reconnected)

	closeResp, closeBody := postTerminalJSON(t, ts.URL, "/bridge/terminal/close", map[string]any{"id": sessionID})
	defer closeResp.Body.Close()
	if closeResp.StatusCode != http.StatusOK {
		t.Fatalf("close exited status = %d, want %d body=%#v", closeResp.StatusCode, http.StatusOK, closeBody)
	}
	if closeBody["state"] != "exited" {
		t.Fatalf("closed session state = %#v, want exited", closeBody["state"])
	}
	if got, ok := closeBody["exitCode"].(float64); !ok || got != 9 {
		t.Fatalf("closed exitCode = %#v, want 9", closeBody["exitCode"])
	}

	closedEvent := waitForTerminalEventType(t, events, "terminal/sessionClosed")
	if closedEvent.Payload["id"] != sessionID {
		t.Fatalf("closed event id = %#v, want %q", closedEvent.Payload["id"], sessionID)
	}
	if closedEvent.Payload["state"] != "exited" {
		t.Fatalf("closed event state = %#v, want exited", closedEvent.Payload["state"])
	}
	if got, ok := closedEvent.Payload["exitCode"].(float64); !ok || got != 9 {
		t.Fatalf("closed event exitCode = %#v, want 9", closedEvent.Payload["exitCode"])
	}

	missingResp, missingBody := postTerminalJSON(t, ts.URL, "/bridge/terminal/attach", map[string]any{"id": sessionID})
	defer missingResp.Body.Close()
	if missingResp.StatusCode != http.StatusNotFound {
		t.Fatalf("attach after close status = %d, want %d body=%#v", missingResp.StatusCode, http.StatusNotFound, missingBody)
	}
}

func TestTerminalBridgeLifecycleEventsFlowThroughUnifiedEventStreamWithoutBridgeManagerDependency(t *testing.T) {
	ts, _, _ := newTestServer(t, "")
	conn := dialBridgeEvents(t, ts.URL)

	createdResp, created := postTerminalJSON(t, ts.URL, "/bridge/terminal/create", map[string]any{
		"name":    "events",
		"cwd":     t.TempDir(),
		"profile": "bash",
		"rows":    24,
		"cols":    80,
	})
	defer createdResp.Body.Close()
	if createdResp.StatusCode != http.StatusOK {
		t.Fatalf("create status = %d, want %d body=%#v", createdResp.StatusCode, http.StatusOK, created)
	}
	sessionID, _ := created["id"].(string)

	createdEvent := waitForTerminalEventType(t, conn, "terminal/sessionCreated")
	if createdEvent.Payload["id"] != sessionID {
		t.Fatalf("created event id = %#v, want %q", createdEvent.Payload["id"], sessionID)
	}

	renameResp, _ := postTerminalJSON(t, ts.URL, "/bridge/terminal/rename", map[string]any{"id": sessionID, "name": "events-renamed"})
	defer renameResp.Body.Close()
	if renameResp.StatusCode != http.StatusOK {
		t.Fatalf("rename status = %d, want %d", renameResp.StatusCode, http.StatusOK)
	}

	updatedEvent := waitForTerminalEventType(t, conn, "terminal/sessionUpdated")
	if updatedEvent.Payload["id"] != sessionID {
		t.Fatalf("updated event id = %#v, want %q", updatedEvent.Payload["id"], sessionID)
	}
	if updatedEvent.Payload["name"] != "events-renamed" {
		t.Fatalf("updated event name = %#v, want events-renamed", updatedEvent.Payload["name"])
	}

	closeResp, _ := postTerminalJSON(t, ts.URL, "/bridge/terminal/close", map[string]any{"id": sessionID})
	defer closeResp.Body.Close()
	if closeResp.StatusCode != http.StatusOK {
		t.Fatalf("close status = %d, want %d", closeResp.StatusCode, http.StatusOK)
	}

	closedEvent := waitForTerminalEventType(t, conn, "terminal/sessionClosed")
	if closedEvent.Payload["id"] != sessionID {
		t.Fatalf("closed event id = %#v, want %q", closedEvent.Payload["id"], sessionID)
	}
	if closedEvent.Payload["state"] != "exited" {
		t.Fatalf("closed event state = %#v, want exited", closedEvent.Payload["state"])
	}
}
