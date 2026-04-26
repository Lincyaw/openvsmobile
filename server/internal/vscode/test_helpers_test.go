package vscode

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

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
		// IPC channels wait for the initialize frame before allowing calls/listeners.
		initMsg := EncodeProtocolMessage(&ProtocolMessage{
			Type: ProtocolMessageRegular,
			Data: EncodeIPCMessage([]interface{}{int(ResponseTypeInitialize)}, nil),
		})
		if err := conn.WriteMessage(websocket.BinaryMessage, initMsg); err != nil {
			t.Errorf("write initialize payload: %v", err)
			return
		}

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
