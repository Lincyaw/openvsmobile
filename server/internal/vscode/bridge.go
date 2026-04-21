package vscode

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
	"unicode/utf8"
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
	MetadataPath        string
	PollInterval        time.Duration
	Client              *Client
	ServerURL           string
	ConnectionToken     string
	ReconnectMaxRetries int
	ReconnectTimeout    time.Duration
	ReconnectFn         func(context.Context) error
}

// BridgeManager discovers the runtime bridge, tracks readiness, and broadcasts lifecycle events.
type BridgeManager struct {
	metadataPath string
	pollInterval time.Duration
	client       *Client
	reconnectFn  func(context.Context) error
	reconnectTTL time.Duration

	mu                    sync.RWMutex
	ready                 bool
	generation            string
	awaitingNewGeneration string
	disconnectedAt        time.Time
	capabilities          BridgeCapabilitiesDocument
	lastErr               error
	subscribers           map[chan BridgeEvent]struct{}
	reconnecting          bool

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
		client:       opts.Client,
		reconnectTTL: opts.ReconnectTimeout,
		stopCh:       make(chan struct{}),
		subscribers:  make(map[chan BridgeEvent]struct{}),
	}
	if m.reconnectTTL <= 0 {
		m.reconnectTTL = 30 * time.Second
	}
	switch {
	case opts.ReconnectFn != nil:
		m.reconnectFn = opts.ReconnectFn
	case opts.Client != nil && opts.ServerURL != "":
		maxRetries := opts.ReconnectMaxRetries
		if maxRetries <= 0 {
			maxRetries = 5
		}
		m.reconnectFn = func(ctx context.Context) error {
			return opts.Client.ReconnectWithRetry(ctx, opts.ServerURL, opts.ConnectionToken, maxRetries)
		}
	}
	if opts.Client != nil {
		opts.Client.SetDisconnectHandler(func(err error) {
			m.NotifyTransportLost(err)
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

// NotifyTransportLost marks the bridge transport unhealthy and starts recovery
// when reconnect support is configured.
func (m *BridgeManager) NotifyTransportLost(err error) {
	m.handleDisconnect(err)
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

// RequireCapability verifies the bridge is ready and that the named capability is enabled.
func (m *BridgeManager) RequireCapability(name string) error {
	_, err := m.Capability(name)
	return err
}

// Capability returns the named capability entry when the bridge is ready and the
// capability is present+enabled in the metadata document.
func (m *BridgeManager) Capability(name string) (map[string]any, error) {
	caps, err := m.Capabilities()
	if err != nil {
		return nil, err
	}
	entry, ok := lookupCapability(caps.Capabilities, name)
	if !ok {
		return nil, newBridgeError("capability_unavailable", fmt.Sprintf("bridge capability %q is unavailable", name), nil)
	}
	if !capabilityEnabled(entry) {
		return nil, newBridgeError("capability_unavailable", fmt.Sprintf("bridge capability %q is disabled", name), nil)
	}
	return entry, nil
}

// Publish broadcasts an event on the unified bridge event stream.
func (m *BridgeManager) Publish(event BridgeEvent) {
	if m == nil {
		return
	}
	m.broadcast(event)
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
	if err := m.validateMetadata(metadata); err != nil {
		m.markNotReady(err)
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
	m.awaitingNewGeneration = ""
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

func (m *BridgeManager) validateMetadata(metadata BridgeMetadata) error {
	m.mu.RLock()
	reconnecting := m.reconnecting
	awaiting := m.awaitingNewGeneration
	disconnectedAt := m.disconnectedAt
	m.mu.RUnlock()

	if reconnecting {
		return fmt.Errorf("waiting for vscode transport reconnection")
	}
	if awaiting != "" && metadata.Generation == awaiting {
		if !metadata.UpdatedAt.IsZero() && metadata.UpdatedAt.After(disconnectedAt) {
			return nil
		}
		return fmt.Errorf("waiting for new bridge generation after reconnect")
	}
	return nil
}

func (m *BridgeManager) handleDisconnect(err error) {
	select {
	case <-m.stopCh:
		return
	default:
	}

	m.mu.Lock()
	if m.reconnecting {
		m.mu.Unlock()
		return
	}
	m.reconnecting = true
	if m.generation != "" {
		m.awaitingNewGeneration = m.generation
	}
	m.disconnectedAt = time.Now().UTC()
	m.mu.Unlock()

	m.markNotReady(err)
	if m.reconnectFn == nil {
		m.mu.Lock()
		m.reconnecting = false
		m.mu.Unlock()
		return
	}

	go m.reconnectTransport()
}

func (m *BridgeManager) reconnectTransport() {
	ctx, cancel := context.WithTimeout(context.Background(), m.reconnectTTL)
	defer cancel()
	go func() {
		select {
		case <-m.stopCh:
			cancel()
		case <-ctx.Done():
		}
	}()

	err := m.reconnectFn(ctx)
	m.mu.Lock()
	m.reconnecting = false
	m.mu.Unlock()

	if err != nil {
		m.markNotReady(fmt.Errorf("reconnect vscode transport: %w", err))
		return
	}

	// Re-evaluate bridge metadata immediately after transport recovery so the
	// next lifecycle transition does not wait for the periodic poll tick.
	m.poll()
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
		dst[k] = cloneBridgeValue(v)
	}
	return dst
}

func cloneBridgeValue(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		return cloneMap(typed)
	case []any:
		cloned := make([]any, len(typed))
		for i, item := range typed {
			cloned[i] = cloneBridgeValue(item)
		}
		return cloned
	default:
		return typed
	}
}

func lookupCapability(capabilities map[string]interface{}, name string) (map[string]any, bool) {
	if capabilities == nil {
		return nil, false
	}
	if exact, ok := capabilityEntry(capabilities[name]); ok {
		return exact, true
	}
	current := capabilities
	parts := strings.Split(name, ".")
	for _, part := range parts {
		next, ok := current[part]
		if !ok {
			return nil, false
		}
		entry, ok := capabilityEntry(next)
		if !ok {
			return nil, false
		}
		current = entry
	}
	return current, true
}

func capabilityEntry(value any) (map[string]any, bool) {
	switch typed := value.(type) {
	case map[string]any:
		return typed, true
	case bool:
		return map[string]any{"enabled": typed}, true
	default:
		return nil, false
	}
}

func capabilityEnabled(entry map[string]any) bool {
	if entry == nil {
		return false
	}
	enabled, ok := entry["enabled"]
	if !ok {
		return true
	}
	flag, ok := enabled.(bool)
	return ok && flag
}

// DocumentPosition identifies a zero-based line/character location in a text buffer.
type DocumentPosition struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

// DocumentRange identifies the half-open span to replace.
type DocumentRange struct {
	Start DocumentPosition `json:"start"`
	End   DocumentPosition `json:"end"`
}

// DocumentChange describes either a full-buffer replacement or a ranged edit.
type DocumentChange struct {
	Range *DocumentRange `json:"range,omitempty"`
	Text  string         `json:"text"`
}

// DocumentSnapshot exposes the current in-memory document state.
type DocumentSnapshot struct {
	Path    string `json:"path"`
	Version int    `json:"version"`
	Content string `json:"content,omitempty"`
}

// DocumentManagerOptions configures runtime-backed load/save hooks.
type DocumentManagerOptions struct {
	Load func(path string) ([]byte, error)
	Save func(path string, content []byte) error
}

// DocumentStore is the runtime-backed persistence contract for document sync.
type DocumentStore interface {
	ReadFile(path string) ([]byte, error)
	WriteFile(path string, content []byte) error
}

type documentSession struct {
	path    string
	version int
	content string
}

// DocumentManager tracks unsaved document buffers independently from on-disk content.
type DocumentManager struct {
	mu     sync.RWMutex
	loadFn func(path string) ([]byte, error)
	saveFn func(path string, content []byte) error

	sessions map[string]*documentSession
}

// DocumentSyncService exposes the bridge document lifecycle used by the API layer.
type DocumentSyncService struct {
	manager *DocumentManager
}

// NewDocumentSyncService creates a document sync service backed by the provided store.
func NewDocumentSyncService(store DocumentStore) *DocumentSyncService {
	opts := DocumentManagerOptions{}
	if store != nil {
		opts.Load = store.ReadFile
		opts.Save = store.WriteFile
	}
	return &DocumentSyncService{
		manager: NewDocumentManager(opts),
	}
}

// NewDocumentManager creates a document session manager.
func NewDocumentManager(opts DocumentManagerOptions) *DocumentManager {
	return &DocumentManager{
		loadFn:   opts.Load,
		saveFn:   opts.Save,
		sessions: make(map[string]*documentSession),
	}
}

// OpenDocument starts or replaces the tracked session for path.
func (s *DocumentSyncService) OpenDocument(path string, version int, content *string) (DocumentSnapshot, error) {
	if s == nil || s.manager == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	return s.manager.OpenDocument(path, version, content)
}

// ApplyDocumentChanges applies a versioned batch of incremental edits.
func (s *DocumentSyncService) ApplyDocumentChanges(path string, version int, changes []DocumentChange) (DocumentSnapshot, error) {
	if s == nil || s.manager == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	return s.manager.ApplyDocumentChanges(path, version, changes)
}

// SaveDocument persists the latest accepted in-memory buffer.
func (s *DocumentSyncService) SaveDocument(path string) (DocumentSnapshot, error) {
	if s == nil || s.manager == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	return s.manager.SaveDocument(path)
}

// CloseDocument releases the tracked session for path.
func (s *DocumentSyncService) CloseDocument(path string) error {
	if s == nil || s.manager == nil {
		return newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	return s.manager.CloseDocument(path)
}

// DocumentBuffer returns the latest unsaved buffer for an open document.
func (s *DocumentSyncService) DocumentBuffer(path string) (DocumentSnapshot, error) {
	if s == nil || s.manager == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	return s.manager.DocumentBuffer(path)
}

func (m *DocumentManager) OpenDocument(path string, version int, content *string) (DocumentSnapshot, error) {
	if m == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	if strings.TrimSpace(path) == "" {
		return DocumentSnapshot{}, newBridgeError("invalid_request", "document path is required", nil)
	}
	if version < 0 {
		return DocumentSnapshot{}, newBridgeError("invalid_request", "document version must be zero or greater", nil)
	}

	m.mu.Lock()
	if session, ok := m.sessions[path]; ok {
		snapshot, err := reconcileOpenDocument(session, version, content)
		m.mu.Unlock()
		return snapshot, err
	}
	m.mu.Unlock()

	var initial string
	if content != nil {
		initial = *content
	} else if m.loadFn != nil {
		data, err := m.loadFn(path)
		if err != nil {
			return DocumentSnapshot{}, newBridgeError("document_load_failed", "failed to load document content", err)
		}
		initial = string(data)
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if session, ok := m.sessions[path]; ok {
		return reconcileOpenDocument(session, version, content)
	}
	m.sessions[path] = &documentSession{
		path:    path,
		version: version,
		content: initial,
	}
	return DocumentSnapshot{Path: path, Version: version, Content: initial}, nil
}

// ApplyDocumentChanges applies a versioned batch of incremental edits.
func (m *DocumentManager) ApplyDocumentChanges(path string, version int, changes []DocumentChange) (DocumentSnapshot, error) {
	if m == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	if strings.TrimSpace(path) == "" {
		return DocumentSnapshot{}, newBridgeError("invalid_request", "document path is required", nil)
	}
	if len(changes) == 0 {
		return DocumentSnapshot{}, newBridgeError("invalid_request", "at least one document change is required", nil)
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	session, ok := m.sessions[path]
	if !ok {
		return DocumentSnapshot{}, newBridgeError("document_not_open", "document is not open", nil)
	}
	if version <= session.version {
		return DocumentSnapshot{}, newBridgeError("version_conflict", "document version is stale", nil)
	}

	content := session.content
	for _, change := range changes {
		next, err := applyDocumentChange(content, change)
		if err != nil {
			return DocumentSnapshot{}, err
		}
		content = next
	}

	session.version = version
	session.content = content
	return DocumentSnapshot{Path: path, Version: session.version, Content: session.content}, nil
}

// SaveDocument persists the latest accepted in-memory buffer.
func (m *DocumentManager) SaveDocument(path string) (DocumentSnapshot, error) {
	if m == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	if strings.TrimSpace(path) == "" {
		return DocumentSnapshot{}, newBridgeError("invalid_request", "document path is required", nil)
	}

	m.mu.RLock()
	session, ok := m.sessions[path]
	if !ok {
		m.mu.RUnlock()
		return DocumentSnapshot{}, newBridgeError("document_not_open", "document is not open", nil)
	}
	snapshot := DocumentSnapshot{Path: session.path, Version: session.version, Content: session.content}
	saveFn := m.saveFn
	m.mu.RUnlock()

	if saveFn == nil {
		return DocumentSnapshot{}, newBridgeError("save_unavailable", "document save is not configured", nil)
	}
	if err := saveFn(path, []byte(snapshot.Content)); err != nil {
		return DocumentSnapshot{}, newBridgeError("document_save_failed", "failed to save document", err)
	}
	return snapshot, nil
}

// CloseDocument releases the tracked session for path.
func (m *DocumentManager) CloseDocument(path string) error {
	if m == nil {
		return newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	if strings.TrimSpace(path) == "" {
		return newBridgeError("invalid_request", "document path is required", nil)
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.sessions[path]; !ok {
		return newBridgeError("document_not_open", "document is not open", nil)
	}
	delete(m.sessions, path)
	return nil
}

// DocumentBuffer returns the latest unsaved buffer for an open document.
func (m *DocumentManager) DocumentBuffer(path string) (DocumentSnapshot, error) {
	if m == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}

	m.mu.RLock()
	defer m.mu.RUnlock()
	session, ok := m.sessions[path]
	if !ok {
		return DocumentSnapshot{}, newBridgeError("document_not_open", "document is not open", nil)
	}
	return DocumentSnapshot{Path: session.path, Version: session.version, Content: session.content}, nil
}

func applyDocumentChange(content string, change DocumentChange) (string, error) {
	if change.Range == nil {
		return change.Text, nil
	}

	start, end, err := resolveDocumentRange(content, *change.Range)
	if err != nil {
		return "", err
	}
	return content[:start] + change.Text + content[end:], nil
}

func resolveDocumentRange(content string, changeRange DocumentRange) (int, int, error) {
	start, err := documentOffset(content, changeRange.Start)
	if err != nil {
		return 0, 0, err
	}
	end, err := documentOffset(content, changeRange.End)
	if err != nil {
		return 0, 0, err
	}
	if end < start {
		return 0, 0, newBridgeError("invalid_position", "document range end precedes start", nil)
	}
	return start, end, nil
}

func documentOffset(content string, pos DocumentPosition) (int, error) {
	if pos.Line < 0 || pos.Character < 0 {
		return 0, newBridgeError("invalid_position", "document position must be zero or greater", nil)
	}

	offset := 0
	line := 0
	for {
		if line == pos.Line {
			break
		}
		idx := strings.IndexByte(content[offset:], '\n')
		if idx < 0 {
			return 0, newBridgeError("invalid_position", "document position line is out of range", nil)
		}
		offset += idx + 1
		line++
	}

	lineEnd := len(content)
	if idx := strings.IndexByte(content[offset:], '\n'); idx >= 0 {
		lineEnd = offset + idx
	}
	characterOffset, err := documentCharacterOffset(content[offset:lineEnd], pos.Character)
	if err != nil {
		return 0, err
	}
	return offset + characterOffset, nil
}

func reconcileOpenDocument(session *documentSession, version int, content *string) (DocumentSnapshot, error) {
	snapshot := DocumentSnapshot{Path: session.path, Version: session.version, Content: session.content}
	switch {
	case version < session.version:
		return DocumentSnapshot{}, newBridgeError("version_conflict", "document version is stale", nil)
	case version == session.version:
		if content == nil || *content == session.content {
			return snapshot, nil
		}
		return DocumentSnapshot{}, newBridgeError("version_conflict", "document reopen conflicts with tracked buffer", nil)
	case content == nil:
		return DocumentSnapshot{}, newBridgeError("version_conflict", "document reopen requires content for a newer version", nil)
	default:
		session.version = version
		session.content = *content
		return DocumentSnapshot{Path: session.path, Version: session.version, Content: session.content}, nil
	}
}

func documentCharacterOffset(line string, character int) (int, error) {
	offset := 0
	remaining := character
	for offset < len(line) {
		if remaining == 0 {
			return offset, nil
		}
		r, size := utf8.DecodeRuneInString(line[offset:])
		width := utf16.RuneLen(r)
		if width < 0 {
			width = 1
		}
		if remaining < width {
			return 0, newBridgeError("invalid_position", "document position character is out of range", nil)
		}
		offset += size
		remaining -= width
	}
	if remaining != 0 {
		return 0, newBridgeError("invalid_position", "document position character is out of range", nil)
	}
	return offset, nil
}
