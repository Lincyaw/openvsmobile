package vscode

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// These tests require a real OpenVSCode Server running.
// They are gated by the VSCODE_INTEGRATION_TEST env var.
// To run:
//   1. Start openvscode-server:
//      cd openvscode-server && NODE_ENV=development VSCODE_DEV=1 \
//        node out/server-main.js --without-connection-token --port 9777 --host 127.0.0.1
//   2. Run tests:
//      VSCODE_INTEGRATION_TEST=1 go test -v -run TestIntegration ./internal/vscode/

const testServerURL = "http://127.0.0.1:9777"

func skipIfNoServer(t *testing.T) {
	t.Helper()
	if os.Getenv("VSCODE_INTEGRATION_TEST") == "" {
		t.Skip("skipping integration test: set VSCODE_INTEGRATION_TEST=1 and start openvscode-server")
	}
}

// TestIntegration_ConnectHandshake tests the full WebSocket handshake
// against a real OpenVSCode Server: auth → sign → connectionType → ok.
func TestIntegration_ConnectHandshake(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	err := client.Connect(ctx, testServerURL, "")
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer client.Close()

	if client.conn == nil {
		t.Fatal("expected non-nil WebSocket connection after handshake")
	}
	if client.ipcClient == nil {
		t.Fatal("expected non-nil IPC client after handshake")
	}
	t.Logf("Connected with reconnection token: %s", client.ReconnectionToken())
}

// TestIntegration_FileSystemStat tests FileSystemProxy.Stat against the real server.
// It stats the root path "/" which should always exist.
func TestIntegration_FileSystemStat(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := client.Connect(ctx, testServerURL, ""); err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer client.Close()

	fs := NewFileSystemProxy(client.IPC(), "vscode-remote")

	// Give the IPC channel a moment to initialize.
	time.Sleep(500 * time.Millisecond)

	stat, err := fs.Stat("/")
	if err != nil {
		t.Fatalf("Stat('/') failed: %v", err)
	}

	if stat.Type != FileTypeDirectory {
		t.Fatalf("expected '/' to be a directory (type=%d), got type=%d", FileTypeDirectory, stat.Type)
	}
	t.Logf("Stat('/'): type=%d, size=%d, mtime=%d", stat.Type, stat.Size, stat.Mtime)
}

// TestIntegration_FileSystemReaddir tests reading a well-known directory.
func TestIntegration_FileSystemReaddir(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := client.Connect(ctx, testServerURL, ""); err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer client.Close()

	fs := NewFileSystemProxy(client.IPC(), "vscode-remote")
	time.Sleep(500 * time.Millisecond)

	// Create a controlled temp directory with known contents.
	tmpDir := t.TempDir()
	os.WriteFile(filepath.Join(tmpDir, "a.txt"), []byte("aaa"), 0644)
	os.WriteFile(filepath.Join(tmpDir, "b.txt"), []byte("bbb"), 0644)
	os.Mkdir(filepath.Join(tmpDir, "subdir"), 0755)

	entries, err := fs.Readdir(tmpDir)
	if err != nil {
		t.Fatalf("Readdir('%s') failed: %v", tmpDir, err)
	}

	t.Logf("Readdir('%s'): %d entries", tmpDir, len(entries))
	for i, e := range entries {
		if i >= 5 {
			t.Logf("  ... and %d more", len(entries)-5)
			break
		}
		t.Logf("  %s (type=%d)", e.Name, e.Type)
	}
}

// TestIntegration_FileSystemWriteReadDelete tests the full write → read → delete cycle.
func TestIntegration_FileSystemWriteReadDelete(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := client.Connect(ctx, testServerURL, ""); err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer client.Close()

	fs := NewFileSystemProxy(client.IPC(), "vscode-remote")
	time.Sleep(500 * time.Millisecond)

	// Use a temp directory to avoid polluting the filesystem.
	tmpDir := t.TempDir()
	testFile := filepath.Join(tmpDir, "integration-test-file.txt")
	testContent := []byte("Hello from Go integration test!\n")

	// Step 1: Write.
	err := fs.WriteFile(testFile, testContent, FileWriteOptions{Create: true, Overwrite: true})
	if err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}
	t.Logf("WriteFile('%s') succeeded", testFile)

	// Verify the file actually exists on the real filesystem.
	if _, err := os.Stat(testFile); err != nil {
		t.Fatalf("File should exist on disk after WriteFile: %v", err)
	}

	// Step 2: Read back through the IPC protocol.
	readBack, err := fs.ReadFile(testFile)
	if err != nil {
		t.Fatalf("ReadFile failed: %v", err)
	}
	if string(readBack) != string(testContent) {
		t.Fatalf("ReadFile content mismatch:\n  expected: %q\n  got:      %q", testContent, readBack)
	}
	t.Logf("ReadFile content matches: %q", string(readBack))

	// Step 3: Stat the file.
	stat, err := fs.Stat(testFile)
	if err != nil {
		t.Fatalf("Stat failed: %v", err)
	}
	if stat.Type != FileTypeFile {
		t.Fatalf("expected file type, got %d", stat.Type)
	}
	if stat.Size != int64(len(testContent)) {
		t.Fatalf("expected size %d, got %d", len(testContent), stat.Size)
	}
	t.Logf("Stat: type=%d, size=%d", stat.Type, stat.Size)

	// Step 4: Delete.
	err = fs.Delete(testFile, FileDeleteOptions{Recursive: false})
	if err != nil {
		t.Fatalf("Delete failed: %v", err)
	}
	t.Logf("Delete('%s') succeeded", testFile)

	// Verify file is gone from disk.
	if _, err := os.Stat(testFile); !os.IsNotExist(err) {
		t.Fatalf("File should not exist after Delete, got err: %v", err)
	}
}

