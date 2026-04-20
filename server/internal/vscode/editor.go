package vscode

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
)

const editorChannelName = "openvsmobile/editor"

// EditorRequest contains the versioned live-document context required for editor intelligence calls.
type EditorRequest struct {
	Path     string            `json:"path"`
	Version  int               `json:"version"`
	Content  string            `json:"content,omitempty"`
	Position *DocumentPosition `json:"position,omitempty"`
	Range    *DocumentRange    `json:"range,omitempty"`
	NewName  string            `json:"newName,omitempty"`
	WorkDir  string            `json:"workDir,omitempty"`
	Context  map[string]any    `json:"context,omitempty"`
	Options  map[string]any    `json:"options,omitempty"`
	Query    string            `json:"query,omitempty"`
}

// EditorDiagnostic mirrors VS Code/LSP diagnostic payloads closely enough for clients to apply directly.
type EditorDiagnostic struct {
	Range    DocumentRange `json:"range"`
	Severity any           `json:"severity,omitempty"`
	Code     any           `json:"code,omitempty"`
	Source   string        `json:"source,omitempty"`
	Message  string        `json:"message"`
	Tags     []int         `json:"tags,omitempty"`
	Related  any           `json:"relatedInformation,omitempty"`
	Data     any           `json:"data,omitempty"`
}

// EditorDiagnosticsDocument is the stable diagnostics response envelope.
type EditorDiagnosticsDocument struct {
	Path        string             `json:"path"`
	Version     int                `json:"version"`
	Diagnostics []EditorDiagnostic `json:"diagnostics"`
}

// EditorDiagnosticReport is the LSP-shaped diagnostics document returned to API clients.
type EditorDiagnosticReport struct {
	URI         string             `json:"uri,omitempty"`
	Path        string             `json:"path,omitempty"`
	Version     *int               `json:"version,omitempty"`
	Diagnostics []EditorDiagnostic `json:"diagnostics"`
}

const (
	LSPDiagnosticSeverityError       = 1
	LSPDiagnosticSeverityWarning     = 2
	LSPDiagnosticSeverityInformation = 3
	LSPDiagnosticSeverityHint        = 4
)

// CompletionListDocument is the stable completion response envelope.
type CompletionListDocument struct {
	IsIncomplete bool             `json:"isIncomplete,omitempty"`
	Items        []CompletionItem `json:"items"`
}

// CompletionItem preserves the replacement-related fields that clients need.
type CompletionItem struct {
	Label               any        `json:"label"`
	Kind                any        `json:"kind,omitempty"`
	Detail              string     `json:"detail,omitempty"`
	Documentation       any        `json:"documentation,omitempty"`
	SortText            string     `json:"sortText,omitempty"`
	FilterText          string     `json:"filterText,omitempty"`
	InsertText          string     `json:"insertText,omitempty"`
	InsertTextFormat    any        `json:"insertTextFormat,omitempty"`
	TextEdit            any        `json:"textEdit,omitempty"`
	AdditionalTextEdits []TextEdit `json:"additionalTextEdits,omitempty"`
	Command             any        `json:"command,omitempty"`
	Data                any        `json:"data,omitempty"`
}

// HoverDocument is the stable hover response envelope.
type HoverDocument struct {
	Contents any            `json:"contents"`
	Range    *DocumentRange `json:"range,omitempty"`
}

// LocationDocument mirrors the LSP location shape.
type LocationDocument struct {
	URI   string        `json:"uri"`
	Range DocumentRange `json:"range"`
}

// TextEdit mirrors the LSP text edit shape.
type TextEdit struct {
	Range   DocumentRange `json:"range"`
	NewText string        `json:"newText"`
}

// WorkspaceEdit mirrors the LSP workspace edit shape.
type WorkspaceEdit struct {
	Changes           map[string][]TextEdit `json:"changes,omitempty"`
	DocumentChanges   any                   `json:"documentChanges,omitempty"`
	ChangeAnnotations any                   `json:"changeAnnotations,omitempty"`
}

// DocumentSymbol mirrors the LSP document symbol tree shape.
type DocumentSymbol struct {
	Name           string           `json:"name"`
	Detail         string           `json:"detail,omitempty"`
	Kind           int              `json:"kind"`
	Tags           []int            `json:"tags,omitempty"`
	Deprecated     bool             `json:"deprecated,omitempty"`
	Range          DocumentRange    `json:"range"`
	SelectionRange DocumentRange    `json:"selectionRange"`
	Children       []DocumentSymbol `json:"children,omitempty"`
}

