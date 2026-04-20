package vscode

import "testing"

type stubDocumentStore struct {
	files map[string][]byte
}

func newStubDocumentStore() *stubDocumentStore {
	return &stubDocumentStore{files: make(map[string][]byte)}
}

func (s *stubDocumentStore) ReadFile(path string) ([]byte, error) {
	return s.files[path], nil
}

func (s *stubDocumentStore) WriteFile(path string, content []byte) error {
	s.files[path] = append([]byte(nil), content...)
	return nil
}

func TestDocumentSyncServiceLifecycle(t *testing.T) {
	store := newStubDocumentStore()
	store.files["/workspace/doc.txt"] = []byte("disk")
	svc := NewDocumentSyncService(store)

	content := "draft\n"
	snapshot, err := svc.OpenDocument("/workspace/doc.txt", 1, &content)
	if err != nil {
		t.Fatalf("open document: %v", err)
	}
	if snapshot.Content != "draft\n" || snapshot.Version != 1 {
		t.Fatalf("unexpected open snapshot: %+v", snapshot)
	}

	snapshot, err = svc.ApplyDocumentChanges("/workspace/doc.txt", 2, []DocumentChange{{
		Range: &DocumentRange{
			Start: DocumentPosition{Line: 0, Character: 5},
			End:   DocumentPosition{Line: 0, Character: 5},
		},
		Text: " updated",
	}})
	if err != nil {
		t.Fatalf("apply changes: %v", err)
	}
	if snapshot.Content != "draft updated\n" || snapshot.Version != 2 {
		t.Fatalf("unexpected change snapshot: %+v", snapshot)
	}

	latest, err := svc.DocumentBuffer("/workspace/doc.txt")
	if err != nil {
		t.Fatalf("get document: %v", err)
	}
	if latest.Content != "draft updated\n" {
		t.Fatalf("latest content = %q, want %q", latest.Content, "draft updated\n")
	}

	if string(store.files["/workspace/doc.txt"]) != "disk" {
		t.Fatalf("disk content before save = %q, want unchanged", string(store.files["/workspace/doc.txt"]))
	}

	snapshot, err = svc.SaveDocument("/workspace/doc.txt")
	if err != nil {
		t.Fatalf("save document: %v", err)
	}
	if string(store.files["/workspace/doc.txt"]) != "draft updated\n" {
		t.Fatalf("saved content = %q, want %q", string(store.files["/workspace/doc.txt"]), "draft updated\n")
	}

	if err := svc.CloseDocument("/workspace/doc.txt"); err != nil {
		t.Fatalf("close document: %v", err)
	}
	if _, err := svc.DocumentBuffer("/workspace/doc.txt"); err == nil {
		t.Fatal("expected get after close to fail")
	}
}

func TestDocumentSyncServiceRejectsStaleVersionWithoutMutatingBuffer(t *testing.T) {
	svc := NewDocumentSyncService(newStubDocumentStore())
	content := "hello"
	if _, err := svc.OpenDocument("/workspace/conflict.txt", 1, &content); err != nil {
		t.Fatalf("open document: %v", err)
	}
	if _, err := svc.ApplyDocumentChanges("/workspace/conflict.txt", 2, []DocumentChange{{Text: "good"}}); err != nil {
		t.Fatalf("first change: %v", err)
	}

	_, err := svc.ApplyDocumentChanges("/workspace/conflict.txt", 2, []DocumentChange{{Text: "bad"}})
	if err == nil {
		t.Fatal("expected stale version conflict")
	}
	bridgeErr, ok := err.(*BridgeError)
	if !ok || bridgeErr.Code != "version_conflict" {
		t.Fatalf("stale version error = %#v, want version_conflict", err)
	}

	snapshot, err := svc.DocumentBuffer("/workspace/conflict.txt")
	if err != nil {
		t.Fatalf("get document: %v", err)
	}
	if snapshot.Content != "good" {
		t.Fatalf("content after stale version = %q, want %q", snapshot.Content, "good")
	}
}

func TestDocumentSyncServiceRejectsInvalidPositionWithoutMutatingBuffer(t *testing.T) {
	svc := NewDocumentSyncService(newStubDocumentStore())
	content := "hello\nworld\n"
	if _, err := svc.OpenDocument("/workspace/invalid.txt", 1, &content); err != nil {
		t.Fatalf("open document: %v", err)
	}

	_, err := svc.ApplyDocumentChanges("/workspace/invalid.txt", 2, []DocumentChange{{
		Range: &DocumentRange{
			Start: DocumentPosition{Line: 5, Character: 0},
			End:   DocumentPosition{Line: 5, Character: 0},
		},
		Text: "boom",
	}})
	if err == nil {
		t.Fatal("expected invalid position error")
	}
	bridgeErr, ok := err.(*BridgeError)
	if !ok || bridgeErr.Code != "invalid_position" {
		t.Fatalf("invalid position error = %#v, want invalid_position", err)
	}

	snapshot, err := svc.DocumentBuffer("/workspace/invalid.txt")
	if err != nil {
		t.Fatalf("get document: %v", err)
	}
	if snapshot.Content != "hello\nworld\n" {
		t.Fatalf("content after invalid change = %q, want original buffer", snapshot.Content)
	}
}

