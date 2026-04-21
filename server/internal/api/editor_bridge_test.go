package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/Lincyaw/vscode-mobile/server/internal/claude"
	"github.com/Lincyaw/vscode-mobile/server/internal/diagnostics"
	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

type apiEditorRequestCapture struct {
	Command string
	Payload map[string]any
}

func newAPIEditorRuntimeServer(t *testing.T, responseFor func(command string, payload map[string]any) any) (*httptest.Server, <-chan apiEditorRequestCapture) {
	t.Helper()

	requests := make(chan apiEditorRequestCapture, 32)
	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade failed: %v", err)
			return
		}
		defer conn.Close()

		auth := mustReadAPIEditorProtocolMessage(t, conn)
		if auth.Type != vscode.ProtocolMessageControl {
			t.Errorf("auth message type = %v, want control", auth.Type)
			return
		}
		var authReq vscode.AuthRequest
		if err := json.Unmarshal(auth.Data, &authReq); err != nil {
			t.Errorf("unmarshal auth request: %v", err)
			return
		}
		if authReq.Type != "auth" {
			t.Errorf("auth request type = %q, want auth", authReq.Type)
			return
		}
		mustWriteAPIEditorControlJSON(t, conn, map[string]any{
			"type":       "sign",
			"data":       "challenge",
			"signedData": "challenge",
		})

		connType := mustReadAPIEditorProtocolMessage(t, conn)
		if connType.Type != vscode.ProtocolMessageControl {
			t.Errorf("connection type message type = %v, want control", connType.Type)
			return
		}
		var connReq vscode.ConnectionTypeRequest
		if err := json.Unmarshal(connType.Data, &connReq); err != nil {
			t.Errorf("unmarshal connection type request: %v", err)
			return
		}
		if connReq.Type != "connectionType" {
			t.Errorf("connection type request type = %q, want connectionType", connReq.Type)
			return
		}
		mustWriteAPIEditorControlJSON(t, conn, map[string]any{"type": "ok"})

		bootstrap := mustReadAPIEditorProtocolMessage(t, conn)
		if bootstrap.Type != vscode.ProtocolMessageRegular {
			t.Errorf("bootstrap message type = %v, want regular", bootstrap.Type)
			return
		}
		mustWriteAPIEditorProtocolMessage(t, conn, &vscode.ProtocolMessage{
			Type: vscode.ProtocolMessageRegular,
			Data: vscode.EncodeIPCMessage([]interface{}{int(vscode.ResponseTypeInitialize)}, nil),
		})

		for {
			msg, err := readAPIEditorProtocolMessage(conn)
			if err != nil {
				return
			}
			if msg.Type != vscode.ProtocolMessageRegular {
				continue
			}
			header, body, err := vscode.DecodeIPCMessage(msg.Data)
			if err != nil {
				t.Errorf("decode ipc message: %v", err)
				return
			}
			hdr, ok := header.([]interface{})
			if !ok || len(hdr) < 4 {
				t.Errorf("header = %#v, want request header", header)
				return
			}
			reqType, ok := hdr[0].(int)
			if !ok {
				t.Errorf("request type header = %#v, want int", hdr[0])
				return
			}
			if vscode.RequestType(reqType) != vscode.RequestTypePromise {
				t.Errorf("request type = %d, want promise", reqType)
				return
			}
			id, ok := hdr[1].(int)
			if !ok {
				t.Errorf("request id header = %#v, want int", hdr[1])
				return
			}
			command, _ := hdr[3].(string)
			payload, _ := body.(map[string]any)
			if payload == nil {
				payload = map[string]any{}
			}

			select {
			case requests <- apiEditorRequestCapture{Command: command, Payload: payload}:
			default:
				t.Errorf("request buffer overflow for command %q", command)
				return
			}

			respBody := responseFor(command, payload)
			mustWriteAPIEditorProtocolMessage(t, conn, &vscode.ProtocolMessage{
				Type: vscode.ProtocolMessageRegular,
				Data: vscode.EncodeIPCMessage([]interface{}{int(vscode.ResponseTypePromiseSuccess), id}, respBody),
			})
		}
	}))

	t.Cleanup(ts.Close)
	return ts, requests
}

func mustReadAPIEditorProtocolMessage(t *testing.T, conn *websocket.Conn) *vscode.ProtocolMessage {
	t.Helper()
	msg, err := readAPIEditorProtocolMessage(conn)
	if err != nil {
		t.Fatalf("read protocol message: %v", err)
	}
	return msg
}

