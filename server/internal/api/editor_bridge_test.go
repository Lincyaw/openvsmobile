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

func newAPIEditorRuntimeServer(t *testing.T, fs *mockFS, responseFor func(command string, payload map[string]any, docs *vscode.DocumentSyncService) any) (*httptest.Server, <-chan apiEditorRequestCapture) {
	t.Helper()

	requests := make(chan apiEditorRequestCapture, 32)
	runtimeDocuments := vscode.NewDocumentSyncService(fs)
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
			channelName, _ := hdr[2].(string)
			command, _ := hdr[3].(string)
			payload, _ := body.(map[string]any)
			if payload == nil {
				payload = map[string]any{}
			}

			if channelName == "openvsmobile/documents" {
				respBody := handleAPIRuntimeDocumentCommand(t, runtimeDocuments, command, payload)
				mustWriteAPIEditorProtocolMessage(t, conn, &vscode.ProtocolMessage{
					Type: vscode.ProtocolMessageRegular,
					Data: vscode.EncodeIPCMessage([]interface{}{int(vscode.ResponseTypePromiseSuccess), id}, respBody),
				})
				continue
			}

			select {
			case requests <- apiEditorRequestCapture{Command: command, Payload: payload}:
			default:
				t.Errorf("request buffer overflow for command %q", command)
				return
			}

			respBody := responseFor(command, payload, runtimeDocuments)
			mustWriteAPIEditorProtocolMessage(t, conn, &vscode.ProtocolMessage{
				Type: vscode.ProtocolMessageRegular,
				Data: vscode.EncodeIPCMessage([]interface{}{int(vscode.ResponseTypePromiseSuccess), id}, respBody),
			})
		}
	}))

	t.Cleanup(ts.Close)
	return ts, requests
}

func handleAPIRuntimeDocumentCommand(t *testing.T, docs *vscode.DocumentSyncService, command string, payload map[string]any) any {
	t.Helper()

	snapshotResponse := func(snapshot vscode.DocumentSnapshot, err error) any {
		if err != nil {
			return apiRuntimeDocumentErrorEnvelope(err)
		}
		return map[string]any{
			"ok":       true,
			"snapshot": snapshot,
		}
	}

	switch command {
	case "open":
		var req struct {
			Path    string  `json:"path"`
			Version int     `json:"version"`
			Content *string `json:"content,omitempty"`
		}
		if err := decodePayloadInto(payload, &req); err != nil {
			t.Fatalf("decode runtime open payload: %v", err)
		}
		return snapshotResponse(docs.OpenDocument(req.Path, req.Version, req.Content))
	case "change":
		var req struct {
			Path    string                  `json:"path"`
			Version int                     `json:"version"`
			Changes []vscode.DocumentChange `json:"changes"`
		}
		if err := decodePayloadInto(payload, &req); err != nil {
			t.Fatalf("decode runtime change payload: %v", err)
		}
		return snapshotResponse(docs.ApplyDocumentChanges(req.Path, req.Version, req.Changes))
	case "save":
		path, _ := payload["path"].(string)
		return snapshotResponse(docs.SaveDocument(path))
	case "snapshot":
		path, _ := payload["path"].(string)
		return snapshotResponse(docs.DocumentBuffer(path))
	case "close":
		path, _ := payload["path"].(string)
		if err := docs.CloseDocument(path); err != nil {
			return apiRuntimeDocumentErrorEnvelope(err)
		}
		return map[string]any{
			"ok":     true,
			"path":   path,
			"closed": true,
		}
	default:
		t.Fatalf("unexpected runtime document command %q", command)
		return nil
	}
}

func apiRuntimeDocumentErrorEnvelope(err error) any {
	bridgeErr, ok := err.(*vscode.BridgeError)
	if !ok {
		return map[string]any{
			"ok": false,
			"error": map[string]any{
				"code":    "document_sync_failed",
				"message": err.Error(),
			},
		}
	}
	return map[string]any{
		"ok": false,
		"error": map[string]any{
			"code":    bridgeErr.Code,
			"message": bridgeErr.Message,
		},
	}
}

