package vscode

import (
	"context"
	"testing"
	"time"
)

func TestWorkspaceService_StartSubscribesAndPublishesFolderChanges(t *testing.T) {
	ts, fake := newFakeVSCodeServer(t, 0)

	client := NewClient()
	if err := client.Connect(context.Background(), ts.URL, ""); err != nil {
		t.Fatalf("connect client: %v", err)
	}
	defer client.Close()

	manager := readyEditorManager(t, client)
	manager.capabilities.Capabilities["workspace"] = map[string]interface{}{
		"enabled": true,
		"folders": true,
	}

	service := NewWorkspaceService(client, manager)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	service.Start(ctx)
	defer service.Close()

	manager.Publish(BridgeEvent{Type: "bridge/ready", Payload: map[string]any{}})

	header, body := waitForIPCRequest(t, fake.messages, RequestTypeEventListen)
	if got := header[2]; got != workspaceChannelName {
		t.Fatalf("channel = %#v, want %q", got, workspaceChannelName)
	}
	if got := header[3]; got != "workspaceChanged" {
		t.Fatalf("event = %#v, want %q", got, "workspaceChanged")
	}
	listenID, err := toInt(header[1])
	if err != nil {
		t.Fatalf("decode listen id: %v", err)
	}
	payload, ok := body.(map[string]interface{})
	if !ok {
		t.Fatalf("listen body = %#v, want map[string]interface{}", body)
	}
	if len(payload) != 0 {
		t.Fatalf("listen body = %#v, want empty payload", payload)
	}

	events, unsubscribe := manager.Subscribe(false)
	defer unsubscribe()

	client.onMessage(EncodeIPCMessage(
		[]interface{}{int(ResponseTypeEventFire), listenID},
		map[string]interface{}{
			"type":           "foldersChanged",
			"workbenchState": "workspace",
			"folders": []interface{}{
				map[string]interface{}{
					"uri":   "file:///workspace",
					"path":  "/workspace",
					"name":  "workspace",
					"index": 0,
				},
			},
			"added": []interface{}{
				map[string]interface{}{
					"uri":   "file:///workspace/new",
					"path":  "/workspace/new",
					"name":  "new",
					"index": 1,
				},
			},
			"removed": []interface{}{},
			"changed": []interface{}{},
		},
	))

	select {
	case raw := <-events:
		if raw.Type != "workspace/foldersChanged" {
			t.Fatalf("event type = %q, want %q", raw.Type, "workspace/foldersChanged")
		}
		envelope, ok := raw.Payload.(WorkspaceChangedEnvelope)
		if !ok {
			t.Fatalf("payload = %#v, want WorkspaceChangedEnvelope", raw.Payload)
		}
		if got := envelope.WorkbenchState; got != "workspace" {
			t.Fatalf("workbenchState = %#v, want %q", got, "workspace")
		}
		if len(envelope.Added) != 1 {
			t.Fatalf("added = %#v, want 1 folder", envelope.Added)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for workspace foldersChanged event")
	}
}