// EditorService talks to the runtime bridge's editor adapter and republishes diagnostics updates.
type EditorService struct {
	client      *Client
	bridge      *BridgeManager
	documents   *DocumentSyncService
	channelName string

	mu              sync.Mutex
	diagnosticsStop func()
	lifecycleStop   func()
}

// NewEditorService creates a bridge-backed editor intelligence service.
func NewEditorService(client *Client, bridge *BridgeManager, documents *DocumentSyncService) *EditorService {
	return &EditorService{client: client, bridge: bridge, documents: documents, channelName: editorChannelName}
}

// Start binds diagnostics subscriptions to the bridge lifecycle.
func (s *EditorService) Start(ctx context.Context) {
	if s == nil || s.bridge == nil {
		return
	}
	events, unsubscribe := s.bridge.Subscribe(false)
	s.mu.Lock()
	s.lifecycleStop = unsubscribe
	s.mu.Unlock()
	go func() {
		defer unsubscribe()
		defer s.disposeDiagnosticsWatcher()
		for {
			select {
			case <-ctx.Done():
				return
			case event, ok := <-events:
				if !ok {
					return
				}
				switch event.Type {
				case "bridge/ready", "bridge/restarted":
					_ = s.subscribeDiagnostics(ctx)
				}
			}
		}
	}()
}

func (s *EditorService) Close() {
	if s == nil {
		return
	}
	s.mu.Lock()
	stop := s.lifecycleStop
	s.lifecycleStop = nil
	s.mu.Unlock()
	if stop != nil {
		stop()
	}
	s.disposeDiagnosticsWatcher()
}

func (s *EditorService) Diagnostics(req EditorRequest) (EditorDiagnosticsDocument, error) {
	raw, err := s.callWithDocument("diagnostics", "diagnostics", req)
	if err != nil {
		return EditorDiagnosticsDocument{}, err
	}
	doc, err := decodeDiagnosticsDocument(raw, req.Path, req.Version)
	if err != nil {
		return EditorDiagnosticsDocument{}, err
	}
	if s.bridge != nil {
		s.bridge.Publish(BridgeEvent{Type: "bridge/editor/diagnosticsChanged", Payload: doc})
	}
	return doc, nil
}

func (s *EditorService) Completion(req EditorRequest) (CompletionListDocument, error) {
	raw, err := s.callWithDocument("completion", "completion", req)
	if err != nil {
		return CompletionListDocument{}, err
	}
	return decodeCompletionList(raw)
}

func (s *EditorService) Hover(req EditorRequest) (HoverDocument, error) {
	raw, err := s.callWithDocument("hover", "hover", req)
	if err != nil {
		return HoverDocument{}, err
	}
	var doc HoverDocument
	if err := decodeJSON(raw, &doc); err != nil {
		return HoverDocument{}, newBridgeError("editor_response_invalid", "failed to decode hover response", err)
	}
	return doc, nil
}

func (s *EditorService) Definition(req EditorRequest) ([]LocationDocument, error) {
	raw, err := s.callWithDocument("definition", "definition", req)
	if err != nil {
		return nil, err
	}
	return decodeLocationList(raw)
}

func (s *EditorService) References(req EditorRequest) ([]LocationDocument, error) {
	raw, err := s.callWithDocument("references", "references", req)
	if err != nil {
		return nil, err
	}
	return decodeLocationList(raw)
}

func (s *EditorService) SignatureHelp(req EditorRequest) (map[string]any, error) {
	raw, err := s.callWithDocument("signatureHelp", "signatureHelp", req)
	if err != nil {
		return nil, err
	}
	obj, ok := toObjectMap(raw)
	if !ok {
		return nil, newBridgeError("editor_response_invalid", "failed to decode signature help response", nil)
	}
	return obj, nil
}

func (s *EditorService) Formatting(req EditorRequest) ([]TextEdit, error) {
	raw, err := s.callWithDocument("formatting", "formatting", req)
	if err != nil {
		return nil, err
	}
	return decodeTextEdits(raw)
}

func (s *EditorService) CodeActions(req EditorRequest) ([]map[string]any, error) {
	raw, err := s.callWithDocument("codeActions", "codeActions", req)
	if err != nil {
		return nil, err
	}
	var actions []map[string]any
	if err := decodeJSON(raw, &actions); err != nil {
		return nil, newBridgeError("editor_response_invalid", "failed to decode code actions response", err)
	}
	return actions, nil
}