func decodePayloadInto(raw map[string]any, dest any) error {
	data, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, dest)
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

func newAPIEditorBridgeServer(t *testing.T, fs *mockFS, responseFor func(command string, payload map[string]any, docs *vscode.DocumentSyncService) any) (*httptest.Server, <-chan apiEditorRequestCapture) {
	t.Helper()

	runtimeTS, requests := newAPIEditorRuntimeServer(t, fs, responseFor)
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
			"documents":       map[string]any{"enabled": true},
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

	documents := vscode.NewRuntimeDocumentSyncService(client, manager, fs)
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

func TestBridgeDocumentLifecycle_RuntimeBackedSavePersistsLatestAcceptedBuffer(t *testing.T) {
	fs := newMockFS()
	workDir := t.TempDir()
	filePath := filepath.Join(workDir, "runtime.txt")
	fs.files[filePath] = []byte("disk copy\n")

	ts, _ := newAPIEditorBridgeServer(t, fs, func(command string, payload map[string]any, docs *vscode.DocumentSyncService) any {
		return map[string]any{"items": []any{}}
	})

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/open", map[string]any{
		"path":    filePath,
		"version": 1,
		"content": "draft\n",
	})
	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/change", map[string]any{
		"path":    filePath,
		"version": 2,
		"changes": []bridgeDocChange{{
			Range: &bridgeDocRange{
				Start: bridgeDocPosition{Line: 0, Character: 5},
				End:   bridgeDocPosition{Line: 0, Character: 5},
			},
			Text: " updated",
		}},
	})

	if got := string(fs.files[filePath]); got != "disk copy\n" {
		t.Fatalf("disk content before runtime save = %q, want unchanged", got)
	}

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/save", map[string]any{
		"path": filePath,
	})
	if got := string(fs.files[filePath]); got != "draft updated\n" {
		t.Fatalf("saved runtime content = %q, want %q", got, "draft updated\n")
	}

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/close", map[string]any{
		"path": filePath,
	})
	requireBridgeDocumentError(t, ts.URL, "/bridge/doc/save", map[string]any{
		"path": filePath,
	}, "document_not_open", http.StatusNotFound)
}

