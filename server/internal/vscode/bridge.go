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
	State           string                 `json:"state"`
	Generation      string                 `json:"generation"`
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
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), "openvscode-mobile", "bridge-metadata.json")
	}
	return filepath.Join(home, ".config", "openvscode-mobile", "bridge-metadata.json")
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
	caps := cloneCapabilities(m.capabilities)
	m.mu.Unlock()

	if replayCurrent && ready {
		ch <- BridgeEvent{Type: "bridge/ready", Payload: readyPayload(caps)}
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
		State:           metadata.State,
		Generation:      metadata.Generation,
		ProtocolVersion: metadata.ProtocolVersion,
		BridgeVersion:   metadata.BridgeVersion,
		Capabilities:    normalizeBridgeCapabilities(metadata.Capabilities),
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
			Type:    "bridge/ready",
			Payload: readyPayload(caps),
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
	event = normalizeBridgeEvent(event)

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
		State:           doc.State,
		Generation:      doc.Generation,
		ProtocolVersion: doc.ProtocolVersion,
		BridgeVersion:   doc.BridgeVersion,
		Capabilities:    cloneMap(doc.Capabilities),
	}
}

func readyPayload(doc BridgeCapabilitiesDocument) map[string]interface{} {
	return map[string]interface{}{
		"state":           doc.State,
		"generation":      doc.Generation,
		"protocolVersion": doc.ProtocolVersion,
		"bridgeVersion":   doc.BridgeVersion,
		"capabilities":    cloneMap(doc.Capabilities),
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

func normalizeBridgeCapabilities(raw map[string]interface{}) map[string]interface{} {
	return map[string]interface{}{
		"documents": normalizeDocumentsCapability(raw),
		"lsp":       normalizeLSPCapability(raw),
		"git":       normalizeCategoryCapability(raw, "git"),
		"terminal":  normalizeCategoryCapability(raw, "terminal"),
		"workspace": normalizeCategoryCapability(raw, "workspace"),
	}
}

func normalizeDocumentsCapability(raw map[string]interface{}) map[string]interface{} {
	for _, candidate := range []string{"documents", "document", "files", "editor"} {
		if value, ok := raw[candidate]; ok {
			return normalizeCapabilityObject(value)
		}
	}
	return map[string]interface{}{"enabled": false}
}

func normalizeLSPCapability(raw map[string]interface{}) map[string]interface{} {
	lsp := map[string]interface{}{}
	source, _ := capabilityEntry(raw["lsp"])
	for _, feature := range []string{
		"diagnostics",
		"completion",
		"hover",
		"definition",
		"references",
		"signatureHelp",
		"formatting",
		"codeActions",
		"rename",
		"documentSymbols",
	} {
		if value, ok := source[feature]; ok {
			lsp[feature] = normalizeCapabilityObject(value)
			continue
		}
		found := false
		for _, alias := range capabilityPathAliases(feature) {
			if value, ok := raw[alias]; ok {
				lsp[feature] = normalizeCapabilityObject(value)
				found = true
				break
			}
		}
		if !found {
			lsp[feature] = map[string]interface{}{"enabled": false}
		}
	}
	lsp["enabled"] = anyChildCapabilityEnabled(lsp)
	return lsp
}

func normalizeCategoryCapability(raw map[string]interface{}, name string) map[string]interface{} {
	if value, ok := raw[name]; ok {
		return normalizeCapabilityObject(value)
	}
	return map[string]interface{}{"enabled": false}
}

func normalizeCapabilityObject(value any) map[string]interface{} {
	entry, ok := capabilityEntry(value)
	if !ok {
		return map[string]interface{}{"enabled": false}
	}
	normalized := cloneMap(entry)
	for key, child := range entry {
		if key == "enabled" || key == "reason" {
			continue
		}
		switch child.(type) {
		case map[string]any:
			normalized[key] = normalizeCapabilityObject(child)
		}
	}
	if _, ok := normalized["enabled"]; !ok {
		normalized["enabled"] = anyChildCapabilityEnabled(normalized)
	}
	return normalized
}

func anyChildCapabilityEnabled(entry map[string]interface{}) bool {
	for key, value := range entry {
		if key == "enabled" || key == "reason" {
			continue
		}
		child, ok := capabilityEntry(value)
		if !ok {
			continue
		}
		if capabilityEnabled(child) {
			return true
		}
	}
	return false
}

func normalizeBridgeEvent(event BridgeEvent) BridgeEvent {
	switch event.Type {
	case "document/diagnosticsChanged", "bridge/editor/diagnosticsChanged", "bridge/diagnosticsChanged":
		event.Type = "document/diagnosticsChanged"
		event.Payload = normalizeDiagnosticsEventPayload(event.Payload)
	case "git/repositoryChanged", "bridge/git/repositoryChanged":
		event.Type = "git/repositoryChanged"
		event.Payload = normalizeRepositoryEventPayload(event.Payload)
	}
	return event
}

func normalizeDiagnosticsEventPayload(payload any) any {
	doc, ok := toObjectMap(payload)
	if !ok {
		return payload
	}
	file := firstNonEmpty(
		stringValue(doc["file"]),
		stringValue(doc["path"]),
		stringValue(doc["filePath"]),
	)
	if file != "" {
		doc["file"] = file
		if _, ok := doc["path"]; !ok {
			doc["path"] = file
		}
	}
	return doc
}

func normalizeRepositoryEventPayload(payload any) any {
	doc, ok := toObjectMap(payload)
	if !ok {
		return payload
	}
	if repositoryRaw, ok := doc["repository"]; ok {
		repository, repoOK := toObjectMap(repositoryRaw)
		if !repoOK {
			return payload
		}
		if path := firstNonEmpty(stringValue(repository["path"]), stringValue(doc["path"])); path != "" {
			repository["path"] = path
		}
		return repository
	}
	return doc
}

func stringValue(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	return ""
}

func lookupCapability(capabilities map[string]interface{}, name string) (map[string]any, bool) {
	if capabilities == nil {
		return nil, false
	}
	for _, candidate := range capabilityPathAliases(name) {
		if exact, ok := capabilityEntry(capabilities[candidate]); ok {
			return exact, true
		}
		current := capabilities
		matched := true
		for _, part := range strings.Split(candidate, ".") {
			next, ok := current[part]
			if !ok {
				matched = false
				break
			}
			entry, ok := capabilityEntry(next)
			if !ok {
				matched = false
				break
			}
			current = entry
		}
		if matched {
			return current, true
		}
	}
	return nil, false
}

func capabilityPathAliases(name string) []string {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return nil
	}
	aliases := []string{trimmed}
	switch trimmed {
	case "documents", "document", "files", "editor":
		aliases = append(aliases, "documents")
	case "diagnostics":
		aliases = append(aliases, "lsp.diagnostics")
	case "completion":
		aliases = append(aliases, "lsp.completion")
	case "hover":
		aliases = append(aliases, "lsp.hover")
	case "definition":
		aliases = append(aliases, "lsp.definition")
	case "references":
		aliases = append(aliases, "lsp.references")
	case "signatureHelp", "signature_help":
		aliases = append(aliases, "lsp.signatureHelp")
	case "formatting":
		aliases = append(aliases, "lsp.formatting")
	case "codeActions", "codeAction":
		aliases = append(aliases, "lsp.codeActions")
	case "rename":
		aliases = append(aliases, "lsp.rename")
	case "documentSymbols", "documentSymbol":
		aliases = append(aliases, "lsp.documentSymbols")
	case "git":
		aliases = append(aliases, "git")
	case "terminal":
		aliases = append(aliases, "terminal")
	case "workspace":
		aliases = append(aliases, "workspace")
	}
	if strings.HasPrefix(trimmed, "lsp.") {
		aliases = append(aliases, strings.TrimPrefix(trimmed, "lsp."))
	}
	return dedupeStrings(aliases)
}

func dedupeStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	out := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
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

const documentsChannelName = "openvsmobile/documents"

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
	runtime *runtimeDocumentSyncClient
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

// NewRuntimeDocumentSyncService creates a bridge-backed document sync service
// that keeps document state inside the OpenVSCode runtime process.
func NewRuntimeDocumentSyncService(client *Client, bridge *BridgeManager, fallbackStore DocumentStore) *DocumentSyncService {
	if client == nil {
		return NewDocumentSyncService(fallbackStore)
	}
	return &DocumentSyncService{
		runtime: newRuntimeDocumentSyncClient(client, bridge),
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
	if s != nil && s.runtime != nil {
		return s.runtime.OpenDocument(path, version, content)
	}
	if s == nil || s.manager == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	return s.manager.OpenDocument(path, version, content)
}

// ApplyDocumentChanges applies a versioned batch of incremental edits.
func (s *DocumentSyncService) ApplyDocumentChanges(path string, version int, changes []DocumentChange) (DocumentSnapshot, error) {
	if s != nil && s.runtime != nil {
		return s.runtime.ApplyDocumentChanges(path, version, changes)
	}
	if s == nil || s.manager == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	return s.manager.ApplyDocumentChanges(path, version, changes)
}

// SaveDocument persists the latest accepted in-memory buffer.
func (s *DocumentSyncService) SaveDocument(path string) (DocumentSnapshot, error) {
	if s != nil && s.runtime != nil {
		return s.runtime.SaveDocument(path)
	}
	if s == nil || s.manager == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	return s.manager.SaveDocument(path)
}

// CloseDocument releases the tracked session for path.
func (s *DocumentSyncService) CloseDocument(path string) error {
	if s != nil && s.runtime != nil {
		return s.runtime.CloseDocument(path)
	}
	if s == nil || s.manager == nil {
		return newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	return s.manager.CloseDocument(path)
}

// DocumentBuffer returns the latest unsaved buffer for an open document.
func (s *DocumentSyncService) DocumentBuffer(path string) (DocumentSnapshot, error) {
	if s != nil && s.runtime != nil {
		return s.runtime.DocumentBuffer(path)
	}
	if s == nil || s.manager == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	return s.manager.DocumentBuffer(path)
}

type runtimeDocumentSyncClient struct {
	client      *Client
	bridge      *BridgeManager
	channelName string
}

type runtimeDocumentResponse struct {
	OK       bool                  `json:"ok"`
	Snapshot *DocumentSnapshot     `json:"snapshot,omitempty"`
	Error    *runtimeDocumentError `json:"error,omitempty"`
	Path     string                `json:"path,omitempty"`
	Closed   bool                  `json:"closed,omitempty"`
}

type runtimeDocumentError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func newRuntimeDocumentSyncClient(client *Client, bridge *BridgeManager) *runtimeDocumentSyncClient {
	return &runtimeDocumentSyncClient{
		client:      client,
		bridge:      bridge,
		channelName: documentsChannelName,
	}
}

func (c *runtimeDocumentSyncClient) OpenDocument(path string, version int, content *string) (DocumentSnapshot, error) {
	payload := map[string]any{
		"path":    path,
		"version": version,
	}
	if content != nil {
		payload["content"] = *content
	}
	return c.callSnapshot("open", payload)
}

func (c *runtimeDocumentSyncClient) ApplyDocumentChanges(path string, version int, changes []DocumentChange) (DocumentSnapshot, error) {
	return c.callSnapshot("change", map[string]any{
		"path":    path,
		"version": version,
		"changes": changes,
	})
}

func (c *runtimeDocumentSyncClient) SaveDocument(path string) (DocumentSnapshot, error) {
	return c.callSnapshot("save", map[string]any{"path": path})
}

func (c *runtimeDocumentSyncClient) CloseDocument(path string) error {
	response, err := c.call("close", map[string]any{"path": path})
	if err != nil {
		return err
	}
	if !response.OK {
		return c.envelopeError(response, "runtime document close failed")
	}
	return nil
}

func (c *runtimeDocumentSyncClient) DocumentBuffer(path string) (DocumentSnapshot, error) {
	return c.callSnapshot("snapshot", map[string]any{"path": path})
}

func (c *runtimeDocumentSyncClient) callSnapshot(command string, payload map[string]any) (DocumentSnapshot, error) {
	response, err := c.call(command, payload)
	if err != nil {
		return DocumentSnapshot{}, err
	}
	if !response.OK {
		return DocumentSnapshot{}, c.envelopeError(response, fmt.Sprintf("runtime document %s failed", command))
	}
	if response.Snapshot == nil {
		return DocumentSnapshot{}, newBridgeError("document_response_invalid", "runtime document response did not include a snapshot", nil)
	}
	return *response.Snapshot, nil
}

func (c *runtimeDocumentSyncClient) call(command string, payload map[string]any) (runtimeDocumentResponse, error) {
	channel, err := c.ipcChannel()
	if err != nil {
		return runtimeDocumentResponse{}, err
	}
	raw, err := channel.Call(command, payload)
	if err != nil {
		return runtimeDocumentResponse{}, newBridgeError("document_sync_failed", fmt.Sprintf("runtime document %s request failed", command), err)
	}
	var response runtimeDocumentResponse
	if err := decodeJSON(raw, &response); err != nil {
		return runtimeDocumentResponse{}, newBridgeError("document_response_invalid", "failed to decode runtime document response", err)
	}
	return response, nil
}

func (c *runtimeDocumentSyncClient) ipcChannel() (*IPCChannel, error) {
	if c == nil || c.client == nil || c.client.IPC() == nil {
		return nil, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	if c.bridge != nil {
		enabled, err := c.bridge.CapabilityEnabled("documents", "document")
		if err != nil {
			return nil, err
		}
		if !enabled {
			return nil, newBridgeError("capability_unavailable", "bridge capability documents is unavailable", nil)
		}
	}
	return c.client.IPC().GetChannel(c.channelName), nil
}

func (c *runtimeDocumentSyncClient) envelopeError(response runtimeDocumentResponse, fallbackMessage string) error {
	if response.Error != nil {
		return newBridgeError(response.Error.Code, response.Error.Message, nil)
	}
	return newBridgeError("document_sync_failed", fallbackMessage, nil)
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
