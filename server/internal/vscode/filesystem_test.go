package vscode

import (
	"testing"
)

func TestPathToURI(t *testing.T) {
	fs := &FileSystemProxy{
		authority: "test-authority",
	}

	uri := fs.pathToURI("/home/user/project")
	if uri.Scheme != "vscode-remote" {
		t.Errorf("scheme = %s, want vscode-remote", uri.Scheme)
	}
	if uri.Authority != "test-authority" {
		t.Errorf("authority = %s, want test-authority", uri.Authority)
	}
	if uri.Path != "/home/user/project" {
		t.Errorf("path = %s, want /home/user/project", uri.Path)
	}
}

func TestParseFileStat(t *testing.T) {
	raw := map[string]interface{}{
		"type":  float64(1), // FileTypeFile
		"mtime": float64(1700000000000),
		"ctime": float64(1690000000000),
		"size":  float64(4096),
	}

	stat, err := parseFileStat(raw)
	if err != nil {
		t.Fatal(err)
	}
	if stat.Type != FileTypeFile {
		t.Errorf("type = %d, want %d", stat.Type, FileTypeFile)
	}
	if stat.Mtime != 1700000000000 {
		t.Errorf("mtime = %d, want 1700000000000", stat.Mtime)
	}
	if stat.Ctime != 1690000000000 {
		t.Errorf("ctime = %d, want 1690000000000", stat.Ctime)
	}
	if stat.Size != 4096 {
		t.Errorf("size = %d, want 4096", stat.Size)
	}
}

func TestParseFileStatWithIntType(t *testing.T) {
	// When type comes back as an int (from our custom deserializer)
	raw := map[string]interface{}{
		"type":  float64(2), // FileTypeDirectory
		"mtime": float64(0),
		"ctime": float64(0),
		"size":  float64(0),
	}

	stat, err := parseFileStat(raw)
	if err != nil {
		t.Fatal(err)
	}
	if stat.Type != FileTypeDirectory {
		t.Errorf("type = %d, want %d", stat.Type, FileTypeDirectory)
	}
}

func TestParseDirEntries(t *testing.T) {
	// readdir returns [[name, type], ...]
	raw := []interface{}{
		[]interface{}{"file.txt", float64(1)},
		[]interface{}{"subdir", float64(2)},
		[]interface{}{"link", float64(64)},
	}

	entries, err := parseDirEntries(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 {
		t.Fatalf("len = %d, want 3", len(entries))
	}

	expected := []DirEntry{
		{Name: "file.txt", Type: FileTypeFile},
		{Name: "subdir", Type: FileTypeDirectory},
		{Name: "link", Type: FileTypeSymlink},
	}
	for i, e := range expected {
		if entries[i].Name != e.Name {
			t.Errorf("[%d] name = %s, want %s", i, entries[i].Name, e.Name)
		}
		if entries[i].Type != e.Type {
			t.Errorf("[%d] type = %d, want %d", i, entries[i].Type, e.Type)
		}
	}
}

func TestParseDirEntriesEmpty(t *testing.T) {
	entries, err := parseDirEntries([]interface{}{})
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Errorf("len = %d, want 0", len(entries))
	}
}

func TestParseFileStatError(t *testing.T) {
	_, err := parseFileStat("not a map")
	if err == nil {
		t.Error("expected error for non-map input")
	}
}

func TestParseDirEntriesError(t *testing.T) {
	_, err := parseDirEntries("not an array")
	if err == nil {
		t.Error("expected error for non-array input")
	}
}

func TestFileSystemRequestSerialization(t *testing.T) {
	// Verify that the IPC message format for a stat request is correct:
	// header = [RequestType.Promise, id, channelName, commandName]
	// body = [uri]
	uri := UriComponents{
		Scheme:    "vscode-remote",
		Authority: "test",
		Path:      "/test/path",
	}

	header := []interface{}{int(RequestTypePromise), 1, RemoteFileSystemChannelName, "stat"}
	body := []interface{}{uri}

	encoded := EncodeIPCMessage(header, body)

	gotHeader, _, err := DecodeIPCMessage(encoded)
	if err != nil {
		t.Fatal(err)
	}

	hdr, ok := gotHeader.([]interface{})
	if !ok {
		t.Fatalf("expected header array, got %T", gotHeader)
	}

	reqType, err := toInt(hdr[0])
	if err != nil {
		t.Fatal(err)
	}
	if RequestType(reqType) != RequestTypePromise {
		t.Errorf("request type = %d, want %d", reqType, RequestTypePromise)
	}

	channelName, ok := hdr[2].(string)
	if !ok || channelName != RemoteFileSystemChannelName {
		t.Errorf("channel = %v, want %s", hdr[2], RemoteFileSystemChannelName)
	}

	commandName, ok := hdr[3].(string)
	if !ok || commandName != "stat" {
		t.Errorf("command = %v, want stat", hdr[3])
	}
}

func TestWriteFileRequestSerialization(t *testing.T) {
	uri := UriComponents{
		Scheme:    "vscode-remote",
		Authority: "test",
		Path:      "/test/file.txt",
	}
	content := []byte("hello world")
	opts := FileWriteOptions{Create: true, Overwrite: true}

	header := []interface{}{int(RequestTypePromise), 2, RemoteFileSystemChannelName, "writeFile"}
	body := []interface{}{uri, content, opts}

	encoded := EncodeIPCMessage(header, body)
	_, gotBody, err := DecodeIPCMessage(encoded)
	if err != nil {
		t.Fatal(err)
	}

	bodyArr, ok := gotBody.([]interface{})
	if !ok {
		t.Fatalf("expected body array, got %T", gotBody)
	}
	if len(bodyArr) != 3 {
		t.Fatalf("body length = %d, want 3", len(bodyArr))
	}
}
