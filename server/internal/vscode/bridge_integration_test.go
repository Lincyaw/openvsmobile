package vscode

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type bridgeLifecycleEvent struct {
	Type    string                 `json:"type"`
	Payload map[string]interface{} `json:"payload"`
}

func skipIfBridgeIntegrationPrereqsMissing(t *testing.T) {
	t.Helper()
	if os.Getenv("VSCODE_INTEGRATION_TEST") == "" {
		t.Skip("skipping bridge integration test: set VSCODE_INTEGRATION_TEST=1, bootstrap openvscode-server from repo root, and start the OpenVSCode test server before rerunning")
	}
}

func findGoBinary(t *testing.T) string {
	t.Helper()
	candidates := []string{
		os.Getenv("GO_BINARY"),
		filepath.Join(os.Getenv("HOME"), "go-sdk", "go", "bin", "go"),
		filepath.Join(os.Getenv("HOME"), ".local", "go", "bin", "go"),
	}
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	if path, err := exec.LookPath("go"); err == nil {
		return path
	}
	t.Skip("go binary not found; set GO_BINARY or add go to PATH")
	return ""
}

func findServerModuleDir(t *testing.T) string {
	t.Helper()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	dir := cwd
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatal("server module root not found")
	return ""
}

func freeTCPPort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for free port: %v", err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func startBridgeAPIServer(t *testing.T, vscodeURL string) (*exec.Cmd, string) {
	t.Helper()
	goBin := findGoBinary(t)
	serverDir := findServerModuleDir(t)
	port := freeTCPPort(t)

	cmd := exec.Command(goBin,
		"run", "./cmd/server",
		"--port", strconv.Itoa(port),
		"--vscode-url", vscodeURL,
		"--work-dir", t.TempDir(),
	)
	cmd.Dir = serverDir
	cmd.Env = os.Environ()
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		t.Fatalf("start bridge API server: %v", err)
	}
	t.Cleanup(func() { stopProcess(cmd) })

	baseURL := fmt.Sprintf("http://127.0.0.1:%d", port)
	waitForHTTPStatus(t, baseURL+"/api/health", http.StatusOK, 20*time.Second)
	return cmd, baseURL
}

func stopProcess(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Kill()
	_, _ = cmd.Process.Wait()
}

func waitForHTTPStatus(t *testing.T, url string, want int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == want {
				return
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s to return %d", url, want)
}

func waitForBridgeCapabilities(t *testing.T, baseURL string, timeout time.Duration) (bool, BridgeCapabilitiesDocument) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	sawNotReady := false
	for time.Now().Before(deadline) {
		resp, err := http.Get(baseURL + "/bridge/capabilities")
		if err == nil {
			if resp.StatusCode == http.StatusOK {
				defer resp.Body.Close()
				var body BridgeCapabilitiesDocument
				if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
					t.Fatalf("decode capabilities: %v", err)
				}
				return sawNotReady, body
			}
			var errBody struct {
				Code string `json:"code"`
			}
			_ = json.NewDecoder(resp.Body).Decode(&errBody)
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusServiceUnavailable && errBody.Code == "bridge_not_ready" {
				sawNotReady = true
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for bridge capabilities at %s", baseURL)
	return false, BridgeCapabilitiesDocument{}
}

func waitForBridgeNotReady(t *testing.T, baseURL string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(baseURL + "/bridge/capabilities")
		if err == nil {
			var errBody struct {
				Code string `json:"code"`
			}
			_ = json.NewDecoder(resp.Body).Decode(&errBody)
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusServiceUnavailable && errBody.Code == "bridge_not_ready" {
				return
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s/bridge/capabilities to return bridge_not_ready", baseURL)
}

func waitForFileRead(t *testing.T, baseURL, path, want string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(baseURL + "/api/files" + path)
		if err == nil {
			body, readErr := io.ReadAll(resp.Body)
			_ = resp.Body.Close()
			if readErr == nil && resp.StatusCode == http.StatusOK && string(body) == want {
				return
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for file read via bridge-backed API: %s", path)
}

func dialBridgeEvents(t *testing.T, baseURL string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(baseURL, "http") + "/bridge/ws/events"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial bridge events websocket: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func waitForBridgeEventSequence(t *testing.T, conn *websocket.Conn, timeout time.Duration, sequence ...string) []bridgeLifecycleEvent {
	t.Helper()
	deadline := time.Now().Add(timeout)
	matched := make([]bridgeLifecycleEvent, 0, len(sequence))
	index := 0
	for index < len(sequence) && time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		var event bridgeLifecycleEvent
		if err := conn.ReadJSON(&event); err != nil {
			continue
		}
		if event.Type == sequence[index] {
			matched = append(matched, event)
			index++
		}
	}
	if index != len(sequence) {
		t.Fatalf("timed out waiting for bridge event sequence %v, matched %d events", sequence, index)
	}
	return matched
}

func TestIntegration_BridgeLifecycle_EndToEnd(t *testing.T) {
	skipIfBridgeIntegrationPrereqsMissing(t)

	metadataPath := filepath.Join(t.TempDir(), "bridge-metadata.json")
	t.Setenv("OPENVSCODE_MOBILE_BRIDGE_METADATA_PATH", metadataPath)

	openVSCodeCmd, vscodePort := startTestServer(t)
	defer stopProcess(openVSCodeCmd)

	_, baseURL := startBridgeAPIServer(t, fmt.Sprintf("http://127.0.0.1:%d", vscodePort))
	conn := dialBridgeEvents(t, baseURL)
	testFile := filepath.Join(t.TempDir(), "bridge-reconnect.txt")
	testContent := "bridge reconnect transport ok\n"
	if err := os.WriteFile(testFile, []byte(testContent), 0o644); err != nil {
		t.Fatalf("write test file: %v", err)
	}

	sawNotReady, capabilities := waitForBridgeCapabilities(t, baseURL, 20*time.Second)
	if !sawNotReady {
		t.Fatal("expected to observe bridge_not_ready before the bridge became ready")
	}
	if capabilities.ProtocolVersion == "" {
		t.Fatal("expected protocolVersion in bridge capabilities response")
	}

	readyEvents := waitForBridgeEventSequence(t, conn, 20*time.Second, "bridge/ready")
	if readyEvents[0].Payload == nil {
		t.Fatalf("expected ready event payload, got %+v", readyEvents[0])
	}
	waitForFileRead(t, baseURL, testFile, testContent, 20*time.Second)

	stopProcess(openVSCodeCmd)
	waitForBridgeNotReady(t, baseURL, 20*time.Second)
	openVSCodeCmd, restartedPort := startTestServer(t)
	defer stopProcess(openVSCodeCmd)
	if restartedPort != vscodePort {
		t.Fatalf("restart port = %d, want %d", restartedPort, vscodePort)
	}

	events := waitForBridgeEventSequence(t, conn, 30*time.Second, "bridge/restarted", "bridge/ready")
	if events[0].Payload == nil || events[1].Payload == nil {
		t.Fatalf("expected restarted/ready events to include payloads: %+v", events)
	}

	sawNotReady, recoveredCaps := waitForBridgeCapabilities(t, baseURL, 20*time.Second)
	if !sawNotReady {
		t.Fatal("expected bridge_not_ready while reconnecting after the OpenVSCode restart")
	}
	if recoveredCaps.ProtocolVersion == "" {
		t.Fatal("expected protocolVersion in recovered bridge capabilities response")
	}
	waitForFileRead(t, baseURL, testFile, testContent, 20*time.Second)
}