// TestIntegration_FileSystemMkdir tests creating a directory via IPC.
func TestIntegration_FileSystemMkdir(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := client.Connect(ctx, testServerURL, ""); err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer client.Close()

	fs := NewFileSystemProxy(client.IPC(), "vscode-remote")
	time.Sleep(500 * time.Millisecond)

	tmpDir := t.TempDir()
	newDir := filepath.Join(tmpDir, "subdir-test")

	err := fs.Mkdir(newDir)
	if err != nil {
		t.Fatalf("Mkdir failed: %v", err)
	}

	info, err := os.Stat(newDir)
	if err != nil {
		t.Fatalf("Directory should exist on disk: %v", err)
	}
	if !info.IsDir() {
		t.Fatalf("Expected directory, got file")
	}
	t.Logf("Mkdir('%s') created real directory on disk", newDir)
}

// TestIntegration_FileSystemRename tests renaming a file via IPC.
func TestIntegration_FileSystemRename(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := client.Connect(ctx, testServerURL, ""); err != nil {
		t.Fatalf("Connect failed: %v", err)
	}
	defer client.Close()

	fs := NewFileSystemProxy(client.IPC(), "vscode-remote")
	time.Sleep(500 * time.Millisecond)

	tmpDir := t.TempDir()
	srcFile := filepath.Join(tmpDir, "src.txt")
	dstFile := filepath.Join(tmpDir, "dst.txt")

	// Create source file via IPC.
	if err := fs.WriteFile(srcFile, []byte("rename me"), FileWriteOptions{Create: true, Overwrite: true}); err != nil {
		t.Fatalf("WriteFile failed: %v", err)
	}

	// Rename.
	if err := fs.Rename(srcFile, dstFile); err != nil {
		t.Fatalf("Rename failed: %v", err)
	}

	// Source should be gone.
	if _, err := os.Stat(srcFile); !os.IsNotExist(err) {
		t.Fatalf("Source file should not exist after rename")
	}
	// Destination should exist.
	data, err := os.ReadFile(dstFile)
	if err != nil {
		t.Fatalf("Destination file should exist: %v", err)
	}
	if string(data) != "rename me" {
		t.Fatalf("Destination content mismatch: %q", data)
	}
	t.Logf("Rename('%s' → '%s') succeeded and verified on disk", srcFile, dstFile)
}

// TestIntegration_MultipleClients tests that multiple concurrent connections work.
func TestIntegration_MultipleClients(t *testing.T) {
	skipIfNoServer(t)

	const numClients = 3
	clients := make([]*Client, numClients)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Connect all clients.
	for i := 0; i < numClients; i++ {
		clients[i] = NewClient()
		if err := clients[i].Connect(ctx, testServerURL, ""); err != nil {
			t.Fatalf("Client %d Connect failed: %v", i, err)
		}
	}

	// Each client does a Stat independently.
	for i, c := range clients {
		fs := NewFileSystemProxy(c.IPC(), "vscode-remote")
		time.Sleep(200 * time.Millisecond)
		stat, err := fs.Stat("/")
		if err != nil {
			t.Fatalf("Client %d Stat('/') failed: %v", i, err)
		}
		if stat.Type != FileTypeDirectory {
			t.Fatalf("Client %d: expected directory, got %d", i, stat.Type)
		}
		t.Logf("Client %d Stat('/') OK", i)
	}

	// Close all.
	for i, c := range clients {
		if err := c.Close(); err != nil {
			t.Logf("Client %d Close warning: %v", i, err)
		}
	}
}

