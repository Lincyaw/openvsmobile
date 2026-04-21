package vscode

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type editorRequestCapture struct {
	Command string
	Payload map[string]any
}

func newEditorRuntimeServer(t *testing.T, responseFor func(command string, payload map[string]any) any) (*httptest.Server, <-chan editorRequestCapture) {
	t.Helper()

	requests := make(chan editorRequestCapture, 32)
	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade failed: %v", err)
			return
		}
		defer conn.Close()

		auth := mustReadEditorProtocolMessage(t, conn)
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
		mustWriteEditorControlJSON(t, conn, map[string]any{
			"type":       "sign",
			"data":       "challenge",
			"signedData": "challenge",
		})

		connType := mustReadEditorProtocolMessage(t, conn)
		if connType.Type != ProtocolMessageControl {
			t.Errorf("connection type message type = %v, want control", connType.Type)
			return
		}
		var connReq ConnectionTypeRequest
		if err := json.Unmarshal(connType.Data, &connReq); err != nil {
			t.Errorf("unmarshal connection type request: %v", err)
			return
		}
		if connReq.Type != "connectionType" {
			t.Errorf("connection type request type = %q, want connectionType", connReq.Type)
			return
		}
		mustWriteEditorControlJSON(t, conn, map[string]any{"type": "ok"})

		bootstrap := mustReadEditorProtocolMessage(t, conn)
		if bootstrap.Type != ProtocolMessageRegular {
			t.Errorf("bootstrap message type = %v, want regular", bootstrap.Type)
			return
		}
		mustWriteEditorProtocolMessage(t, conn, &ProtocolMessage{
			Type: ProtocolMessageRegular,
			Data: EncodeIPCMessage([]interface{}{int(ResponseTypeInitialize)}, nil),
		})

		for {
			msg, err := readEditorProtocolMessage(conn)
			if err != nil {
				return
			}
			if msg.Type != ProtocolMessageRegular {
				continue
			}
			header, body, err := DecodeIPCMessage(msg.Data)
			if err != nil {
				t.Errorf("decode ipc message: %v", err)
				return
			}
			hdr, ok := header.([]interface{})
			if !ok || len(hdr) < 4 {
				t.Errorf("header = %#v, want request header", header)
				return
			}
			reqType, err := toInt(hdr[0])
			if err != nil {
				t.Errorf("request type: %v", err)
				return
			}
			if RequestType(reqType) != RequestTypePromise {
				t.Errorf("request type = %d, want promise", reqType)
				return
			}
			id, err := toInt(hdr[1])
			if err != nil {
				t.Errorf("request id: %v", err)
				return
			}
			command, _ := hdr[3].(string)
			payload, _ := body.(map[string]any)
			if payload == nil {
				payload = map[string]any{}
			}

			select {
			case requests <- editorRequestCapture{Command: command, Payload: payload}:
			default:
				t.Errorf("request buffer overflow for command %q", command)
				return
			}

			respBody := responseFor(command, payload)
			responseMsg := &ProtocolMessage{
				Type: ProtocolMessageRegular,
				Data: EncodeIPCMessage([]interface{}{int(ResponseTypePromiseSuccess), id}, respBody),
			}
			mustWriteEditorProtocolMessage(t, conn, responseMsg)
		}
	}))

	t.Cleanup(ts.Close)
	return ts, requests
}

func mustReadEditorProtocolMessage(t *testing.T, conn *websocket.Conn) *ProtocolMessage {
	t.Helper()
	msg, err := readEditorProtocolMessage(conn)
	if err != nil {
		t.Fatalf("read protocol message: %v", err)
	}
	return msg
}

func readEditorProtocolMessage(conn *websocket.Conn) (*ProtocolMessage, error) {
	_, raw, err := conn.ReadMessage()
	if err != nil {
		return nil, err
	}
	return DecodeProtocolMessage(bytes.NewReader(raw))
}

func mustWriteEditorControlJSON(t *testing.T, conn *websocket.Conn, payload map[string]any) {
	t.Helper()
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal control payload: %v", err)
	}
	mustWriteEditorProtocolMessage(t, conn, &ProtocolMessage{
		Type: ProtocolMessageControl,
		Data: data,
	})
}

func mustWriteEditorProtocolMessage(t *testing.T, conn *websocket.Conn, msg *ProtocolMessage) {
	t.Helper()
	data := EncodeProtocolMessage(msg)
	if err := conn.WriteMessage(websocket.BinaryMessage, data); err != nil {
		t.Fatalf("write protocol message: %v", err)
	}
}

func connectEditorClient(t *testing.T, serverURL string) *Client {
	t.Helper()

	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	if err := client.Connect(ctx, serverURL, ""); err != nil {
		t.Fatalf("connect editor client: %v", err)
	}
	t.Cleanup(func() {
		_ = client.Close()
	})
	return client
}

