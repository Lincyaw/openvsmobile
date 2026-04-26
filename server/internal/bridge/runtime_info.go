// Package bridge provides a client for the openvsmobile-bridge VS Code
// extension. The extension publishes its loopback HTTP listen address and a
// bearer token into a JSON file under
// ~/.config/openvscode-mobile/bridge-runtime.json (overridable via
// OPENVSCODE_MOBILE_BRIDGE_INFO_PATH); this package reads that file lazily and
// uses it to forward git/diagnostics/workspace requests into the live VS Code
// extension host.
//
// There is no local-CLI fallback. If the runtime info is missing or the
// extension is unreachable, callers receive a *Error wrapping
// ErrBridgeUnavailable.
package bridge

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// EnvInfoPath is the env var that overrides the runtime-info file location.
const EnvInfoPath = "OPENVSCODE_MOBILE_BRIDGE_INFO_PATH"

// ErrBridgeUnavailable is returned when the bridge runtime info is missing or
// the extension's HTTP server cannot be reached.
var ErrBridgeUnavailable = errors.New("bridge_unavailable")

// RuntimeInfo describes the JSON document the extension writes on startup.
type RuntimeInfo struct {
	Host      string `json:"host"`
	Port      int    `json:"port"`
	Token     string `json:"token"`
	PID       int    `json:"pid"`
	StartedAt string `json:"startedAt"`
	Version   int    `json:"version"`
}

// BaseURL returns the http://host:port prefix used for outbound requests.
func (r RuntimeInfo) BaseURL() string {
	host := r.Host
	if host == "" {
		host = "127.0.0.1"
	}
	return fmt.Sprintf("http://%s:%d", host, r.Port)
}

// runtimeCache memoises the parsed RuntimeInfo so we do not stat/read the JSON
// file on every API call. Callers can invalidate the cache (forcing a reload)
// by calling Invalidate; the Client does this automatically when it sees a
// connection error so a restarted extension reattaches without a reboot.
type runtimeCache struct {
	mu        sync.Mutex
	path      string
	info      *RuntimeInfo
	loadedAt  time.Time
	loadedMod time.Time
	pathOnce  sync.Once
}

func newRuntimeCache(infoPath string) *runtimeCache {
	return &runtimeCache{path: infoPath}
}

func (r *runtimeCache) Path() string {
	r.pathOnce.Do(func() {
		if r.path != "" {
			return
		}
		r.path = ResolveInfoPath()
	})
	return r.path
}

func (r *runtimeCache) Get() (RuntimeInfo, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	target := r.Path()
	stat, err := os.Stat(target)
	if err != nil {
		r.info = nil
		return RuntimeInfo{}, fmt.Errorf("%w: runtime info %s missing: %v", ErrBridgeUnavailable, target, err)
	}
	if r.info != nil && stat.ModTime().Equal(r.loadedMod) {
		return *r.info, nil
	}
	info, err := readRuntimeInfo(target)
	if err != nil {
		r.info = nil
		return RuntimeInfo{}, fmt.Errorf("%w: %v", ErrBridgeUnavailable, err)
	}
	r.info = &info
	r.loadedAt = time.Now()
	r.loadedMod = stat.ModTime()
	return info, nil
}

// Invalidate forces the next Get() call to re-read the runtime-info file. The
// HTTP client calls this whenever a request fails with a connection error so
// that a restarted extension is picked up automatically.
func (r *runtimeCache) Invalidate() {
	r.mu.Lock()
	r.info = nil
	r.loadedMod = time.Time{}
	r.mu.Unlock()
}

func readRuntimeInfo(path string) (RuntimeInfo, error) {
	bytes, err := os.ReadFile(path)
	if err != nil {
		return RuntimeInfo{}, fmt.Errorf("read %s: %w", path, err)
	}
	var info RuntimeInfo
	if err := json.Unmarshal(bytes, &info); err != nil {
		return RuntimeInfo{}, fmt.Errorf("parse %s: %w", path, err)
	}
	if info.Port == 0 {
		return RuntimeInfo{}, fmt.Errorf("runtime info missing port")
	}
	if info.Token == "" {
		return RuntimeInfo{}, fmt.Errorf("runtime info missing token")
	}
	if info.Host == "" {
		info.Host = "127.0.0.1"
	}
	return info, nil
}

// ResolveInfoPath returns the path the bridge runtime info file is expected at.
// Honours the OPENVSCODE_MOBILE_BRIDGE_INFO_PATH env override; otherwise falls
// back to ~/.config/openvscode-mobile/bridge-runtime.json.
func ResolveInfoPath() string {
	if override := os.Getenv(EnvInfoPath); override != "" {
		return override
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return "/.config/openvscode-mobile/bridge-runtime.json"
	}
	return filepath.Join(home, ".config", "openvscode-mobile", "bridge-runtime.json")
}