func TestDocumentSyncServiceDuplicateOpen_IdempotentSameVersionReusesExistingBuffer(t *testing.T) {
	svc := NewDocumentSyncService(newStubDocumentStore())
	content := "draft"
	if _, err := svc.OpenDocument("/workspace/reopen.txt", 1, &content); err != nil {
		t.Fatalf("open document: %v", err)
	}
	if _, err := svc.ApplyDocumentChanges("/workspace/reopen.txt", 2, []DocumentChange{{
		Range: &DocumentRange{
			Start: DocumentPosition{Line: 0, Character: 5},
			End:   DocumentPosition{Line: 0, Character: 5},
		},
		Text: " ok",
	}}); err != nil {
		t.Fatalf("apply changes: %v", err)
	}

	reopenContent := "draft ok"
	snapshot, err := svc.OpenDocument("/workspace/reopen.txt", 2, &reopenContent)
	if err != nil {
		t.Fatalf("idempotent reopen: %v", err)
	}
	if snapshot.Version != 2 || snapshot.Content != "draft ok" {
		t.Fatalf("reopen snapshot = %+v, want version=2 content=%q", snapshot, "draft ok")
	}

	latest, err := svc.DocumentBuffer("/workspace/reopen.txt")
	if err != nil {
		t.Fatalf("get document: %v", err)
	}
	if latest.Version != 2 || latest.Content != "draft ok" {
		t.Fatalf("buffer after reopen = %+v, want version=2 content=%q", latest, "draft ok")
	}
}

func TestDocumentSyncServiceDuplicateOpen_RejectsStaleOrConflictingReopenWithoutMutatingBuffer(t *testing.T) {
	svc := NewDocumentSyncService(newStubDocumentStore())
	content := "draft"
	if _, err := svc.OpenDocument("/workspace/reopen-conflict.txt", 1, &content); err != nil {
		t.Fatalf("open document: %v", err)
	}
	if _, err := svc.ApplyDocumentChanges("/workspace/reopen-conflict.txt", 2, []DocumentChange{{
		Range: &DocumentRange{
			Start: DocumentPosition{Line: 0, Character: 5},
			End:   DocumentPosition{Line: 0, Character: 5},
		},
		Text: " ok",
	}}); err != nil {
		t.Fatalf("apply changes: %v", err)
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
			_, err := svc.OpenDocument("/workspace/reopen-conflict.txt", tc.version, &tc.content)
			if err == nil {
				t.Fatal("expected reopen to fail")
			}
			bridgeErr, ok := err.(*BridgeError)
			if !ok || bridgeErr.Code != "version_conflict" {
				t.Fatalf("reopen error = %#v, want version_conflict", err)
			}

			latest, err := svc.DocumentBuffer("/workspace/reopen-conflict.txt")
			if err != nil {
				t.Fatalf("get document: %v", err)
			}
			if latest.Version != 2 || latest.Content != "draft ok" {
				t.Fatalf("buffer after rejected reopen = %+v, want version=2 content=%q", latest, "draft ok")
			}
		})
	}
}

func TestDocumentSyncServiceApplyDocumentChanges_UnicodeRanges(t *testing.T) {
	for _, tc := range []struct {
		name        string
		initial     string
		version     int
		changes     []DocumentChange
		wantContent string
	}{
		{
			name:    "same line after multibyte character",
			initial: "A你B\n",
			version: 2,
			changes: []DocumentChange{{
				Range: &DocumentRange{
					Start: DocumentPosition{Line: 0, Character: 2},
					End:   DocumentPosition{Line: 0, Character: 2},
				},
				Text: "!",
			}},
			wantContent: "A你!B\n",
		},
		{
			name:    "cross line span across multibyte characters",
			initial: "你!x\n世y\n",
			version: 3,
			changes: []DocumentChange{{
				Range: &DocumentRange{
					Start: DocumentPosition{Line: 0, Character: 2},
					End:   DocumentPosition{Line: 1, Character: 1},
				},
				Text: "++",
			}},
			wantContent: "你!++y\n",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			svc := NewDocumentSyncService(newStubDocumentStore())
			if _, err := svc.OpenDocument("/workspace/unicode.txt", 1, &tc.initial); err != nil {
				t.Fatalf("open document: %v", err)
			}

			snapshot, err := svc.ApplyDocumentChanges("/workspace/unicode.txt", tc.version, tc.changes)
			if err != nil {
				t.Fatalf("apply unicode change: %v", err)
			}
			if snapshot.Version != tc.version || snapshot.Content != tc.wantContent {
				t.Fatalf("snapshot after unicode change = %+v, want version=%d content=%q", snapshot, tc.version, tc.wantContent)
			}

			latest, err := svc.DocumentBuffer("/workspace/unicode.txt")
			if err != nil {
				t.Fatalf("get document: %v", err)
			}
			if latest.Content != tc.wantContent {
				t.Fatalf("buffer after unicode change = %q, want %q", latest.Content, tc.wantContent)
			}
		})
	}
}

func TestDocumentSyncServiceRequiresOpenDocumentForChangeSaveAndClose(t *testing.T) {
	svc := NewDocumentSyncService(newStubDocumentStore())

	for _, tc := range []struct {
		name string
		run  func() error
	}{
		{
			name: "change",
			run: func() error {
				_, err := svc.ApplyDocumentChanges("/workspace/missing.txt", 1, []DocumentChange{{Text: "ignored"}})
				return err
			},
		},
		{
			name: "save",
			run: func() error {
				_, err := svc.SaveDocument("/workspace/missing.txt")
				return err
			},
		},
		{
			name: "close",
			run: func() error {
				return svc.CloseDocument("/workspace/missing.txt")
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.run()
			if err == nil {
				t.Fatal("expected document_not_open error")
			}
			bridgeErr, ok := err.(*BridgeError)
			if !ok || bridgeErr.Code != "document_not_open" {
				t.Fatalf("%s error = %#v, want document_not_open", tc.name, err)
			}
		})
	}
}
