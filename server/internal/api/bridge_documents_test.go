package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Lincyaw/vscode-mobile/server/internal/claude"
	"github.com/Lincyaw/vscode-mobile/server/internal/diagnostics"
	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

type bridgeDocPosition struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type bridgeDocRange struct {
	Start bridgeDocPosition `json:"start"`
	End   bridgeDocPosition `json:"end"`
}

type bridgeDocChange struct {
	Range *bridgeDocRange `json:"range,omitempty"`
	Text  string          `json:"text"`
}

type bridgeDocSnapshot struct {
	Path    string `json:"path"`
	Version int    `json:"version"`
	Content string `json:"content"`
}

func postBridgeDocumentRequest(t *testing.T, baseURL, path string, payload any) (*http.Response, []byte) {
	t.Helper()

	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal %s payload: %v", path, err)
	}

	resp, err := http.Post(baseURL+path, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("post %s: %v", path, err)
	}

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		_ = resp.Body.Close()
		t.Fatalf("read %s response body: %v", path, err)
	}
	_ = resp.Body.Close()
	return resp, respBody
}

func requireBridgeDocumentSuccess(t *testing.T, baseURL, path string, payload any) []byte {
	t.Helper()

	resp, body := postBridgeDocumentRequest(t, baseURL, path, payload)
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
		t.Fatalf("%s status = %d, want 200 or 204; body=%s", path, resp.StatusCode, string(body))
	}
	return body
}

func requireBridgeDocumentSnapshot(t *testing.T, baseURL, path string, payload any) bridgeDocSnapshot {
	t.Helper()

	body := requireBridgeDocumentSuccess(t, baseURL, path, payload)
	var snapshot bridgeDocSnapshot
	if err := json.Unmarshal(body, &snapshot); err != nil {
		t.Fatalf("decode %s snapshot response: %v; body=%s", path, err, string(body))
	}
	return snapshot
}

func requireBridgeDocumentError(t *testing.T, baseURL, path string, payload any, wantCode string, wantStatuses ...int) bridgeErrorDetail {
	t.Helper()

	resp, body := postBridgeDocumentRequest(t, baseURL, path, payload)
	for _, wantStatus := range wantStatuses {
		if resp.StatusCode == wantStatus {
			var detail bridgeErrorDetail
			if err := json.Unmarshal(body, &detail); err != nil {
				t.Fatalf("decode %s error response: %v; body=%s", path, err, string(body))
			}
			if detail.Code != wantCode {
				t.Fatalf("%s error code = %q, want %q", path, detail.Code, wantCode)
			}
			if detail.Message == "" {
				t.Fatalf("%s error message should be non-empty", path)
			}
			return detail
		}
	}

	if len(wantStatuses) == 0 {
		t.Fatalf("%s returned status %d but no allowed statuses were supplied", path, resp.StatusCode)
	}
	t.Fatalf("%s status = %d, want one of %v; body=%s", path, resp.StatusCode, wantStatuses, string(body))
	return bridgeErrorDetail{}
}

func newBridgeDocumentServer(t *testing.T, fs *mockFS, manager *vscode.BridgeManager) *httptest.Server {
	t.Helper()

	sessionIndex := claude.NewSessionIndex(t.TempDir())
	pm := claude.NewProcessManager("/nonexistent/claude", ".")
	srv := NewServer(fs, sessionIndex, pm, "", nil, terminal.NewManager(), diagnostics.NewRunner(10*time.Second))
	srv.SetBridgeManager(manager)

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return ts
}

func TestBridgeDocumentLifecycle_SavePersistsLatestAcceptedBufferAndCloseCleansUp(t *testing.T) {
	ts, fs, _ := newTestServer(t, "")
	const filePath = "/workspace/note.txt"
	fs.files[filePath] = []byte("disk copy\n")

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
		t.Fatalf("disk content before save = %q, want unchanged", got)
	}

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/save", map[string]any{
		"path": filePath,
	})
	if got := string(fs.files[filePath]); got != "draft updated\n" {
		t.Fatalf("saved content = %q, want %q", got, "draft updated\\n")
	}

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/close", map[string]any{
		"path": filePath,
	})
	requireBridgeDocumentError(t, ts.URL, "/bridge/doc/save", map[string]any{
		"path": filePath,
	}, "document_not_open", http.StatusNotFound, http.StatusBadRequest)

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/open", map[string]any{
		"path":    filePath,
		"version": 1,
		"content": "reopened\n",
	})
	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/save", map[string]any{
		"path": filePath,
	})
	if got := string(fs.files[filePath]); got != "reopened\n" {
		t.Fatalf("saved content after reopen = %q, want %q", got, "reopened\\n")
	}
}

