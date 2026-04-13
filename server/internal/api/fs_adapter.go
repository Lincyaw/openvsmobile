package api

import (
	"path/filepath"

	"github.com/Lincyaw/vscode-mobile/server/internal/claude"
	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

// VSCodeFSAdapter adapts a vscode.FileSystemProxy to the api.FileSystem
// interface, converting between vscode and claude types.
type VSCodeFSAdapter struct {
	fsp *vscode.FileSystemProxy
}

// NewVSCodeFSAdapter creates a new adapter wrapping the given FileSystemProxy.
func NewVSCodeFSAdapter(fsp *vscode.FileSystemProxy) *VSCodeFSAdapter {
	return &VSCodeFSAdapter{fsp: fsp}
}

// ReadDir lists directory entries, converting vscode.DirEntry to claude.DirEntry.
func (a *VSCodeFSAdapter) ReadDir(path string) ([]claude.DirEntry, error) {
	entries, err := a.fsp.Readdir(path)
	if err != nil {
		return nil, err
	}
	result := make([]claude.DirEntry, len(entries))
	for i, e := range entries {
		result[i] = claude.DirEntry{
			Name:  e.Name,
			IsDir: e.Type == vscode.FileTypeDirectory,
		}
	}
	return result, nil
}

// ReadFile reads the contents of a file.
func (a *VSCodeFSAdapter) ReadFile(path string) ([]byte, error) {
	return a.fsp.ReadFile(path)
}

// WriteFile writes content to a file with create and overwrite enabled.
func (a *VSCodeFSAdapter) WriteFile(path string, content []byte) error {
	return a.fsp.WriteFile(path, content, vscode.FileWriteOptions{
		Create:    true,
		Overwrite: true,
	})
}

// Stat returns file metadata, converting vscode.FileStat to claude.FileStat.
func (a *VSCodeFSAdapter) Stat(path string) (*claude.FileStat, error) {
	stat, err := a.fsp.Stat(path)
	if err != nil {
		return nil, err
	}
	return &claude.FileStat{
		Name:  filepath.Base(path),
		IsDir: stat.Type == vscode.FileTypeDirectory,
		Size:  stat.Size,
	}, nil
}

// Delete removes a file or directory recursively.
func (a *VSCodeFSAdapter) Delete(path string) error {
	return a.fsp.Delete(path, vscode.FileDeleteOptions{
		Recursive: true,
	})
}

// MkDir creates a directory at the given path.
func (a *VSCodeFSAdapter) MkDir(path string) error {
	return a.fsp.Mkdir(path)
}
