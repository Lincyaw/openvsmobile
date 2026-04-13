package vscode

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestEncodeDecodeProtocolMessage(t *testing.T) {
	tests := []struct {
		name string
		msg  ProtocolMessage
	}{
		{
			name: "empty regular message",
			msg:  ProtocolMessage{Type: ProtocolMessageRegular, ID: 0, Ack: 0, Data: []byte{}},
		},
		{
			name: "control message with data",
			msg:  ProtocolMessage{Type: ProtocolMessageControl, ID: 1, Ack: 2, Data: []byte(`{"type":"auth","auth":"token"}`)},
		},
		{
			name: "ack message",
			msg:  ProtocolMessage{Type: ProtocolMessageAck, ID: 0, Ack: 42, Data: []byte{}},
		},
		{
			name: "keepalive",
			msg:  ProtocolMessage{Type: ProtocolMessageKeepAlive, ID: 0, Ack: 0, Data: []byte{}},
		},
		{
			name: "large data",
			msg:  ProtocolMessage{Type: ProtocolMessageRegular, ID: 100, Ack: 99, Data: bytes.Repeat([]byte("x"), 1024)},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			encoded := EncodeProtocolMessage(&tc.msg)

			if len(encoded) != ProtocolHeaderLength+len(tc.msg.Data) {
				t.Fatalf("encoded length %d, want %d", len(encoded), ProtocolHeaderLength+len(tc.msg.Data))
			}

			decoded, err := DecodeProtocolMessage(bytes.NewReader(encoded))
			if err != nil {
				t.Fatalf("decode error: %v", err)
			}

			if decoded.Type != tc.msg.Type {
				t.Errorf("type = %d, want %d", decoded.Type, tc.msg.Type)
			}
			if decoded.ID != tc.msg.ID {
				t.Errorf("id = %d, want %d", decoded.ID, tc.msg.ID)
			}
			if decoded.Ack != tc.msg.Ack {
				t.Errorf("ack = %d, want %d", decoded.Ack, tc.msg.Ack)
			}
			if !bytes.Equal(decoded.Data, tc.msg.Data) {
				t.Errorf("data mismatch")
			}
		})
	}
}

func TestSerializeDeserializeRoundTrip(t *testing.T) {
	tests := []struct {
		name  string
		input interface{}
		check func(t *testing.T, got interface{})
	}{
		{
			name:  "nil / undefined",
			input: nil,
			check: func(t *testing.T, got interface{}) {
				if got != nil {
					t.Errorf("got %v, want nil", got)
				}
			},
		},
		{
			name:  "string",
			input: "hello world",
			check: func(t *testing.T, got interface{}) {
				s, ok := got.(string)
				if !ok || s != "hello world" {
					t.Errorf("got %v, want 'hello world'", got)
				}
			},
		},
		{
			name:  "int zero",
			input: 0,
			check: func(t *testing.T, got interface{}) {
				v, ok := got.(int)
				if !ok || v != 0 {
					t.Errorf("got %v, want 0", got)
				}
			},
		},
		{
			name:  "int positive",
			input: 12345,
			check: func(t *testing.T, got interface{}) {
				v, ok := got.(int)
				if !ok || v != 12345 {
					t.Errorf("got %v, want 12345", got)
				}
			},
		},
		{
			name:  "byte slice (VSBuffer)",
			input: []byte{0x01, 0x02, 0x03},
			check: func(t *testing.T, got interface{}) {
				b, ok := got.([]byte)
				if !ok || !bytes.Equal(b, []byte{0x01, 0x02, 0x03}) {
					t.Errorf("got %v, want [1 2 3]", got)
				}
			},
		},
		{
			name:  "array",
			input: []interface{}{"a", 1, nil},
			check: func(t *testing.T, got interface{}) {
				arr, ok := got.([]interface{})
				if !ok || len(arr) != 3 {
					t.Fatalf("expected 3-element array, got %v", got)
				}
				if arr[0] != "a" {
					t.Errorf("arr[0] = %v, want 'a'", arr[0])
				}
				if arr[1] != 1 {
					t.Errorf("arr[1] = %v, want 1", arr[1])
				}
				if arr[2] != nil {
					t.Errorf("arr[2] = %v, want nil", arr[2])
				}
			},
		},
		{
			name:  "object (map)",
			input: map[string]interface{}{"key": "value", "num": float64(42)},
			check: func(t *testing.T, got interface{}) {
				m, ok := got.(map[string]interface{})
				if !ok {
					t.Fatalf("expected map, got %T", got)
				}
				if m["key"] != "value" {
					t.Errorf("key = %v, want 'value'", m["key"])
				}
				if m["num"] != float64(42) {
					t.Errorf("num = %v, want 42", m["num"])
				}
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			w := &bufWriter{}
			Serialize(w, tc.input)

			r := newBufReader(w.Bytes())
			got, err := Deserialize(r)
			if err != nil {
				t.Fatalf("deserialize error: %v", err)
			}
			tc.check(t, got)
		})
	}
}