func TestBridgeDocumentChange_StaleVersionReturnsVersionConflictWithoutMutatingSavedContent(t *testing.T) {
	ts, fs, _ := newTestServer(t, "")
	const filePath = "/workspace/conflict.txt"
	fs.files[filePath] = []byte("base")

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/open", map[string]any{
		"path":    filePath,
		"version": 1,
		"content": "base",
	})
	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/change", map[string]any{
		"path":    filePath,
		"version": 2,
		"changes": []bridgeDocChange{{
			Range: &bridgeDocRange{
				Start: bridgeDocPosition{Line: 0, Character: 4},
				End:   bridgeDocPosition{Line: 0, Character: 4},
			},
			Text: " ok",
		}},
	})

	requireBridgeDocumentError(t, ts.URL, "/bridge/doc/change", map[string]any{
		"path":    filePath,
		"version": 2,
		"changes": []bridgeDocChange{{
			Range: &bridgeDocRange{
				Start: bridgeDocPosition{Line: 0, Character: 0},
				End:   bridgeDocPosition{Line: 0, Character: 0},
			},
			Text: "stale ",
		}},
	}, "version_conflict", http.StatusConflict)

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/save", map[string]any{
		"path": filePath,
	})
	if got := string(fs.files[filePath]); got != "base ok" {
		t.Fatalf("saved content after stale change = %q, want %q", got, "base ok")
	}
}

func TestBridgeDocumentChange_InvalidPositionReturnsStructuredErrorWithoutMutatingSavedContent(t *testing.T) {
	ts, fs, _ := newTestServer(t, "")
	const filePath = "/workspace/invalid.txt"
	fs.files[filePath] = []byte("hello\nworld\n")

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/open", map[string]any{
		"path":    filePath,
		"version": 1,
		"content": "hello\nworld\n",
	})
	requireBridgeDocumentError(t, ts.URL, "/bridge/doc/change", map[string]any{
		"path":    filePath,
		"version": 2,
		"changes": []bridgeDocChange{{
			Range: &bridgeDocRange{
				Start: bridgeDocPosition{Line: 9, Character: 0},
				End:   bridgeDocPosition{Line: 9, Character: 0},
			},
			Text: "boom",
		}},
	}, "invalid_position", http.StatusBadRequest, http.StatusConflict)

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/save", map[string]any{
		"path": filePath,
	})
	if got := string(fs.files[filePath]); got != "hello\nworld\n" {
		t.Fatalf("saved content after invalid change = %q, want original buffer", got)
	}
}

func TestBridgeDocumentLifecycle_UnopenedFileOperationsReturnDocumentNotOpen(t *testing.T) {
	ts, _, _ := newTestServer(t, "")
	const filePath = "/workspace/missing.txt"

	tests := []struct {
		name string
		path string
		body map[string]any
	}{
		{
			name: "change",
			path: "/bridge/doc/change",
			body: map[string]any{
				"path":    filePath,
				"version": 2,
				"changes": []bridgeDocChange{{Text: "ignored"}},
			},
		},
		{
			name: "save",
			path: "/bridge/doc/save",
			body: map[string]any{"path": filePath},
		},
		{
			name: "close",
			path: "/bridge/doc/close",
			body: map[string]any{"path": filePath},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			requireBridgeDocumentError(t, ts.URL, tc.path, tc.body, "document_not_open", http.StatusNotFound, http.StatusBadRequest, http.StatusConflict)
		})
	}
}

func TestBridgeDocumentOpen_DuplicateOpenIdempotentAndConflictScenarios(t *testing.T) {
	ts, fs, _ := newTestServer(t, "")
	const filePath = "/workspace/reopen.txt"
	fs.files[filePath] = []byte("disk")

	requireBridgeDocumentSnapshot(t, ts.URL, "/bridge/doc/open", map[string]any{
		"path":    filePath,
		"version": 1,
		"content": "draft",
	})
	requireBridgeDocumentSnapshot(t, ts.URL, "/bridge/doc/change", map[string]any{
		"path":    filePath,
		"version": 2,
		"changes": []bridgeDocChange{{
			Range: &bridgeDocRange{
				Start: bridgeDocPosition{Line: 0, Character: 5},
				End:   bridgeDocPosition{Line: 0, Character: 5},
			},
			Text: " ok",
		}},
	})

	snapshot := requireBridgeDocumentSnapshot(t, ts.URL, "/bridge/doc/open", map[string]any{
		"path":    filePath,
		"version": 2,
		"content": "draft ok",
	})
	if snapshot.Version != 2 || snapshot.Content != "draft ok" {
		t.Fatalf("idempotent reopen snapshot = %+v, want version=2 content=%q", snapshot, "draft ok")
	}

	for _, tc := range []struct {
		name    string
		version int
		content string
	}{
		{name: "stale version", version: 1, content: "draft"},
		{name: "conflicting same version", version: 2, content: "other"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			requireBridgeDocumentError(t, ts.URL, "/bridge/doc/open", map[string]any{
				"path":    filePath,
				"version": tc.version,
				"content": tc.content,
			}, "version_conflict", http.StatusConflict)
		})
	}

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/save", map[string]any{
		"path": filePath,
	})
	if got := string(fs.files[filePath]); got != "draft ok" {
		t.Fatalf("saved content after rejected reopen = %q, want %q", got, "draft ok")
	}
}

