package github

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestStoreSaveLoadDeleteAndRecover(t *testing.T) {
	path := filepath.Join(t.TempDir(), "auth", "github-auth.json")
	store := NewStore(path)
	now := time.Date(2026, 4, 20, 9, 0, 0, 0, time.UTC)
	record := AuthRecord{
		GitHubHost:            "github.com",
		AccessToken:           "access-1",
		AccessTokenExpiresAt:  now.Add(1 * time.Hour),
		RefreshToken:          "refresh-1",
		RefreshTokenExpiresAt: now.Add(24 * time.Hour),
		AccountLogin:          "octocat",
		AccountID:             1,
	}

	if err := store.Save(record); err != nil {
		t.Fatalf("Save() error = %v", err)
	}
	loaded, err := store.Load("github.com")
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if loaded == nil || loaded.AccessToken != "access-1" || loaded.RefreshToken != "refresh-1" {
		t.Fatalf("Load() = %#v", loaded)
	}
	if loaded.AccessTokenExpiresAt.Format(time.RFC3339) != record.AccessTokenExpiresAt.Format(time.RFC3339) {
		t.Fatalf("access expiry mismatch: got %s want %s", loaded.AccessTokenExpiresAt, record.AccessTokenExpiresAt)
	}

	updated := record
	updated.AccessToken = "access-2"
	updated.RefreshToken = "refresh-2"
	if err := store.Save(updated); err != nil {
		t.Fatalf("Save(updated) error = %v", err)
	}
	loaded, err = store.Load("github.com")
	if err != nil {
		t.Fatalf("Load(updated) error = %v", err)
	}
	if loaded.AccessToken != "access-2" || loaded.RefreshToken != "refresh-2" {
		t.Fatalf("updated record not persisted: %#v", loaded)
	}

	if err := store.Delete("github.com"); err != nil {
		t.Fatalf("Delete() error = %v", err)
	}
	loaded, err = store.Load("github.com")
	if err != nil {
		t.Fatalf("Load(after delete) error = %v", err)
	}
	if loaded != nil {
		t.Fatalf("expected nil record after delete, got %#v", loaded)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("expected store file to be removed, stat err = %v", err)
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}
	if err := os.WriteFile(path, []byte("{not-json"), 0o644); err != nil {
		t.Fatalf("WriteFile(corrupt) error = %v", err)
	}
	if _, err := store.Load("github.com"); err == nil {
		t.Fatalf("expected Load() to fail on corrupt store")
	}
	if err := store.Save(record); err != nil {
		t.Fatalf("Save(recover) error = %v", err)
	}
	loaded, err = store.Load("github.com")
	if err != nil || loaded == nil {
		t.Fatalf("Load(recovered) = %#v, %v", loaded, err)
	}
}

func TestStoreUsesAtomicRename(t *testing.T) {
	path := filepath.Join(t.TempDir(), "github-auth.json")
	store := NewStore(path)
	record := AuthRecord{
		GitHubHost:            "github.com",
		AccessToken:           "access",
		AccessTokenExpiresAt:  time.Now().UTC().Add(time.Hour),
		RefreshToken:          "refresh",
		RefreshTokenExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	}
	if err := store.Save(record); err != nil {
		t.Fatalf("Save() error = %v", err)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatalf("ReadDir() error = %v", err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), "github-auth-") && strings.HasSuffix(entry.Name(), ".tmp") {
			t.Fatalf("temporary file leaked after atomic write: %s", entry.Name())
		}
	}
}
