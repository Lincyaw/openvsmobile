package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
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

func newAPIWorkspaceRuntimeServer(t *testing.T, responseFor func(command string, payload map[string]any) any) (*httptest.Server, <-chan apiEditorRequestCapture) {
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
			id, _ := hdr[1].(int)
			channelName, _ := hdr[2].(string)
			command, _ := hdr[3].(string)
			payload, _ := body.(map[string]any)
			if payload == nil {
				payload = map[string]any{}
			}
			if channelName != "openvsmobile/workspace" {
				t.Errorf("unexpected channel %q", channelName)
				return
			}
			select {
			case requests <- apiEditorRequestCapture{Command: command, Payload: payload}:
			default:
				t.Errorf("request buffer overflow for command %q", command)
				return
			}
			mustWriteAPIEditorProtocolMessage(t, conn, &vscode.ProtocolMessage{
				Type: vscode.ProtocolMessageRegular,
				Data: vscode.EncodeIPCMessage([]interface{}{int(vscode.ResponseTypePromiseSuccess), id}, responseFor(command, payload)),
			})
		}
	}))

	t.Cleanup(ts.Close)
	return ts, requests
}

func newAPIWorkspaceBridgeServer(t *testing.T, responseFor func(command string, payload map[string]any) any) (*httptest.Server, <-chan apiEditorRequestCapture) {
	t.Helper()

	runtimeServer, requests := newAPIWorkspaceRuntimeServer(t, responseFor)
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
		Generation:    "gen-workspace-tests",
		State:         "ready",
		BridgeVersion: "test",
		Capabilities: map[string]any{
			"workspace": map[string]any{
				"enabled":  true,
				"search":   true,
				"symbols":  true,
				"folders":  true,
				"problems": true,
			},
		},
	})

	client := vscode.NewClient()
	if err := client.Connect(context.Background(), runtimeServer.URL, ""); err != nil {
		t.Fatalf("connect runtime client: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })

	workspaceService := vscode.NewWorkspaceService(client, manager)
	sessionIndex := claude.NewSessionIndex(t.TempDir())
	pm := claude.NewProcessManager("/nonexistent/claude", ".")
	srv := NewServer(newMockFS(), sessionIndex, pm, "", nil, terminal.NewManager(), diagnostics.NewRunner(10*time.Second))
	srv.SetBridgeManager(manager)
	srv.SetWorkspaceService(workspaceService)

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	_ = waitForReadyCapabilities(t, ts.URL)
	return ts, requests
}

func postWorkspaceJSON(t *testing.T, baseURL, path string, payload any) (*http.Response, []byte) {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal request body: %v", err)
	}
	resp, err := http.Post(baseURL+path, "application/json", strings.NewReader(string(body)))
	if err != nil {
		t.Fatalf("POST %s failed: %v", path, err)
	}
	defer func() {
		if resp.Body != nil {
			_ = resp.Body.Close()
		}
	}()
	decoded, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read response body: %v", err)
	}
	return resp, decoded
}

func TestWorkspaceBridgeFoldersAndSymbols(t *testing.T) {
	root := t.TempDir()
	ts, requests := newAPIWorkspaceBridgeServer(t, func(command string, payload map[string]any) any {
		switch command {
		case "folders":
			return []map[string]any{{
				"uri":   "file://" + root,
				"path":  root,
				"name":  filepath.Base(root),
				"index": 0,
			}}
		case "symbols":
			return []map[string]any{{
				"name":          "MainWidget",
				"containerName": "lib/app.dart",
				"kind":          5,
				"uri":           "file://" + filepath.Join(root, "lib", "app.dart"),
				"path":          filepath.Join(root, "lib", "app.dart"),
				"range": map[string]any{
					"start": map[string]any{"line": 12, "character": 2},
					"end":   map[string]any{"line": 24, "character": 1},
				},
			}}
		default:
			return []map[string]any{}
		}
	})

	resp, err := http.Get(ts.URL + "/bridge/workspace/folders")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("folders status = %d, want %d", resp.StatusCode, http.StatusOK)
	}
	var folders []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&folders); err != nil {
		t.Fatalf("decode folders: %v", err)
	}
	if len(folders) != 1 || folders[0]["path"] != root {
		t.Fatalf("folders = %#v, want %s", folders, root)
	}
	if req := <-requests; req.Command != "folders" {
		t.Fatalf("command = %q, want folders", req.Command)
	}

	postResp, symbolsBody := postWorkspaceJSON(t, ts.URL, "/bridge/workspace/symbols", map[string]any{
		"query":   "Main",
		"workDir": root,
		"max":     25,
	})
	if postResp.StatusCode != http.StatusOK {
		t.Fatalf("symbols status = %d, want %d body=%s", postResp.StatusCode, http.StatusOK, string(symbolsBody))
	}
	var symbols []map[string]any
	if err := json.Unmarshal(symbolsBody, &symbols); err != nil {
		t.Fatalf("decode symbols body: %v; body=%s", err, string(symbolsBody))
	}
	if len(symbols) != 1 || symbols[0]["name"] != "MainWidget" {
		t.Fatalf("symbols response = %#v, want MainWidget", symbols)
	}
	if req := <-requests; req.Command != "symbols" {
		t.Fatalf("command = %q, want symbols", req.Command)
	} else if req.Payload["query"] != "Main" || req.Payload["workDir"] != root {
		t.Fatalf("symbols payload = %#v", req.Payload)
	}
}