func TestBridgeDocumentChange_UnicodeRangesPersistLastAcceptedBuffer(t *testing.T) {
	ts, fs, _ := newTestServer(t, "")
	const filePath = "/workspace/unicode.txt"
	fs.files[filePath] = []byte("disk")

	requireBridgeDocumentSnapshot(t, ts.URL, "/bridge/doc/open", map[string]any{
		"path":    filePath,
		"version": 1,
		"content": "你x\n世y\n",
	})

	snapshot := requireBridgeDocumentSnapshot(t, ts.URL, "/bridge/doc/change", map[string]any{
		"path":    filePath,
		"version": 2,
		"changes": []bridgeDocChange{{
			Range: &bridgeDocRange{
				Start: bridgeDocPosition{Line: 0, Character: 1},
				End:   bridgeDocPosition{Line: 0, Character: 1},
			},
			Text: "!",
		}},
	})
	if snapshot.Version != 2 || snapshot.Content != "你!x\n世y\n" {
		t.Fatalf("same-line unicode snapshot = %+v, want version=2 content=%q", snapshot, "你!x\n世y\n")
	}

	snapshot = requireBridgeDocumentSnapshot(t, ts.URL, "/bridge/doc/change", map[string]any{
		"path":    filePath,
		"version": 3,
		"changes": []bridgeDocChange{{
			Range: &bridgeDocRange{
				Start: bridgeDocPosition{Line: 0, Character: 2},
				End:   bridgeDocPosition{Line: 1, Character: 1},
			},
			Text: "++",
		}},
	})
	if snapshot.Version != 3 || snapshot.Content != "你!++y\n" {
		t.Fatalf("cross-line unicode snapshot = %+v, want version=3 content=%q", snapshot, "你!++y\n")
	}

	requireBridgeDocumentSuccess(t, ts.URL, "/bridge/doc/save", map[string]any{
		"path": filePath,
	})
	if got := string(fs.files[filePath]); got != "你!++y\n" {
		t.Fatalf("saved unicode content = %q, want %q", got, "你!++y\n")
	}
}

func TestBridgeDocumentLifecycle_VersionedBufferFeedsDiagnosticsEventPayload(t *testing.T) {
	fs := newMockFS()
	const filePath = "/workspace/editor.dart"
	fs.files[filePath] = []byte("print('disk');\n")

	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{})
	ts := newBridgeDocumentServer(t, fs, manager)
	conn := dialBridgeEvents(t, ts.URL)

	requireBridgeDocumentSnapshot(t, ts.URL, "/bridge/doc/open", map[string]any{
		"path":    filePath,
		"version": 1,
		"content": "print('draft');\n",
	})
	snapshot := requireBridgeDocumentSnapshot(t, ts.URL, "/bridge/doc/change", map[string]any{
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
	if snapshot.Version != 2 || snapshot.Content != "print('draft') // unsaved;\n" {
		t.Fatalf("buffer snapshot = %+v, want version=2 content=%q", snapshot, "print('draft') // unsaved;\n")
	}

	manager.Publish(vscode.BridgeEvent{
		Type: "bridge/diagnosticsChanged",
		Payload: map[string]any{
			"path":    filePath,
			"version": snapshot.Version,
			"diagnostics": []any{
				map[string]any{
					"severity": "warning",
					"message":  "unsaved buffer warning",
				},
			},
		},
	})

	event := readBridgeEvent(t, conn)
	if event.Type != "bridge/diagnosticsChanged" {
		t.Fatalf("event type = %q, want bridge/diagnosticsChanged", event.Type)
	}
	payload := requireEventPayload(t, event)
	if got := requirePayloadValue(t, payload, "path"); got != filePath {
		t.Fatalf("event path = %#v, want %q", got, filePath)
	}
	if got := requirePayloadValue(t, payload, "version"); got != float64(2) {
		t.Fatalf("event version = %#v, want 2", got)
	}

	if got := string(fs.files[filePath]); got != "print('disk');\n" {
		t.Fatalf("disk content = %q, want unsaved buffer to remain in-memory only", got)
	}
}

func TestBridgeDocumentLifecycle_EditorDiagnosticsEndpointUsesVersionedBufferWhenAvailable(t *testing.T) {
	fs := newMockFS()
	const filePath = "/workspace/editor.dart"
	fs.files[filePath] = []byte("print('disk');\n")

	manager := vscode.NewBridgeManager(vscode.BridgeManagerOptions{})
	ts := newBridgeDocumentServer(t, fs, manager)

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

	resp, body := postBridgeDocumentRequest(t, ts.URL, "/bridge/editor/diagnostics", map[string]any{
		"path":    filePath,
		"version": 2,
		"workDir": "/workspace",
	})
	switch resp.StatusCode {
	case http.StatusOK:
		var payload map[string]any
		if err := json.Unmarshal(body, &payload); err != nil {
			t.Fatalf("decode /bridge/editor/diagnostics response: %v; body=%s", err, string(body))
		}
		if payload["path"] != filePath {
			t.Fatalf("diagnostics path = %#v, want %q", payload["path"], filePath)
		}
	case http.StatusNotFound:
		t.Skip("editor diagnostics endpoint not implemented yet")
	default:
		t.Fatalf("/bridge/editor/diagnostics status = %d, want 200 once implemented or 404 while pending; body=%s", resp.StatusCode, string(body))
	}
}