func TestBridgeEditorCompletionUsesRuntimeDocumentStateAndVersionedContext(t *testing.T) {
	fs := newMockFS()
	workDir := t.TempDir()
	filePath := filepath.Join(workDir, "main.dart")
	fs.files[filePath] = []byte("print('disk');\n")

	ts, requests := newAPIEditorBridgeServer(t, fs, func(command string, payload map[string]any, docs *vscode.DocumentSyncService) any {
		if command != "completion" {
			return map[string]any{"items": []any{}}
		}
		snapshot, err := docs.DocumentBuffer(payload["path"].(string))
		if err != nil {
			t.Fatalf("runtime completion snapshot: %v", err)
		}
		return map[string]any{
			"isIncomplete": false,
			"items": []any{
				map[string]any{
					"label":  snapshot.Content,
					"detail": "2",
				},
			},
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
	var completionPayload map[string]any
	if err := json.Unmarshal(body, &completionPayload); err != nil {
		t.Fatalf("decode completion body: %v; body=%s", err, string(body))
	}
	items, ok := completionPayload["items"].([]any)
	if !ok || len(items) != 1 {
		t.Fatalf("completion items = %#v, want 1 item", completionPayload["items"])
	}
	item, ok := items[0].(map[string]any)
	if !ok {
		t.Fatalf("completion item = %#v, want object", items[0])
	}
	if got := item["label"]; got != "print('draft') // unsaved;\n" {
		t.Fatalf("completion label = %#v, want runtime unsaved buffer", got)
	}
	if got := item["detail"]; got != "2" {
		t.Fatalf("completion detail = %#v, want runtime version 2", got)
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
	if _, ok := req.Payload["content"]; ok {
		t.Fatalf("bridge payload unexpectedly included content: %#v", req.Payload)
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

	ts, requests := newAPIEditorBridgeServer(t, fs, func(command string, payload map[string]any, docs *vscode.DocumentSyncService) any {
		switch command {
		case "diagnostics":
			snapshot, err := docs.DocumentBuffer(payload["path"].(string))
			if err != nil {
				t.Fatalf("runtime diagnostics snapshot: %v", err)
			}
			return map[string]any{
				"path":    snapshot.Path,
				"version": snapshot.Version,
				"diagnostics": []any{
					map[string]any{
						"severity": "warning",
						"message":  snapshot.Content,
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
	if got := first["message"]; got != "print('draft') // unsaved;\n" {
		t.Fatalf("diagnostic message = %#v, want runtime unsaved buffer", got)
	}

	req := <-requests
	if req.Command != "diagnostics" {
		t.Fatalf("bridge command = %q, want diagnostics", req.Command)
	}
	if _, ok := req.Payload["content"]; ok {
		t.Fatalf("bridge diagnostics payload unexpectedly included content: %#v", req.Payload)
	}
}

func TestBridgeEditorRuntimeEndpointsReturnStructuredResultsFromRuntimeModel(t *testing.T) {
	fs := newMockFS()
	workDir := t.TempDir()
	filePath := filepath.Join(workDir, "main.dart")
	otherPath := filepath.Join(workDir, "other.dart")
	fs.files[filePath] = []byte("print('disk');\n")
	fs.files[otherPath] = []byte("secondary\n")

	ts, requests := newAPIEditorBridgeServer(t, fs, func(command string, payload map[string]any, docs *vscode.DocumentSyncService) any {
		snapshot, err := docs.DocumentBuffer(payload["path"].(string))
		if err != nil {
			t.Fatalf("runtime snapshot for %s: %v", command, err)
		}

		rangeJSON := func(startLine, startChar, endLine, endChar int) map[string]any {
			return map[string]any{
				"start": map[string]any{"line": startLine, "character": startChar},
				"end":   map[string]any{"line": endLine, "character": endChar},
			}
		}

		switch command {
		case "hover":
			return map[string]any{
				"contents": []any{
					map[string]any{"kind": "markdown", "value": snapshot.Content},
				},
				"range": rangeJSON(0, 0, 0, 5),
			}
		case "definition":
			return []any{
				map[string]any{
					"uri":   "file://" + filePath,
					"path":  filePath,
					"range": rangeJSON(0, 0, 0, 5),
				},
			}
		case "references":
			return []any{
				map[string]any{
					"uri":   "file://" + filePath,
					"path":  filePath,
					"range": rangeJSON(0, 0, 0, 5),
				},
				map[string]any{
					"uri":   "file://" + otherPath,
					"path":  otherPath,
					"range": rangeJSON(0, 0, 0, 4),
				},
			}
		case "signatureHelp":
			return map[string]any{
				"signatures": []any{
					map[string]any{"label": "sig(" + snapshot.Content + ")"},
				},
				"activeSignature": 0,
				"activeParameter": 0,
			}
		case "documentSymbols":
			return []any{
				map[string]any{
					"name":           "main",
					"kind":           12,
					"range":          rangeJSON(0, 0, 0, 5),
					"selectionRange": rangeJSON(0, 0, 0, 5),
				},
			}
		case "formatting":
			return []any{
				map[string]any{
					"range":   rangeJSON(0, 0, 0, 0),
					"newText": "// formatted\n" + snapshot.Content,
				},
			}
		case "codeActions":
			return []any{
				map[string]any{
					"title": "Apply fix",
					"kind":  "quickfix",
					"edit": map[string]any{
						"changes": map[string]any{
							filePath: []any{
								map[string]any{
									"range":   rangeJSON(0, 0, 0, 5),
									"newText": "fixed",
								},
							},
						},
					},
				},
			}
		case "rename":
			return map[string]any{
				"changes": map[string]any{
					filePath: []any{
						map[string]any{
							"range":   rangeJSON(0, 0, 0, 5),
							"newText": "renamed",
						},
					},
					otherPath: []any{
						map[string]any{
							"range":   rangeJSON(0, 0, 0, 4),
							"newText": "renamed",
						},
					},
				},
			}
		default:
			t.Fatalf("unexpected command %q", command)
			return nil
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

	position := map[string]any{"line": 0, "character": 7}
	selectedRange := map[string]any{
		"start": map[string]any{"line": 0, "character": 0},
		"end":   map[string]any{"line": 0, "character": 5},
	}

	testCases := []struct {
		name         string
		endpoint     string
		body         map[string]any
		wantCommand  string
		wantKeys     []string
		absentKeys   []string
		assertResult func(*testing.T, []byte)
	}{
		{
			name:        "hover",
			endpoint:    "/bridge/editor/hover",
			body:        map[string]any{"path": filePath, "version": 2, "position": position, "workDir": workDir},
			wantCommand: "hover",
			wantKeys:    []string{"path", "version", "position"},
			absentKeys:  []string{"range", "newName", "content"},
			assertResult: func(t *testing.T, body []byte) {
				t.Helper()
				var payload map[string]any
				if err := json.Unmarshal(body, &payload); err != nil {
					t.Fatalf("decode hover body: %v; body=%s", err, string(body))
				}
				contents, ok := payload["contents"].([]any)
				if !ok || len(contents) != 1 {
					t.Fatalf("hover contents = %#v, want 1 entry", payload["contents"])
				}
			},
		},
		{
			name:        "definition",
			endpoint:    "/bridge/editor/definition",
			body:        map[string]any{"path": filePath, "version": 2, "position": position, "workDir": workDir},
			wantCommand: "definition",
			wantKeys:    []string{"path", "version", "position"},
			absentKeys:  []string{"range", "newName", "content"},
			assertResult: func(t *testing.T, body []byte) {
				t.Helper()
				var payload []map[string]any
				if err := json.Unmarshal(body, &payload); err != nil {
					t.Fatalf("decode definition body: %v; body=%s", err, string(body))
				}
				if len(payload) != 1 {
					t.Fatalf("definition payload = %#v, want 1 entry", payload)
				}
				if got, ok := payload[0]["uri"].(string); !ok || got == "" {
					t.Fatalf("definition payload = %#v, want uri", payload)
				}
			},
		},
		{
			name:        "references",
			endpoint:    "/bridge/editor/references",
			body:        map[string]any{"path": filePath, "version": 2, "position": position, "workDir": workDir},
			wantCommand: "references",
			wantKeys:    []string{"path", "version", "position"},
			absentKeys:  []string{"range", "newName", "content"},
			assertResult: func(t *testing.T, body []byte) {
				t.Helper()
				var payload []map[string]any
				if err := json.Unmarshal(body, &payload); err != nil {
					t.Fatalf("decode references body: %v; body=%s", err, string(body))
				}
				if len(payload) != 2 {
					t.Fatalf("references payload = %#v, want 2 entries", payload)
				}
			},
		},
		{
			name:        "signatureHelp",
			endpoint:    "/bridge/editor/signature-help",
			body:        map[string]any{"path": filePath, "version": 2, "position": position, "workDir": workDir},
			wantCommand: "signatureHelp",
			wantKeys:    []string{"path", "version", "position"},
			absentKeys:  []string{"range", "newName", "content"},
			assertResult: func(t *testing.T, body []byte) {
				t.Helper()
				var payload map[string]any
				if err := json.Unmarshal(body, &payload); err != nil {
					t.Fatalf("decode signature help body: %v; body=%s", err, string(body))
				}
				signatures, ok := payload["signatures"].([]any)
				if !ok || len(signatures) != 1 {
					t.Fatalf("signature help = %#v, want 1 signature", payload)
				}
			},
		},
		{
			name:        "documentSymbols",
			endpoint:    "/bridge/editor/document-symbols",
			body:        map[string]any{"path": filePath, "version": 2, "workDir": workDir},
			wantCommand: "documentSymbols",
			wantKeys:    []string{"path", "version"},
			absentKeys:  []string{"position", "range", "newName", "content"},
			assertResult: func(t *testing.T, body []byte) {
				t.Helper()
				var payload []map[string]any
				if err := json.Unmarshal(body, &payload); err != nil {
					t.Fatalf("decode document symbols body: %v; body=%s", err, string(body))
				}
				if len(payload) != 1 || payload[0]["name"] != "main" {
					t.Fatalf("document symbols payload = %#v, want main symbol", payload)
				}
			},
		},
		{
			name:        "formatting",
			endpoint:    "/bridge/editor/formatting",
			body:        map[string]any{"path": filePath, "version": 2, "workDir": workDir},
			wantCommand: "formatting",
			wantKeys:    []string{"path", "version"},
			absentKeys:  []string{"position", "range", "newName", "content"},
			assertResult: func(t *testing.T, body []byte) {
				t.Helper()
				var payload []map[string]any
				if err := json.Unmarshal(body, &payload); err != nil {
					t.Fatalf("decode formatting body: %v; body=%s", err, string(body))
				}
				if len(payload) != 1 || payload[0]["newText"] == nil {
					t.Fatalf("formatting payload = %#v, want one text edit", payload)
				}
			},
		},
		{
			name:        "codeActions",
			endpoint:    "/bridge/editor/code-actions",
			body:        map[string]any{"path": filePath, "version": 2, "range": selectedRange, "workDir": workDir},
			wantCommand: "codeActions",
			wantKeys:    []string{"path", "version", "range"},
			absentKeys:  []string{"position", "newName", "content"},
			assertResult: func(t *testing.T, body []byte) {
				t.Helper()
				var payload []map[string]any
				if err := json.Unmarshal(body, &payload); err != nil {
					t.Fatalf("decode code actions body: %v; body=%s", err, string(body))
				}
				if len(payload) != 1 || payload[0]["title"] != "Apply fix" {
					t.Fatalf("code actions payload = %#v, want quick fix", payload)
				}
			},
		},
		{
			name:        "rename",
			endpoint:    "/bridge/editor/rename",
			body:        map[string]any{"path": filePath, "version": 2, "position": position, "newName": "renamed", "workDir": workDir},
			wantCommand: "rename",
			wantKeys:    []string{"path", "version", "position", "newName"},
			absentKeys:  []string{"range", "content"},
			assertResult: func(t *testing.T, body []byte) {
				t.Helper()
				var payload map[string]any
				if err := json.Unmarshal(body, &payload); err != nil {
					t.Fatalf("decode rename body: %v; body=%s", err, string(body))
				}
				changes, ok := payload["changes"].(map[string]any)
				if !ok || len(changes) != 2 {
					t.Fatalf("rename payload = %#v, want 2 changed files", payload)
				}
			},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			resp, body := postBridgeDocumentRequest(t, ts.URL, tc.endpoint, tc.body)
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				t.Fatalf("%s status = %d, body=%s", tc.name, resp.StatusCode, string(body))
			}
			tc.assertResult(t, body)

			req := <-requests
			if req.Command != tc.wantCommand {
				t.Fatalf("%s command = %q, want %q", tc.name, req.Command, tc.wantCommand)
			}
			for _, key := range tc.wantKeys {
				if _, ok := req.Payload[key]; !ok {
					t.Fatalf("%s payload missing %q: %#v", tc.name, key, req.Payload)
				}
			}
			for _, key := range tc.absentKeys {
				if _, ok := req.Payload[key]; ok {
					t.Fatalf("%s payload unexpectedly included %q: %#v", tc.name, key, req.Payload)
				}
			}
		})
	}
}
