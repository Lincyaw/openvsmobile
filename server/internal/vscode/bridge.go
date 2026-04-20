package vscode

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	defaultBridgeProtocolVersion = "2026-04-20"
	defaultBridgePollInterval    = 1 * time.Second
	bridgeStateReady             = "ready"
)

// BridgeCapabilitiesDocument is the RFC-shaped capabilities document exposed to clients.
type BridgeCapabilitiesDocument struct {
	ProtocolVersion string                 `json:"protocolVersion"`
	BridgeVersion   string                 `json:"bridgeVersion,omitempty"`
	Capabilities    map[string]interface{} `json:"capabilities"`
}

// BridgeMetadata is the on-disk discovery contract written by the VS Code bridge extension.
type BridgeMetadata struct {
	ProtocolVersion string                 `json:"protocolVersion"`
	Generation      string                 `json:"generation"`
	State           string                 `json:"state"`
	Capabilities    map[string]interface{} `json:"capabilities"`
	BridgeVersion   string                 `json:"bridgeVersion,omitempty"`
	UpdatedAt       time.Time              `json:"updatedAt,omitempty"`
}

// BridgeEvent is the stable event envelope broadcast to API/WebSocket consumers.
type BridgeEvent struct {
	Type    string      `json:"type"`
	Payload interface{} `json:"payload"`
}

// BridgeError provides structured bridge-specific API errors.
type BridgeError struct {
	Code    string
	Message string
	Cause   error
}

func (e *BridgeError) Error() string {
	if e == nil {
		return ""
	}
	if e.Cause == nil {
		return e.Message
	}
	return fmt.Sprintf("%s: %v", e.Message, e.Cause)
}

func (e *BridgeError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Cause
}

func newBridgeError(code, message string, cause error) *BridgeError {
	return &BridgeError{Code: code, Message: message, Cause: cause}
}

// BridgeManagerOptions controls bridge lifecycle discovery.
type BridgeManagerOptions struct {
	MetadataPath string
	PollInterval time.Duration
	Client       *Client
}

// BridgeManager discovers the runtime bridge, tracks readiness, and broadcasts lifecycle events.
type BridgeManager struct {
	metadataPath string
	pollInterval time.Duration

	mu           sync.RWMutex
	ready        bool
	generation   string
	capabilities BridgeCapabilitiesDocument
	lastErr      error
	subscribers  map[chan BridgeEvent]struct{}

	closeOnce sync.Once
	stopCh    chan struct{}
}

// NewBridgeManager creates a bridge lifecycle manager.
func NewBridgeManager(opts BridgeManagerOptions) *BridgeManager {
	metadataPath := opts.MetadataPath
	if metadataPath == "" {
		metadataPath = DefaultBridgeMetadataPath()
	}
	pollInterval := opts.PollInterval
	if pollInterval <= 0 {
		pollInterval = defaultBridgePollInterval
	}

	m := &BridgeManager{
		metadataPath: metadataPath,
		pollInterval: pollInterval,
		stopCh:       make(chan struct{}),
		subscribers:  make(map[chan BridgeEvent]struct{}),
	}
	if opts.Client != nil {
		opts.Client.SetDisconnectHandler(func(err error) {
			m.markNotReady(err)
		})
	}
	return m
}

// DefaultBridgeMetadataPath returns the well-known discovery file path shared with the built-in extension.
func DefaultBridgeMetadataPath() string {
	if override := os.Getenv("OPENVSCODE_MOBILE_BRIDGE_METADATA_PATH"); override != "" {
		return override
	}
	return filepath.Join(os.TempDir(), "openvscode-mobile", "bridge-metadata.json")
}

// Start begins the discovery loop and returns immediately.
func (m *BridgeManager) Start(ctx context.Context) {
	go m.run(ctx)
}

func (m *BridgeManager) run(ctx context.Context) {
	m.poll()
	ticker := time.NewTicker(m.pollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-m.stopCh:
			return
		case <-ticker.C:
			m.poll()
		}
	}
}

// Close stops background discovery.
func (m *BridgeManager) Close() {
	m.closeOnce.Do(func() {
		close(m.stopCh)
	})
}

// MetadataPath returns the discovery file path.
func (m *BridgeManager) MetadataPath() string {
	return m.metadataPath
}

