package vscode

import (
	"context"
	"testing"
	"time"
)

func waitForIPCRequest(t *testing.T, messages <-chan *ProtocolMessage, wantType RequestType) ([]interface{}, interface{}) {
	t.Helper()

	deadline := time.After(2 * time.Second)
	for {
		select {
		case msg := <-messages:
			if msg == nil {
				continue
			}
			header, body, err := DecodeIPCMessage(msg.Data)
			if err != nil {
				continue
			}
			hdr, ok := header.([]interface{})
			if !ok || len(hdr) == 0 {
				continue
			}
			reqType, err := toInt(hdr[0])
			if err != nil {
				continue
			}
			if RequestType(reqType) == wantType {
				return hdr, body
			}
		case <-deadline:
			t.Fatalf("timed out waiting for IPC request type %d", wantType)
		}
	}
}

func TestIPCChannelListen_GitRepositoryStateRoundTripAndDispose(t *testing.T) {
	ts, fake := newFakeVSCodeServer(t, 0)

	client := NewClient()
	if err := client.Connect(context.Background(), ts.URL, ""); err != nil {
		t.Fatalf("connect client: %v", err)
	}
	defer client.Close()

	channel := client.IPC().GetChannel("git")

	events, dispose, err := channel.Listen("repositoryState", map[string]interface{}{
		"path": "/workspace/repo",
	})
	if err != nil {
		t.Fatalf("listen repositoryState: %v", err)
	}

	header, body := waitForIPCRequest(t, fake.messages, RequestTypeEventListen)
	if got := header[2]; got != "git" {
		t.Fatalf("channel = %#v, want %q", got, "git")
	}
	if got := header[3]; got != "repositoryState" {
		t.Fatalf("event = %#v, want %q", got, "repositoryState")
	}
	listenID, err := toInt(header[1])
	if err != nil {
		t.Fatalf("decode listen id: %v", err)
	}

	bodyMap, ok := body.(map[string]interface{})
	if !ok {
		t.Fatalf("listen body = %#v, want map[string]interface{}", body)
	}
	if got := bodyMap["path"]; got != "/workspace/repo" {
		t.Fatalf("listen path = %#v, want %q", got, "/workspace/repo")
	}

	client.onMessage(EncodeIPCMessage(
		[]interface{}{int(ResponseTypeEventFire), listenID},
		map[string]interface{}{
			"path":     "/workspace/repo",
			"branch":   "main",
			"upstream": "origin/main",
			"ahead":    2,
			"behind":   1,
			"remotes": []interface{}{
				map[string]interface{}{
					"name":     "origin",
					"fetchUrl": "git@github.com:Lincyaw/openvsmobile.git",
					"pushUrl":  "git@github.com:Lincyaw/openvsmobile.git",
				},
			},
			"conflicts": []interface{}{
				map[string]interface{}{
					"path":   "lib/conflicted.dart",
					"status": "both_modified",
				},
			},
			"mergeChanges": []interface{}{
				map[string]interface{}{
					"path":   "lib/merge_only.dart",
					"status": "added_by_them",
				},
			},
		},
	))

	select {
	case raw := <-events:
		payload, ok := raw.(map[string]interface{})
		if !ok {
			t.Fatalf("event payload = %#v, want map[string]interface{}", raw)
		}
		if got := payload["upstream"]; got != "origin/main" {
			t.Fatalf("upstream = %#v, want %q", got, "origin/main")
		}
		remotes, ok := payload["remotes"].([]interface{})
		if !ok || len(remotes) != 1 {
			t.Fatalf("remotes = %#v, want 1 remote entry", payload["remotes"])
		}
		conflicts, ok := payload["conflicts"].([]interface{})
		if !ok || len(conflicts) != 1 {
			t.Fatalf("conflicts = %#v, want 1 conflict entry", payload["conflicts"])
		}
		mergeChanges, ok := payload["mergeChanges"].([]interface{})
		if !ok || len(mergeChanges) != 1 {
			t.Fatalf("mergeChanges = %#v, want 1 merge change entry", payload["mergeChanges"])
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for git repository state event")
	}

	dispose()

	header, _ = waitForIPCRequest(t, fake.messages, RequestTypeEventDispose)
	disposeID, err := toInt(header[1])
	if err != nil {
		t.Fatalf("decode dispose id: %v", err)
	}
	if disposeID != listenID {
		t.Fatalf("dispose id = %d, want %d", disposeID, listenID)
	}

	select {
	case _, ok := <-events:
		if ok {
			t.Fatal("event channel should be closed after dispose")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for event channel to close")
	}
}