func readAPIEditorProtocolMessage(conn *websocket.Conn) (*vscode.ProtocolMessage, error) {
	_, raw, err := conn.ReadMessage()
	if err != nil {
		return nil, err
	}
	return vscode.DecodeProtocolMessage(bytes.NewReader(raw))
}

func mustWriteAPIEditorControlJSON(t *testing.T, conn *websocket.Conn, payload map[string]any) {
	t.Helper()
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal control payload: %v", err)
	}
	mustWriteAPIEditorProtocolMessage(t, conn, &vscode.ProtocolMessage{
		Type: vscode.ProtocolMessageControl,
		Data: data,
	})
}

func mustWriteAPIEditorProtocolMessage(t *testing.T, conn *websocket.Conn, msg *vscode.ProtocolMessage) {
	t.Helper()
	data := vscode.EncodeProtocolMessage(msg)
	if err := conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
		t.Fatalf("write protocol message: %v", err)
	}
}

func newAPIEditorBridgeServer(t *testing.T, fs *mockFS, responseFor func(command string, payload map[string]any) any) (*httptest.Server, <-chan apiEditorRequestCapture) {
	t.Helper()

	runtimeTS, requests := newAPIEditorRuntimeServer(t, responseFor)
	client := vscode.NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	if err := client.Connect(ctx, runtimeTS.URL, ""); err != nil {
		t.Fatalf("connect bridge client: %v", err)
	}
	t.Cleanup(func() {
		_ = client.Close()
	})

	sessionIndex := claude.NewSessionIndex(t.TempDir())
	pm := claude.NewProcessManager("/nonexistent/claude", ".")
	runner := diagnostics.NewRunner(10 * time.Second)
	srv := NewServer(fs, sessionIndex, pm, "", nil, terminal.NewManager(), runner)

	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{
		MetadataPath: metadataPath,
		Client:       client,
		PollInterval: 20 * time.Millisecond,
	})
	writeBridgeMetadata(t, metadataPath, vscode.BridgeMetadata{
		Generation:      "gen-editor",
		State:           "ready",
		ProtocolVersion: "2026-04-20",
		BridgeVersion:   "0.3.0",
		Capabilities: map[string]any{
			"diagnostics":     map[string]any{"enabled": true},
			"completion":      map[string]any{"enabled": true},
			"hover":           map[string]any{"enabled": true},
			"definition":      map[string]any{"enabled": true},
			"references":      map[string]any{"enabled": true},
			"signatureHelp":   map[string]any{"enabled": true},
			"formatting":      map[string]any{"enabled": true},
			"codeActions":     map[string]any{"enabled": true},
			"rename":          map[string]any{"enabled": true},
			"documentSymbols": map[string]any{"enabled": true},
		},
	})
	managerCtx, managerCancel := context.WithCancel(context.Background())
	t.Cleanup(managerCancel)
	manager.Start(managerCtx)
	t.Cleanup(manager.Close)
	waitForAPIEditorBridgeReady(t, manager)

	documents := vscode.NewDocumentSyncService(fs)
	srv.SetBridgeManager(manager)
	srv.SetDocumentSync(documents)
	srv.SetEditorService(vscode.NewEditorService(client, manager, documents))

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return ts, requests
}

func waitForAPIEditorBridgeReady(t *testing.T, manager *vscode.BridgeManager) {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := manager.Capabilities(); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timed out waiting for bridge manager readiness")
}

