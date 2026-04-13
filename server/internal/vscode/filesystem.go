package vscode

import (
	"fmt"
)

// FileType mirrors the VS Code FileType enum from files.ts.
type FileType int

const (
	FileTypeUnknown   FileType = 0
	FileTypeFile      FileType = 1
	FileTypeDirectory FileType = 2
	FileTypeSymlink   FileType = 64
)

// FileStat holds metadata about a file, matching VS Code's IStat interface.
type FileStat struct {
	Type        FileType `json:"type"`
	Mtime       int64    `json:"mtime"`
	Ctime       int64    `json:"ctime"`
	Size        int64    `json:"size"`
	Permissions int      `json:"permissions,omitempty"`
}

// DirEntry represents a single directory entry returned by Readdir.
type DirEntry struct {
	Name string   `json:"name"`
	Type FileType `json:"type"`
}

// FileWriteOptions mirrors VS Code's IFileWriteOptions.
type FileWriteOptions struct {
	Create    bool `json:"create"`
	Overwrite bool `json:"overwrite"`
	Unlock    bool `json:"unlock,omitempty"`
}

// FileDeleteOptions mirrors VS Code's IFileDeleteOptions.
type FileDeleteOptions struct {
	Recursive bool `json:"recursive"`
	UseTrash  bool `json:"useTrash,omitempty"`
}

// FileOverwriteOptions mirrors VS Code's IFileOverwriteOptions.
type FileOverwriteOptions struct {
	Overwrite bool `json:"overwrite"`
}

// WatchOptions mirrors VS Code's IWatchOptions.
type WatchOptions struct {
	Recursive bool     `json:"recursive"`
	Excludes  []string `json:"excludes"`
}

// UriComponents mirrors VS Code's UriComponents for IPC serialisation.
type UriComponents struct {
	Scheme    string `json:"scheme"`
	Authority string `json:"authority"`
	Path      string `json:"path"`
	Query     string `json:"query,omitempty"`
	Fragment  string `json:"fragment,omitempty"`
}

// RemoteFileSystemChannelName is the IPC channel name used for remote
// filesystem operations, matching REMOTE_FILE_SYSTEM_CHANNEL_NAME.
const RemoteFileSystemChannelName = "remoteFilesystem"

// FileSystemProxy provides Go-friendly access to the VS Code remote
// filesystem IPC channel. All paths are automatically wrapped in
// vscode-remote:// URIs for IPC communication.
type FileSystemProxy struct {
	channel   *IPCChannel
	authority string
}

// NewFileSystemProxy creates a proxy for the remote filesystem channel.
// authority is the remote authority string used in URI construction
// (typically the connection identifier).
func NewFileSystemProxy(ipc *IPCClient, authority string) *FileSystemProxy {
	return &FileSystemProxy{
		channel:   ipc.GetChannel(RemoteFileSystemChannelName),
		authority: authority,
	}
}

// pathToURI converts a local filesystem path to a VS Code remote URI.
func (fs *FileSystemProxy) pathToURI(path string) UriComponents {
	return UriComponents{
		Scheme:    "vscode-remote",
		Authority: fs.authority,
		Path:      path,
	}
}

// Stat returns file metadata for the given path.
func (fs *FileSystemProxy) Stat(path string) (*FileStat, error) {
	uri := fs.pathToURI(path)
	result, err := fs.channel.Call("stat", []interface{}{uri})
	if err != nil {
		return nil, fmt.Errorf("stat %s: %w", path, err)
	}
	return parseFileStat(result)
}

// Readdir lists entries in the directory at the given path.
func (fs *FileSystemProxy) Readdir(path string) ([]DirEntry, error) {
	uri := fs.pathToURI(path)
	result, err := fs.channel.Call("readdir", []interface{}{uri})
	if err != nil {
		return nil, fmt.Errorf("readdir %s: %w", path, err)
	}
	return parseDirEntries(result)
}