func readyEditorManager(t *testing.T, client *Client) *BridgeManager {
	t.Helper()

	metadataPath := filepath.Join(t.TempDir(), "bridge.json")
	manager := NewBridgeManager(BridgeManagerOptions{MetadataPath: metadataPath, Client: client})
	writeBridgeMetadataFile(t, metadataPath, BridgeMetadata{
		Generation:      "gen-editor",
		State:           bridgeStateReady,
		ProtocolVersion: defaultBridgeProtocolVersion,
		BridgeVersion:   "0.3.0",
		Capabilities: map[string]interface{}{
			"diagnostics":     map[string]interface{}{"enabled": true},
			"completion":      map[string]interface{}{"enabled": true},
			"hover":           map[string]interface{}{"enabled": true},
			"definition":      map[string]interface{}{"enabled": true},
			"references":      map[string]interface{}{"enabled": true},
			"signatureHelp":   map[string]interface{}{"enabled": true},
			"formatting":      map[string]interface{}{"enabled": true},
			"codeActions":     map[string]interface{}{"enabled": true},
			"rename":          map[string]interface{}{"enabled": true},
			"documentSymbols": map[string]interface{}{"enabled": true},
		},
	})
	manager.poll()
	t.Cleanup(manager.Close)
	return manager
}

func expectRequestPayload(t *testing.T, got editorRequestCapture, wantCommand string, mustHave, mustNotHave []string) {
	t.Helper()

	if got.Command != wantCommand {
		t.Fatalf("command = %q, want %q", got.Command, wantCommand)
	}
	for _, key := range mustHave {
		if _, ok := got.Payload[key]; !ok {
			t.Fatalf("payload missing %q: %#v", key, got.Payload)
		}
	}
	for _, key := range mustNotHave {
		if _, ok := got.Payload[key]; ok {
			t.Fatalf("payload unexpectedly included %q: %#v", key, got.Payload)
		}
	}
}