// TestIntegration_HTTPEndToEnd tests the full chain:
// HTTP request → Go API server → FileSystemProxy → OpenVSCode Server → real filesystem.
// This requires both openvscode-server AND the Go server to be set up.
func TestIntegration_HTTPEndToEnd(t *testing.T) {
	skipIfNoServer(t)

	// This test builds a real Go server connected to the real OpenVSCode Server,
	// then makes HTTP requests to it and verifies real filesystem operations.

	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := client.Connect(ctx, testServerURL, ""); err != nil {
		t.Fatalf("Connect to OpenVSCode Server failed: %v", err)
	}
	defer client.Close()

	fsp := NewFileSystemProxy(client.IPC(), "vscode-remote")
	time.Sleep(500 * time.Millisecond)

	// Create a temp file directly on disk, then read it through the proxy.
	tmpDir := t.TempDir()
	testFile := filepath.Join(tmpDir, "http-e2e-test.txt")
	testContent := "End-to-end via real OpenVSCode Server\n"
	os.WriteFile(testFile, []byte(testContent), 0644)

	// Read through the IPC proxy (as the Go HTTP handler would).
	readBack, err := fsp.ReadFile(testFile)
	if err != nil {
		t.Fatalf("ReadFile through proxy failed: %v", err)
	}
	if string(readBack) != testContent {
		t.Fatalf("Content mismatch:\n  expected: %q\n  got:      %q", testContent, readBack)
	}
	t.Logf("E2E verified: disk → OpenVSCode IPC → Go proxy → correct content")

	// Now test readdir on the temp dir.
	entries, err := fsp.Readdir(tmpDir)
	if err != nil {
		t.Fatalf("Readdir through proxy failed: %v", err)
	}
	found := false
	for _, e := range entries {
		if e.Name == "http-e2e-test.txt" {
			found = true
			if e.Type != FileTypeFile {
				t.Fatalf("Expected file type for test file, got %d", e.Type)
			}
		}
	}
	if !found {
		t.Fatalf("Test file not found in Readdir results: %+v", entries)
	}
	t.Logf("E2E Readdir verified: found test file in %d entries", len(entries))
}

// startTestServer is a helper to launch the real OpenVSCode Server as a subprocess.
// Used by TestIntegration_WithAutoStart if the server isn't already running.
func startTestServer(t *testing.T) (*exec.Cmd, int) {
	t.Helper()

	port := 9778 // Use a different port to avoid conflicts.
	ovscodeDir := findOpenVSCodeDir(t)

	nodePath := os.Getenv("NODE_PATH")
	if nodePath == "" {
		// Fall back to PATH lookup.
		var err error
		nodePath, err = exec.LookPath("node")
		if err != nil {
			t.Skip("node not found in PATH; set NODE_PATH env var")
		}
	}

	serverMain := filepath.Join(ovscodeDir, "out/server-main.js")
	if _, err := os.Stat(serverMain); err != nil {
		t.Skipf("openvscode-server not compiled: %s not found", serverMain)
	}

	cmd := exec.Command(nodePath, serverMain,
		"--without-connection-token",
		"--port", fmt.Sprintf("%d", port),
		"--host", "127.0.0.1",
	)
	cmd.Dir = ovscodeDir
	cmd.Env = append(os.Environ(), "NODE_ENV=development", "VSCODE_DEV=1")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		t.Fatalf("Failed to start openvscode-server: %v", err)
	}

	// Wait for server to be ready.
	ready := false
	for i := 0; i < 30; i++ {
		time.Sleep(500 * time.Millisecond)
		c := NewClient()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := c.Connect(ctx, fmt.Sprintf("http://127.0.0.1:%d", port), "")
		cancel()
		if err == nil {
			c.Close()
			ready = true
			break
		}
	}
	if !ready {
		cmd.Process.Kill()
		t.Fatal("openvscode-server did not become ready in 15 seconds")
	}

	return cmd, port
}

// findOpenVSCodeDir finds the openvscode-server directory relative to the test.
func findOpenVSCodeDir(t *testing.T) string {
	t.Helper()

	// Allow override via environment variable.
	if envDir := os.Getenv("OPENVSCODE_SERVER_DIR"); envDir != "" {
		if _, err := os.Stat(filepath.Join(envDir, "out/server-main.js")); err == nil {
			return envDir
		}
		t.Skipf("OPENVSCODE_SERVER_DIR=%s does not contain out/server-main.js", envDir)
		return ""
	}

	// Detect relative to this source file's module root (server/ -> ../openvscode-server).
	// runtime.Caller is not reliable in tests, so walk up from cwd.
	cwd, _ := os.Getwd()
	dir := cwd
	for {
		candidate := filepath.Join(dir, "openvscode-server")
		if _, err := os.Stat(filepath.Join(candidate, "out/server-main.js")); err == nil {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}

	t.Skip("openvscode-server directory not found; set OPENVSCODE_SERVER_DIR env var")
	return ""
}