func TestBridgeEditorCompletionUsesUnsavedBufferAndVersionedContext(t *testing.T) {
	fs := newMockFS()
	workDir := t.TempDir()
	filePath := filepath.Join(workDir, "main.dart")
	fs.files[filePath] = []byte("print('disk');\n")

	ts, requests := newAPIEditorBridgeServer(t, fs, func(command string, payload map[string]any) any {
		if command != "completion" {
			return map[string]any{"items": []any{}}
		}
		return map[string]any{"isIncomplete": false, "items": []any{}}
	})

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/open", map[string]any{
		"path":    filePath,
		"version": 1,
		"content": "print('draft');\n",
	})
	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/change", map[string]any{
		"path":    filePath,
		"version": 2,
		"changes": []bridgeDocChange{{
			Range: &bridgeDocRange{
				Start: bridgeDocPosition{Line: 0, Character: 14},
				End:   bridgeDocPosition{Line: 0, Character: 14},
			},
			Text: " // unsaved",
		}},
	})

	position := map[string]any{"line": 0, "character": 7}
	resp, body := postBridgeDocumentRequest(t, ts.URL, "/bridge/editor/completion", map[string]any{
		"path":     filePath,
		"version":  2,
		"position": position,
		"workDir":  workDir,
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("completion status = %d, body=%s", resp.StatusCode, string(body))
	}

	req := <-requests
	if req.Command != "completion" {
		t.Fatalf("bridge command = %q, want completion", req.Command)
	}
	if got := req.Payload["path"]; got != filePath {
		t.Fatalf("bridge path = %#v, want %q", got, filePath)
	}
	if got, ok := req.Payload["version"].(float64); !ok || got != 2 {
		t.Fatalf("bridge version = %#v, want 2", req.Payload["version"])
	}
	if got := req.Payload["content"]; got != "print('draft') // unsaved;\n" {
		t.Fatalf("bridge content = %#v, want unsaved buffer", got)
	}
	if _, ok := req.Payload["position"]; !ok {
		t.Fatalf("bridge payload missing position: %#v", req.Payload)
	}

	resp, body = postBridgeDocumentRequest(t, ts.URL, "/bridge/editor/completion", map[string]any{
		"path":     filePath,
		"version":  1,
		"position": position,
		"workDir":  workDir,
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("stale completion status = %d, want %d; body=%s", resp.StatusCode, http.StatusConflict, string(body))
	}
	var staleErr bridgeErrorDetail
	if err := json.Unmarshal(body, &staleErr); err != nil {
		t.Fatalf("decode stale completion error: %v; body=%s", err, string(body))
	}
	if staleErr.Code != "version_conflict" {
		t.Fatalf("stale completion code = %q, want version_conflict", staleErr.Code)
	}
	select {
	case extra := <-requests:
		t.Fatalf("unexpected extra bridge request after stale version rejection: %#v", extra)
	default:
	}
}

func TestDiagnosticsBridgeResponseWinsWhenDocumentIsOpen(t *testing.T) {
	fs := newMockFS()
	workDir := t.TempDir()
	filePath := filepath.Join(workDir, "main.dart")
	fs.files[filePath] = []byte("print('disk');\n")

	ts, requests := newAPIEditorBridgeServer(t, fs, func(command string, payload map[string]any) any {
		switch command {
		case "diagnostics":
			return map[string]any{
				"path":    payload["path"],
				"version": payload["version"],
				"diagnostics": []any{
					map[string]any{
						"severity": "warning",
						"message":  "bridge diagnostics",
					},
				},
			}
		default:
			return map[string]any{}
		}
	})

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/open", map[string]any{
		"path":    filePath,
		"version": 1,
		"content": "print('draft');\n",
	})
	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/change", map[string]any{
		"path":    filePath,
		"version": 2,
		"changes": []bridgeDocChange{{
			Range: &bridgeDocRange{
				Start: bridgeDocPosition{Line: 0, Character: 14},
				End:   bridgeDocPosition{Line: 0, Character: 14},
			},
			Text: " // unsaved",
		}},
	})

	resp, err := http.Get(ts.URL + "/api/diagnostics?path=" + filePath + "&workDir=" + url.QueryEscape(workDir) + "&format=lsp")
	if err != nil {
		t.Fatal(err)
	}
	body := make([]byte, 0)
	defer resp.Body.Close()
	body, _ = io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("diagnostics status = %d, body=%s", resp.StatusCode, string(body))
	}

	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("decode diagnostics body: %v; body=%s", err, string(body))
	}
	if got := payload["path"]; got != filePath {
		t.Fatalf("diagnostics path = %#v, want %q", got, filePath)
	}
	if got := payload["version"]; got != float64(2) {
		t.Fatalf("diagnostics version = %#v, want 2", got)
	}
	diagnosticsList, ok := payload["diagnostics"].([]any)
	if !ok || len(diagnosticsList) != 1 {
		t.Fatalf("diagnostics = %#v, want 1 entry", payload["diagnostics"])
	}
	first, ok := diagnosticsList[0].(map[string]any)
	if !ok {
		t.Fatalf("diagnostic[0] = %#v, want object", diagnosticsList[0])
	}
	if got := first["message"]; got != "bridge diagnostics" {
		t.Fatalf("diagnostic message = %#v, want bridge diagnostics", got)
	}

	req := <-requests
	if req.Command != "diagnostics" {
		t.Fatalf("bridge command = %q, want diagnostics", req.Command)
	}
	if got := req.Payload["content"]; got != "print('draft') // unsaved;\n" {
		t.Fatalf("bridge diagnostics content = %#v, want unsaved buffer", got)
	}
}