func TestWorkspaceBridgeSearchAndProblems(t *testing.T) {
	root := t.TempDir()
	filePath := filepath.Join(root, "lib", "search_provider.dart")
	ts, requests := newAPIWorkspaceBridgeServer(t, func(command string, payload map[string]any) any {
		switch command {
		case "searchFiles":
			return []map[string]any{{
				"path":  filePath,
				"name":  "search_provider.dart",
				"isDir": false,
			}}
		case "searchText":
			return []map[string]any{{
				"file":        filePath,
				"line":        42,
				"column":      7,
				"content":     "provider.searchSymbols(query, rootPath);",
				"linesBefore": "switch (provider.searchMode) {",
				"linesAfter":  "break;",
			}}
		case "problems":
			return []map[string]any{{
				"path":     filePath,
				"severity": 1,
				"source":   "dart",
				"message":  "Unused import",
				"range": map[string]any{
					"start": map[string]any{"line": 3, "character": 0},
					"end":   map[string]any{"line": 3, "character": 6},
				},
			}}
		default:
			return []map[string]any{}
		}
	})

	filesResp, filesBody := postWorkspaceJSON(t, ts.URL, "/bridge/workspace/search/files", map[string]any{
		"query":   "search",
		"workDir": root,
		"max":     20,
	})
	if filesResp.StatusCode != http.StatusOK {
		t.Fatalf("files status = %d, want %d body=%s", filesResp.StatusCode, http.StatusOK, string(filesBody))
	}
	var files []map[string]any
	if err := json.Unmarshal(filesBody, &files); err != nil {
		t.Fatalf("decode file search body: %v; body=%s", err, string(filesBody))
	}
	if len(files) != 1 || files[0]["path"] != filePath {
		t.Fatalf("file search response = %#v, want search_provider.dart", files)
	}
	if req := <-requests; req.Command != "searchFiles" {
		t.Fatalf("command = %q, want searchFiles", req.Command)
	}

	textResp, textBody := postWorkspaceJSON(t, ts.URL, "/bridge/workspace/search/text", map[string]any{
		"query":   "searchSymbols",
		"workDir": root,
	})
	if textResp.StatusCode != http.StatusOK {
		t.Fatalf("text status = %d, want %d body=%s", textResp.StatusCode, http.StatusOK, string(textBody))
	}
	var matches []map[string]any
	if err := json.Unmarshal(textBody, &matches); err != nil {
		t.Fatalf("decode text search body: %v; body=%s", err, string(textBody))
	}
	if len(matches) != 1 || matches[0]["line"] != float64(42) {
		t.Fatalf("text search response = %#v, want line 42", matches)
	}
	if req := <-requests; req.Command != "searchText" {
		t.Fatalf("command = %q, want searchText", req.Command)
	}

	problemsResp, problemsBody := postWorkspaceJSON(t, ts.URL, "/bridge/workspace/problems", map[string]any{
		"workDir": root,
	})
	if problemsResp.StatusCode != http.StatusOK {
		t.Fatalf("problems status = %d, want %d body=%s", problemsResp.StatusCode, http.StatusOK, string(problemsBody))
	}
	var problems []map[string]any
	if err := json.Unmarshal(problemsBody, &problems); err != nil {
		t.Fatalf("decode problems body: %v; body=%s", err, string(problemsBody))
	}
	if len(problems) != 1 || problems[0]["message"] != "Unused import" {
		t.Fatalf("problems response = %#v, want Unused import", problems)
	}
	if req := <-requests; req.Command != "problems" {
		t.Fatalf("command = %q, want problems", req.Command)
	}
}

func TestBridgeEventsWebSocket_ForwardsWorkspaceFoldersChangedEnvelope(t *testing.T) {
	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{})
	ts := newBridgeEnabledServer(t, manager)
	conn := dialBridgeEvents(t, ts.URL)

	event := vscode.BridgeEvent{
		Type: "workspace/foldersChanged",
		Payload: map[string]any{
			"type":           "foldersChanged",
			"workbenchState": "workspace",
			"folders": []map[string]any{{
				"uri":   "file:///workspace",
				"path":  "/workspace",
				"name":  "workspace",
				"index": 0,
			}},
			"added": []map[string]any{{
				"uri":   "file:///workspace/new",
				"path":  "/workspace/new",
				"name":  "new",
				"index": 1,
			}},
			"removed": []map[string]any{},
			"changed": []map[string]any{},
		},
	}

	for _, subscriber := range waitForBridgeSubscribers(t, manager) {
		subscriber <- event
	}

	got := readBridgeEvent(t, conn)
	if got.Type != "workspace/foldersChanged" {
		t.Fatalf("event type = %q, want %q", got.Type, "workspace/foldersChanged")
	}
	payload := requireEventPayload(t, got)
	if payload["workbenchState"] != "workspace" {
		t.Fatalf("workbenchState = %#v, want %q", payload["workbenchState"], "workspace")
	}
	added, ok := payload["added"].([]any)
	if !ok || len(added) != 1 {
		t.Fatalf("added = %#v, want 1 folder", payload["added"])
	}
}