// ReadFile reads the entire contents of a file.
func (fs *FileSystemProxy) ReadFile(path string) ([]byte, error) {
	uri := fs.pathToURI(path)
	result, err := fs.channel.Call("readFile", []interface{}{uri})
	if err != nil {
		return nil, fmt.Errorf("readFile %s: %w", path, err)
	}

	// The server returns a VSBuffer which deserializes as []byte.
	switch v := result.(type) {
	case []byte:
		return v, nil
	case string:
		return []byte(v), nil
	default:
		return nil, fmt.Errorf("unexpected readFile result type: %T", result)
	}
}

// WriteFile writes content to a file with the given options.
func (fs *FileSystemProxy) WriteFile(path string, content []byte, opts FileWriteOptions) error {
	uri := fs.pathToURI(path)
	_, err := fs.channel.Call("writeFile", []interface{}{uri, content, opts})
	if err != nil {
		return fmt.Errorf("writeFile %s: %w", path, err)
	}
	return nil
}

// Rename moves a file or directory from source to target.
func (fs *FileSystemProxy) Rename(source, target string) error {
	srcURI := fs.pathToURI(source)
	tgtURI := fs.pathToURI(target)
	_, err := fs.channel.Call("rename", []interface{}{srcURI, tgtURI, FileOverwriteOptions{Overwrite: false}})
	if err != nil {
		return fmt.Errorf("rename %s -> %s: %w", source, target, err)
	}
	return nil
}

// Delete removes a file or directory.
func (fs *FileSystemProxy) Delete(path string, opts FileDeleteOptions) error {
	uri := fs.pathToURI(path)
	_, err := fs.channel.Call("delete", []interface{}{uri, opts})
	if err != nil {
		return fmt.Errorf("delete %s: %w", path, err)
	}
	return nil
}

// Mkdir creates a directory at the given path.
func (fs *FileSystemProxy) Mkdir(path string) error {
	uri := fs.pathToURI(path)
	_, err := fs.channel.Call("mkdir", []interface{}{uri})
	if err != nil {
		return fmt.Errorf("mkdir %s: %w", path, err)
	}
	return nil
}

// Watch subscribes to file change events for the given path.
// Returns a channel of raw change events and a dispose function.
// The sessionID parameter identifies this watch session.
func (fs *FileSystemProxy) Watch(sessionID string, reqID int, path string, opts WatchOptions) (<-chan interface{}, func(), error) {
	uri := fs.pathToURI(path)
	return fs.channel.Listen("fileChange", []interface{}{sessionID, reqID, uri, opts})
}

// parseFileStat converts a raw IPC response into a FileStat.
func parseFileStat(v interface{}) (*FileStat, error) {
	m, ok := v.(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("expected map for stat, got %T", v)
	}
	stat := &FileStat{}
	if t, err := toInt(m["type"]); err == nil {
		stat.Type = FileType(t)
	}
	if mt, ok := m["mtime"].(float64); ok {
		stat.Mtime = int64(mt)
	}
	if ct, ok := m["ctime"].(float64); ok {
		stat.Ctime = int64(ct)
	}
	if sz, ok := m["size"].(float64); ok {
		stat.Size = int64(sz)
	}
	if p, err := toInt(m["permissions"]); err == nil {
		stat.Permissions = p
	}
	return stat, nil
}

// parseDirEntries converts a raw IPC response into a slice of DirEntry.
// The server returns an array of [name, type] tuples.
func parseDirEntries(v interface{}) ([]DirEntry, error) {
	arr, ok := v.([]interface{})
	if !ok {
		return nil, fmt.Errorf("expected array for readdir, got %T", v)
	}
	entries := make([]DirEntry, 0, len(arr))
	for _, item := range arr {
		tuple, ok := item.([]interface{})
		if !ok || len(tuple) < 2 {
			continue
		}
		name, _ := tuple[0].(string)
		ft, _ := toInt(tuple[1])
		entries = append(entries, DirEntry{
			Name: name,
			Type: FileType(ft),
		})
	}
	return entries, nil
}