func TestEncodeDecodeIPCMessage(t *testing.T) {
	header := []interface{}{100, 1, "remoteFilesystem", "stat"}
	body := map[string]interface{}{
		"scheme":    "vscode-remote",
		"authority": "test",
		"path":      "/home/user/file.txt",
	}

	encoded := EncodeIPCMessage(header, body)

	gotHeader, gotBody, err := DecodeIPCMessage(encoded)
	if err != nil {
		t.Fatalf("decode error: %v", err)
	}

	hdr, ok := gotHeader.([]interface{})
	if !ok {
		t.Fatalf("expected header array, got %T", gotHeader)
	}
	if len(hdr) != 4 {
		t.Fatalf("header length = %d, want 4", len(hdr))
	}
	if hdr[2] != "remoteFilesystem" {
		t.Errorf("channel = %v, want 'remoteFilesystem'", hdr[2])
	}
	if hdr[3] != "stat" {
		t.Errorf("command = %v, want 'stat'", hdr[3])
	}

	bodyMap, ok := gotBody.(map[string]interface{})
	if !ok {
		t.Fatalf("expected body map, got %T", gotBody)
	}
	if bodyMap["path"] != "/home/user/file.txt" {
		t.Errorf("path = %v", bodyMap["path"])
	}
}

func TestVQLEncoding(t *testing.T) {
	values := []int{0, 1, 127, 128, 255, 256, 16383, 16384, 1000000}
	for _, v := range values {
		w := &bufWriter{}
		writeVQL(w, v)
		r := newBufReader(w.Bytes())
		got, err := readVQL(r)
		if err != nil {
			t.Fatalf("readVQL(%d): %v", v, err)
		}
		if got != v {
			t.Errorf("VQL roundtrip: got %d, want %d", got, v)
		}
	}
}

func TestHandshakeMessageSerialization(t *testing.T) {
	authReq := map[string]interface{}{
		"type": "auth",
		"auth": "test-token",
		"data": "test-data",
	}
	data, err := json.Marshal(authReq)
	if err != nil {
		t.Fatal(err)
	}

	msg := &ProtocolMessage{
		Type: ProtocolMessageControl,
		ID:   0,
		Ack:  0,
		Data: data,
	}

	encoded := EncodeProtocolMessage(msg)
	decoded, err := DecodeProtocolMessage(bytes.NewReader(encoded))
	if err != nil {
		t.Fatal(err)
	}

	var got map[string]interface{}
	if err := json.Unmarshal(decoded.Data, &got); err != nil {
		t.Fatal(err)
	}

	if got["type"] != "auth" {
		t.Errorf("type = %v, want 'auth'", got["type"])
	}
	if got["auth"] != "test-token" {
		t.Errorf("auth = %v, want 'test-token'", got["auth"])
	}
}