func (s *EditorService) Rename(req EditorRequest) (WorkspaceEdit, error) {
	raw, err := s.callWithDocument("rename", "rename", req)
	if err != nil {
		return WorkspaceEdit{}, err
	}
	return decodeWorkspaceEdit(raw)
}

func (s *EditorService) DocumentSymbols(req EditorRequest) ([]DocumentSymbol, error) {
	raw, err := s.callWithDocument("documentSymbols", "documentSymbols", req)
	if err != nil {
		return nil, err
	}
	var symbols []DocumentSymbol
	if err := decodeJSON(raw, &symbols); err != nil {
		return nil, newBridgeError("editor_response_invalid", "failed to decode document symbols response", err)
	}
	return symbols, nil
}

func (s *EditorService) HasCapability(feature string, aliases ...string) bool {
	if s == nil || s.bridge == nil {
		return false
	}
	enabled, err := s.bridge.CapabilityEnabled(append([]string{feature}, aliases...)...)
	return err == nil && enabled
}

func (s *EditorService) callWithDocument(command, capability string, req EditorRequest) (any, error) {
	snapshot, err := s.resolveDocument(req.Path, req.Version)
	if err != nil {
		return nil, err
	}
	payload := map[string]any{
		"path":    snapshot.Path,
		"version": snapshot.Version,
		"content": snapshot.Content,
	}
	if req.Position != nil {
		payload["position"] = req.Position
	}
	if req.Range != nil {
		payload["range"] = req.Range
	}
	if req.NewName != "" {
		payload["newName"] = req.NewName
	}
	if req.WorkDir != "" {
		payload["workDir"] = req.WorkDir
	}
	if len(req.Context) > 0 {
		payload["context"] = req.Context
	}
	if len(req.Options) > 0 {
		payload["options"] = req.Options
	}
	if req.Query != "" {
		payload["query"] = req.Query
	}
	channel, err := s.ipcChannel(capability)
	if err != nil {
		return nil, err
	}
	response, err := channel.Call(command, payload)
	if err != nil {
		return nil, newBridgeError("editor_request_failed", fmt.Sprintf("editor %s request failed", command), err)
	}
	return response, nil
}

