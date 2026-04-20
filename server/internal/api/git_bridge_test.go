package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"path/filepath"
	"reflect"
	"testing"
	"time"
	"unsafe"

	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

func decodeBridgeErrorResponse(t *testing.T, resp *http.Response) bridgeErrorDetail {
	t.Helper()

	defer resp.Body.Close()
	var body bridgeErrorDetail
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode bridge error response: %v", err)
	}
	return body
}

func waitForBridgeSubscribers(t *testing.T, manager *vscode.BridgeManager) []chan vscode.BridgeEvent {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		value := reflect.ValueOf(manager).Elem().FieldByName("subscribers")
		value = reflect.NewAt(value.Type(), unsafe.Pointer(value.UnsafeAddr())).Elem()

		keys := value.MapKeys()
		if len(keys) > 0 {
			subscribers := make([]chan vscode.BridgeEvent, 0, len(keys))
			for _, key := range keys {
				subscribers = append(subscribers, key.Interface().(chan vscode.BridgeEvent))
			}
			return subscribers
		}
		time.Sleep(20 * time.Millisecond)
	}

	t.Fatal("timed out waiting for bridge websocket subscriber registration")
	return nil
}

func TestGitBridgeRepository_NotReadyReturnsStructuredError(t *testing.T) {
	ts, _, _ := newTestServer(t, "")

	resp, err := http.Get(ts.URL + "/bridge/git/repository?path=" + url.QueryEscape(t.TempDir()))
	if err != nil {
		t.Fatal(err)
	}

	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusServiceUnavailable)
	}

	body := decodeBridgeErrorResponse(t, resp)
	if body.Code != "bridge_not_ready" {
		t.Fatalf("error code = %q, want %q", body.Code, "bridge_not_ready")
	}
	if body.Message == "" {
		t.Fatal("expected bridge_not_ready message to be non-empty")
	}
}

func TestGitBridgeRepository_InvalidPathRejectedBeforeBridgeCall(t *testing.T) {
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
		Capabilities: map[string]any{
			"git": map[string]any{"enabled": true},
		},
	})

	ts := newBridgeEnabledServer(t, manager)
	_ = waitForReadyCapabilities(t, ts.URL)

	missingPath := filepath.Join(t.TempDir(), "missing-repo")
	resp, err := http.Get(ts.URL + "/bridge/git/repository?path=" + url.QueryEscape(missingPath))
	if err != nil {
		t.Fatal(err)
	}

	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusBadRequest)
	}

	body := decodeBridgeErrorResponse(t, resp)
	if body.Code != "invalid_path" {
		t.Fatalf("error code = %q, want %q", body.Code, "invalid_path")
	}
}

func TestGitBridgeCommandEndpoints_NotReadyReturnStructuredErrors(t *testing.T) {
	ts, _, _ := newTestServer(t, "")
	repoPath := t.TempDir()

	tests := []struct {
		name string
		path string
		body map[string]any
	}{
		{name: "stage", path: "/bridge/git/stage", body: map[string]any{"path": repoPath, "file": "lib/file.dart"}},
		{name: "unstage", path: "/bridge/git/unstage", body: map[string]any{"path": repoPath, "file": "lib/file.dart"}},
		{name: "commit", path: "/bridge/git/commit", body: map[string]any{"path": repoPath, "message": "ship it"}},
		{name: "checkout", path: "/bridge/git/checkout", body: map[string]any{"path": repoPath, "ref": "feature/git-bridge"}},
		{name: "fetch", path: "/bridge/git/fetch", body: map[string]any{"path": repoPath, "remote": "origin"}},
		{name: "pull", path: "/bridge/git/pull", body: map[string]any{"path": repoPath, "remote": "origin", "branch": "main"}},
		{name: "push", path: "/bridge/git/push", body: map[string]any{"path": repoPath, "remote": "origin", "branch": "main"}},
		{name: "discard", path: "/bridge/git/discard", body: map[string]any{"path": repoPath, "file": "lib/file.dart"}},
		{name: "stash", path: "/bridge/git/stash", body: map[string]any{"path": repoPath, "message": "wip"}},
		{name: "stash apply", path: "/bridge/git/stash/apply", body: map[string]any{"path": repoPath, "stash": "stash@{0}"}},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			payload, err := json.Marshal(tc.body)
			if err != nil {
				t.Fatalf("marshal request body: %v", err)
			}

			resp, err := http.Post(ts.URL+tc.path, "application/json", bytes.NewReader(payload))
			if err != nil {
				t.Fatal(err)
			}

			if resp.StatusCode != http.StatusServiceUnavailable {
				t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusServiceUnavailable)
			}

			body := decodeBridgeErrorResponse(t, resp)
			if body.Code != "bridge_not_ready" {
				t.Fatalf("error code = %q, want %q", body.Code, "bridge_not_ready")
			}
			if body.Message == "" {
				t.Fatal("expected bridge_not_ready message to be non-empty")
			}
		})
	}
}

