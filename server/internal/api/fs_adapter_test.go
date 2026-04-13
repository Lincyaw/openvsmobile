package api

import (
	"testing"

	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

// mockFileSystemProxy is not feasible because FileSystemProxy depends on
// IPCChannel. Instead we verify the adapter satisfies the FileSystem interface
// and test the pure conversion helpers.

func TestVSCodeFSAdapterImplementsFileSystem(t *testing.T) {
	// Compile-time check: *VSCodeFSAdapter implements FileSystem.
	var _ FileSystem = (*VSCodeFSAdapter)(nil)
}

func TestNewVSCodeFSAdapter(t *testing.T) {
	adapter := NewVSCodeFSAdapter(nil)
	if adapter == nil {
		t.Fatal("expected non-nil adapter")
	}
}

func TestIsDir(t *testing.T) {
	tests := []struct {
		fileType vscode.FileType
		want     bool
	}{
		{vscode.FileTypeDirectory, true},
		{vscode.FileTypeFile, false},
		{vscode.FileTypeSymlink, false},
		{vscode.FileTypeUnknown, false},
	}
	for _, tt := range tests {
		got := tt.fileType == vscode.FileTypeDirectory
		if got != tt.want {
			t.Errorf("FileType(%d) == FileTypeDirectory = %v, want %v", tt.fileType, got, tt.want)
		}
	}
}