func TestEditorServiceSendsVersionedUnsavedBufferAndRequiredContext(t *testing.T) {
	ts, requests := newEditorRuntimeServer(t, func(command string, payload map[string]any) any {
		switch command {
		case "completion":
			return map[string]any{"isIncomplete": false, "items": []any{}}
		case "hover":
			return map[string]any{"contents": "hover"}
		case "definition", "references", "formatting", "codeActions", "documentSymbols":
			return []any{}
		case "signatureHelp":
			return map[string]any{}
		case "rename":
			return map[string]any{"changes": map[string]any{}}
		default:
			return map[string]any{}
		}
	})
	client := connectEditorClient(t, ts.URL)
	manager := readyEditorManager(t, client)
	store := newStubDocumentStore()
	store.files["/workspace/main.dart"] = []byte("print('disk');\n")
	docs := NewDocumentSyncService(store)
	editor := NewEditorService(client, manager, docs)

	initial := "print('draft');\n"
	if _, err := docs.OpenDocument("/workspace/main.dart", 1, &initial); err != nil {
		t.Fatalf("open document: %v", err)
	}
	if _, err := docs.ApplyDocumentChanges("/workspace/main.dart", 2, []DocumentChange{{
		Range: &DocumentRange{
			Start: DocumentPosition{Line: 0, Character: 14},
			End:   DocumentPosition{Line: 0, Character: 14},
		},
		Text: " // unsaved",
	}}); err != nil {
		t.Fatalf("apply document changes: %v", err)
	}

	unsaved := "print('draft') // unsaved;\n"
	position := DocumentPosition{Line: 0, Character: 7}
	rangeEdit := DocumentRange{
		Start: DocumentPosition{Line: 0, Character: 7},
		End:   DocumentPosition{Line: 0, Character: 13},
	}

	cases := []struct {
		name        string
		call        func(EditorRequest) (any, error)
		req         EditorRequest
		wantCommand  string
		mustHave    []string
		mustNotHave []string
	}{
		{
			name: "completion",
			call: func(req EditorRequest) (any, error) { return editor.Completion(req) },
			req:  EditorRequest{Path: "/workspace/main.dart", Version: 2, Position: &position},
			wantCommand: "completion",
			mustHave:    []string{"path", "version", "content", "position"},
			mustNotHave: []string{"range", "newName"},
		},
		{
			name: "hover",
			call: func(req EditorRequest) (any, error) { return editor.Hover(req) },
			req:  EditorRequest{Path: "/workspace/main.dart", Version: 2, Position: &position},
			wantCommand: "hover",
			mustHave:    []string{"path", "version", "content", "position"},
			mustNotHave: []string{"range", "newName"},
		},
		{
			name: "definition",
			call: func(req EditorRequest) (any, error) { return editor.Definition(req) },
			req:  EditorRequest{Path: "/workspace/main.dart", Version: 2, Position: &position},
			wantCommand: "definition",
			mustHave:    []string{"path", "version", "content", "position"},
			mustNotHave: []string{"range", "newName"},
		},
		{
			name: "references",
			call: func(req EditorRequest) (any, error) { return editor.References(req) },
			req:  EditorRequest{Path: "/workspace/main.dart", Version: 2, Position: &position},
			wantCommand: "references",
			mustHave:    []string{"path", "version", "content", "position"},
			mustNotHave: []string{"range", "newName"},
		},
		{
			name: "signatureHelp",
			call: func(req EditorRequest) (any, error) { return editor.SignatureHelp(req) },
			req:  EditorRequest{Path: "/workspace/main.dart", Version: 2, Position: &position},
			wantCommand: "signatureHelp",
			mustHave:    []string{"path", "version", "content", "position"},
			mustNotHave: []string{"range", "newName"},
		},
		{
			name: "codeActions",
			call: func(req EditorRequest) (any, error) { return editor.CodeActions(req) },
			req:  EditorRequest{Path: "/workspace/main.dart", Version: 2, Range: &rangeEdit},
			wantCommand: "codeActions",
			mustHave:    []string{"path", "version", "content", "range"},
			mustNotHave: []string{"position", "newName"},
		},
		{
			name: "rename",
			call: func(req EditorRequest) (any, error) { return editor.Rename(req) },
			req:  EditorRequest{Path: "/workspace/main.dart", Version: 2, Position: &position, NewName: "renamedValue"},
			wantCommand: "rename",
			mustHave:    []string{"path", "version", "content", "position", "newName"},
			mustNotHave: []string{"range"},
		},
		{
			name: "formatting",
			call: func(req EditorRequest) (any, error) { return editor.Formatting(req) },
			req:  EditorRequest{Path: "/workspace/main.dart", Version: 2},
			wantCommand: "formatting",
			mustHave:    []string{"path", "version", "content"},
			mustNotHave: []string{"position", "range", "newName"},
		},
		{
			name: "documentSymbols",
			call: func(req EditorRequest) (any, error) { return editor.DocumentSymbols(req) },
			req:  EditorRequest{Path: "/workspace/main.dart", Version: 2},
			wantCommand: "documentSymbols",
			mustHave:    []string{"path", "version", "content"},
			mustNotHave: []string{"position", "range", "newName"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := tc.call(tc.req)
			if err != nil {
				t.Fatalf("%s failed: %v", tc.name, err)
			}

			req := <-requests
			expectRequestPayload(t, req, tc.wantCommand, tc.mustHave, tc.mustNotHave)
			if got := req.Payload["content"]; got != unsaved {
				t.Fatalf("payload content = %#v, want %q", got, unsaved)
			}
			if tc.wantCommand == "rename" {
				if got := req.Payload["newName"]; got != "renamedValue" {
					t.Fatalf("rename newName = %#v, want %q", got, "renamedValue")
				}
			}
		})
	}
}

func TestEditorServiceRejectsStaleVersionBeforeCallingBridge(t *testing.T) {
	ts, requests := newEditorRuntimeServer(t, func(command string, payload map[string]any) any {
		return map[string]any{"items": []any{}}
	})
	client := connectEditorClient(t, ts.URL)
	manager := readyEditorManager(t, client)
	store := newStubDocumentStore()
	store.files["/workspace/stale.dart"] = []byte("base\n")
	docs := NewDocumentSyncService(store)
	editor := NewEditorService(client, manager, docs)

	initial := "draft\n"
	if _, err := docs.OpenDocument("/workspace/stale.dart", 1, &initial); err != nil {
		t.Fatalf("open document: %v", err)
	}
	if _, err := docs.ApplyDocumentChanges("/workspace/stale.dart", 2, []DocumentChange{{
		Text: "changed\n",
	}}); err != nil {
		t.Fatalf("apply document changes: %v", err)
	}

	_, err := editor.Completion(EditorRequest{
		Path:     "/workspace/stale.dart",
		Version:  1,
		Position: &DocumentPosition{Line: 0, Character: 0},
	})
	if err == nil {
		t.Fatal("expected stale version error")
	}
	bridgeErr, ok := err.(*BridgeError)
	if !ok || bridgeErr.Code != "version_conflict" {
		t.Fatalf("error = %#v, want version_conflict", err)
	}
	select {
	case req := <-requests:
		t.Fatalf("unexpected bridge request after stale version rejection: %#v", req)
	default:
	}
}