func (s *EditorService) resolveDocument(path string, version int) (DocumentSnapshot, error) {
	if s == nil || s.documents == nil {
		return DocumentSnapshot{}, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	if version < 0 {
		return DocumentSnapshot{}, newBridgeError("invalid_request", "document version must be zero or greater", nil)
	}
	snapshot, err := s.documents.DocumentBuffer(path)
	if err != nil {
		return DocumentSnapshot{}, err
	}
	if snapshot.Version != version {
		return DocumentSnapshot{}, newBridgeError("version_conflict", "document version does not match the tracked buffer", nil)
	}
	return snapshot, nil
}

func (s *EditorService) subscribeDiagnostics(ctx context.Context) error {
	channel, err := s.ipcChannel("diagnostics")
	if err != nil {
		return err
	}
	events, dispose, err := channel.ListenContext(ctx, "diagnosticsChanged", map[string]any{})
	if err != nil {
		return newBridgeError("diagnostics_subscription_failed", "failed to subscribe to bridge diagnostics updates", err)
	}

	s.mu.Lock()
	if old := s.diagnosticsStop; old != nil {
		old()
	}
	s.diagnosticsStop = dispose
	s.mu.Unlock()

	go func(stop func(), eventCh <-chan interface{}) {
		for {
			select {
			case <-ctx.Done():
				stop()
				return
			case raw, ok := <-eventCh:
				if !ok {
					return
				}
				doc, err := decodeDiagnosticsDocument(raw, "", 0)
				if err != nil {
					continue
				}
				if s.bridge != nil {
					s.bridge.Publish(BridgeEvent{Type: "bridge/diagnosticsChanged", Payload: doc})
				}
			}
		}
	}(dispose, events)

	return nil
}

func (s *EditorService) disposeDiagnosticsWatcher() {
	s.mu.Lock()
	stop := s.diagnosticsStop
	s.diagnosticsStop = nil
	s.mu.Unlock()
	if stop != nil {
		stop()
	}
}

func (s *EditorService) ipcChannel(feature string) (*IPCChannel, error) {
	if s.client == nil || s.client.IPC() == nil {
		return nil, newBridgeError("bridge_not_ready", "mobile runtime bridge is not ready", nil)
	}
	if s.bridge != nil {
		enabled, err := s.bridge.CapabilityEnabled(feature, capabilityAlias(feature))
		if err != nil {
			return nil, err
		}
		if !enabled {
			return nil, newBridgeError("capability_unavailable", fmt.Sprintf("bridge capability %s is unavailable", feature), nil)
		}
	}
	return s.client.IPC().GetChannel(s.channelName), nil
}

func capabilityAlias(feature string) string {
	switch feature {
	case "signatureHelp":
		return "signature_help"
	case "codeActions":
		return "codeAction"
	case "documentSymbols":
		return "documentSymbol"
	default:
		return ""
	}
}

func decodeDiagnosticsDocument(raw any, fallbackPath string, fallbackVersion int) (EditorDiagnosticsDocument, error) {
	type diagnosticsAlias struct {
		Path        string             `json:"path"`
		FilePath    string             `json:"filePath"`
		URI         string             `json:"uri"`
		Version     int                `json:"version"`
		Diagnostics []EditorDiagnostic `json:"diagnostics"`
		Items       []EditorDiagnostic `json:"items"`
	}
	var alias diagnosticsAlias
	if err := decodeJSON(raw, &alias); err == nil && (alias.Path != "" || alias.FilePath != "" || alias.URI != "" || alias.Diagnostics != nil || alias.Items != nil) {
		doc := EditorDiagnosticsDocument{
			Path:        firstNonEmpty(alias.Path, alias.FilePath, alias.URI, fallbackPath),
			Version:     alias.Version,
			Diagnostics: alias.Diagnostics,
		}
		if len(doc.Diagnostics) == 0 && len(alias.Items) > 0 {
			doc.Diagnostics = alias.Items
		}
		if doc.Version == 0 {
			doc.Version = fallbackVersion
		}
		return doc, nil
	}
	var list []EditorDiagnostic
	if err := decodeJSON(raw, &list); err == nil {
		return EditorDiagnosticsDocument{Path: fallbackPath, Version: fallbackVersion, Diagnostics: list}, nil
	}
	return EditorDiagnosticsDocument{}, newBridgeError("editor_response_invalid", "failed to decode diagnostics response", nil)
}

func decodeCompletionList(raw any) (CompletionListDocument, error) {
	type completionAlias struct {
		IsIncomplete bool             `json:"isIncomplete"`
		Items        []CompletionItem `json:"items"`
	}
	var alias completionAlias
	if err := decodeJSON(raw, &alias); err == nil && alias.Items != nil {
		return CompletionListDocument{IsIncomplete: alias.IsIncomplete, Items: alias.Items}, nil
	}
	var items []CompletionItem
	if err := decodeJSON(raw, &items); err == nil {
		return CompletionListDocument{Items: items}, nil
	}
	return CompletionListDocument{}, newBridgeError("editor_response_invalid", "failed to decode completion response", nil)
}

func decodeLocationList(raw any) ([]LocationDocument, error) {
	var docs []LocationDocument
	if err := decodeJSON(raw, &docs); err != nil {
		return nil, newBridgeError("editor_response_invalid", "failed to decode location response", err)
	}
	return docs, nil
}

func decodeTextEdits(raw any) ([]TextEdit, error) {
	var edits []TextEdit
	if err := decodeJSON(raw, &edits); err != nil {
		return nil, newBridgeError("editor_response_invalid", "failed to decode text edits response", err)
	}
	return edits, nil
}

func decodeWorkspaceEdit(raw any) (WorkspaceEdit, error) {
	var edit WorkspaceEdit
	if err := decodeJSON(raw, &edit); err != nil {
		return WorkspaceEdit{}, newBridgeError("editor_response_invalid", "failed to decode workspace edit response", err)
	}
	return edit, nil
}

// CapabilityEnabled reports whether any of the named capabilities are enabled in the current bridge metadata.
func (m *BridgeManager) CapabilityEnabled(names ...string) (bool, error) {
	for _, name := range names {
		if name == "" {
			continue
		}
		entry, err := m.Capability(name)
		if err == nil {
			return capabilityEnabled(entry), nil
		}
		var bridgeErr *BridgeError
		if errors.As(err, &bridgeErr) && bridgeErr.Code == "capability_unavailable" {
			continue
		}
		return false, err
	}
	return false, nil
}

func pathToDocumentURI(path string) string {
	if strings.TrimSpace(path) == "" {
		return ""
	}
	slashed := filepath.ToSlash(path)
	if !strings.HasPrefix(slashed, "/") {
		slashed = "/" + slashed
	}
	return "file://" + (&url.URL{Path: slashed}).EscapedPath()
}