// Capabilities returns the current capabilities document when the bridge is ready.
func (m *BridgeManager) Capabilities() (BridgeCapabilitiesDocument, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if !m.ready {
		if m.lastErr != nil {
			return BridgeCapabilitiesDocument{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", m.lastErr)
		}
		return BridgeCapabilitiesDocument{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	return cloneCapabilities(m.capabilities), nil
}

// Subscribe registers for lifecycle events. If replayCurrent is true, the current ready state is replayed immediately.
func (m *BridgeManager) Subscribe(replayCurrent bool) (<-chan BridgeEvent, func()) {
	ch := make(chan BridgeEvent, 8)

	m.mu.Lock()
	m.subscribers[ch] = struct{}{}
	ready := m.ready
	generation := m.generation
	m.mu.Unlock()

	if replayCurrent && ready {
		ch <- BridgeEvent{
			Type: "bridge/ready",
			Payload: map[string]interface{}{
				"generation": generation,
			},
		}
	}

	unsubscribe := func() {
		m.mu.Lock()
		if _, ok := m.subscribers[ch]; ok {
			delete(m.subscribers, ch)
			close(ch)
		}
		m.mu.Unlock()
	}
	return ch, unsubscribe
}

func (m *BridgeManager) poll() {
	metadata, err := readBridgeMetadata(m.metadataPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			m.markNotReady(err)
			return
		}
		log.Printf("[Bridge] discovery poll failed: %v", err)
		m.markNotReady(err)
		return
	}
	if metadata.State != bridgeStateReady {
		m.markNotReady(fmt.Errorf("bridge state=%s", metadata.State))
		return
	}
	m.applyMetadata(metadata)
}

func readBridgeMetadata(path string) (BridgeMetadata, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return BridgeMetadata{}, err
	}
	var metadata BridgeMetadata
	if err := json.Unmarshal(data, &metadata); err != nil {
		return BridgeMetadata{}, fmt.Errorf("decode bridge metadata: %w", err)
	}
	if metadata.ProtocolVersion == "" {
		metadata.ProtocolVersion = defaultBridgeProtocolVersion
	}
	if metadata.Generation == "" {
		return BridgeMetadata{}, fmt.Errorf("bridge generation missing")
	}
	if metadata.Capabilities == nil {
		metadata.Capabilities = map[string]interface{}{}
	}
	return metadata, nil
}

func (m *BridgeManager) applyMetadata(metadata BridgeMetadata) {
	caps := BridgeCapabilitiesDocument{
		ProtocolVersion: metadata.ProtocolVersion,
		BridgeVersion:   metadata.BridgeVersion,
		Capabilities:    cloneMap(metadata.Capabilities),
	}

	m.mu.Lock()
	wasReady := m.ready
	previousGeneration := m.generation
	generationChanged := previousGeneration != "" && previousGeneration != metadata.Generation
	m.ready = true
	m.generation = metadata.Generation
	m.capabilities = caps
	m.lastErr = nil
	m.mu.Unlock()

	if generationChanged {
		m.broadcast(BridgeEvent{
			Type: "bridge/restarted",
			Payload: map[string]interface{}{
				"generation":         metadata.Generation,
				"previousGeneration": previousGeneration,
			},
		})
	}
	if !wasReady || generationChanged {
		m.broadcast(BridgeEvent{
			Type: "bridge/ready",
			Payload: map[string]interface{}{
				"generation":      metadata.Generation,
				"protocolVersion": metadata.ProtocolVersion,
				"bridgeVersion":   metadata.BridgeVersion,
				"capabilities":    cloneMap(metadata.Capabilities),
			},
		})
	}
}

func (m *BridgeManager) markNotReady(err error) {
	m.mu.Lock()
	m.ready = false
	m.capabilities = BridgeCapabilitiesDocument{}
	m.lastErr = err
	m.mu.Unlock()
}

func (m *BridgeManager) broadcast(event BridgeEvent) {
	m.mu.RLock()
	deferred := make([]chan BridgeEvent, 0)
	for ch := range m.subscribers {
		select {
		case ch <- event:
		default:
			deferred = append(deferred, ch)
		}
	}
	m.mu.RUnlock()

	for _, ch := range deferred {
		m.mu.Lock()
		if _, ok := m.subscribers[ch]; ok {
			delete(m.subscribers, ch)
			close(ch)
		}
		m.mu.Unlock()
	}
}

func cloneCapabilities(doc BridgeCapabilitiesDocument) BridgeCapabilitiesDocument {
	return BridgeCapabilitiesDocument{
		ProtocolVersion: doc.ProtocolVersion,
		BridgeVersion:   doc.BridgeVersion,
		Capabilities:    cloneMap(doc.Capabilities),
	}
}

func cloneMap(src map[string]interface{}) map[string]interface{} {
	if src == nil {
		return map[string]interface{}{}
	}
	dst := make(map[string]interface{}, len(src))
	for k, v := range src {
		dst[k] = v
	}
	return dst
}