func TestGitLegacyBridgeRouteShape_ReplacesRemovedAPIGitEndpoints(t *testing.T) {
	ts, _, _ := newTestServer(t, "")
	repoPath := t.TempDir()

	reqBody, err := json.Marshal(map[string]any{"path": repoPath, "ref": "feature/git-bridge"})
	if err != nil {
		t.Fatalf("marshal request body: %v", err)
	}

	resp, err := http.Post(ts.URL+"/bridge/git/checkout", "application/json", bytes.NewReader(reqBody))
	if err != nil {
		t.Fatal(err)
	}

	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusServiceUnavailable)
	}

	body := decodeBridgeErrorResponse(t, resp)
	if body.Code != "bridge_not_ready" {
		t.Fatalf("error code = %q, want %q", body.Code, "bridge_not_ready")
	}
}

func TestBridgeEventsWebSocket_ForwardsGitRepositoryChangedEnvelope(t *testing.T) {
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{})
	ts := newBridgeEnabledServer(t, manager)
	conn := dialBridgeEvents(t, ts.URL)

	event := vscode.BridgeEvent{
		Type: "bridge/git/repositoryChanged",
		Payload: map[string]any{
			"path": "/workspace/repo",
			"repository": map[string]any{
				"branch":       "main",
				"upstream":     "origin/main",
				"ahead":        1,
				"behind":       0,
				"remotes":      []map[string]any{{"name": "origin", "fetchUrl": "git@github.com:Lincyaw/openvsmobile.git"}},
				"staged":       []map[string]any{{"path": "lib/staged.dart", "status": "modified"}},
				"unstaged":     []map[string]any{},
				"untracked":    []map[string]any{},
				"conflicts":    []map[string]any{{"path": "lib/conflicted.dart", "status": "both_modified"}},
				"mergeChanges": []map[string]any{{"path": "lib/merge_only.dart", "status": "added_by_them"}},
			},
		},
	}

	for _, subscriber := range waitForBridgeSubscribers(t, manager) {
		subscriber <- event
	}

	got := readBridgeEvent(t, conn)
	if got.Type != "bridge/git/repositoryChanged" {
		t.Fatalf("event type = %q, want %q", got.Type, "bridge/git/repositoryChanged")
	}

	payload := requireEventPayload(t, got)
	if requirePayloadValue(t, payload, "path") != "/workspace/repo" {
		t.Fatalf("payload path = %#v, want %q", payload["path"], "/workspace/repo")
	}

	repository, ok := requirePayloadValue(t, payload, "repository").(map[string]any)
	if !ok {
		t.Fatalf("repository payload = %#v, want map[string]any", payload["repository"])
	}
	if repository["branch"] != "main" {
		t.Fatalf("repository branch = %#v, want %q", repository["branch"], "main")
	}
	if len(repository["conflicts"].([]any)) != 1 {
		t.Fatalf("conflicts = %#v, want 1 entry", repository["conflicts"])
	}
	if len(repository["mergeChanges"].([]any)) != 1 {
		t.Fatalf("mergeChanges = %#v, want 1 entry", repository["mergeChanges"])
	}
}
