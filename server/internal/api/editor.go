package api

import (
	"errors"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"

	"github.com/Lincyaw/vscode-mobile/server/internal/diagnostics"
	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

type bridgeEditorRequest struct {
	Path     string                   `json:"path"`
	Version  *int                     `json:"version,omitempty"`
	WorkDir  string                   `json:"workDir,omitempty"`
	Position *vscode.DocumentPosition `json:"position,omitempty"`
	Range    *vscode.DocumentRange    `json:"range,omitempty"`
	Context  map[string]any           `json:"context,omitempty"`
	Options  map[string]any           `json:"options,omitempty"`
	NewName  string                   `json:"newName,omitempty"`
	Query    string                   `json:"query,omitempty"`
}

type bridgeEditorRequestRequirements struct {
	Position bool
	Range    bool
	NewName  bool
}

func (s *Server) handleBridgeEditorDiagnostics(w http.ResponseWriter, r *http.Request) {
	if s.editorService == nil {
		writeBridgeError(w, http.StatusNotFound, "capability_unavailable", "editor intelligence bridge is not configured")
		return
	}

	var raw bridgeEditorRequest
	if !decodeBridgeDocumentRequest(w, r, &raw) {
		return
	}
	req, err := sanitizeBridgeEditorRequest(raw, bridgeEditorRequestRequirements{})
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	result, err := s.editorService.Diagnostics(req)
	if err != nil {
		writeEditorBridgeError(w, err)
		return
	}
	version := result.Version
	writeJSON(w, http.StatusOK, diagnosticsDocumentToReport(result, &version))
}

func (s *Server) handleBridgeEditorCompletion(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeEditorRPC(w, r, bridgeEditorRequestRequirements{Position: true}, func(req vscode.EditorRequest) (any, error) {
		return s.editorService.Completion(req)
	})
}

func (s *Server) handleBridgeEditorHover(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeEditorRPC(w, r, bridgeEditorRequestRequirements{Position: true}, func(req vscode.EditorRequest) (any, error) {
		return s.editorService.Hover(req)
	})
}

func (s *Server) handleBridgeEditorDefinition(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeEditorRPC(w, r, bridgeEditorRequestRequirements{Position: true}, func(req vscode.EditorRequest) (any, error) {
		return s.editorService.Definition(req)
	})
}

func (s *Server) handleBridgeEditorReferences(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeEditorRPC(w, r, bridgeEditorRequestRequirements{Position: true}, func(req vscode.EditorRequest) (any, error) {
		return s.editorService.References(req)
	})
}

func (s *Server) handleBridgeEditorSignatureHelp(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeEditorRPC(w, r, bridgeEditorRequestRequirements{Position: true}, func(req vscode.EditorRequest) (any, error) {
		return s.editorService.SignatureHelp(req)
	})
}

func (s *Server) handleBridgeEditorFormatting(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeEditorRPC(w, r, bridgeEditorRequestRequirements{}, func(req vscode.EditorRequest) (any, error) {
		return s.editorService.Formatting(req)
	})
}

func (s *Server) handleBridgeEditorCodeActions(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeEditorRPC(w, r, bridgeEditorRequestRequirements{Range: true}, func(req vscode.EditorRequest) (any, error) {
		return s.editorService.CodeActions(req)
	})
}

func (s *Server) handleBridgeEditorRename(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeEditorRPC(w, r, bridgeEditorRequestRequirements{Position: true, NewName: true}, func(req vscode.EditorRequest) (any, error) {
		return s.editorService.Rename(req)
	})
}

func (s *Server) handleBridgeEditorDocumentSymbols(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeEditorRPC(w, r, bridgeEditorRequestRequirements{}, func(req vscode.EditorRequest) (any, error) {
		return s.editorService.DocumentSymbols(req)
	})
}

func (s *Server) handleBridgeEditorRPC(w http.ResponseWriter, r *http.Request, requirements bridgeEditorRequestRequirements, fn func(vscode.EditorRequest) (any, error)) {
	if s.editorService == nil {
		writeBridgeError(w, http.StatusNotFound, "capability_unavailable", "editor intelligence bridge is not configured")
		return
	}
	var raw bridgeEditorRequest
	if !decodeBridgeDocumentRequest(w, r, &raw) {
		return
	}
	req, err := sanitizeBridgeEditorRequest(raw, requirements)
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	result, err := fn(req)
	if err != nil {
		writeEditorBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func sanitizeBridgeEditorRequest(raw bridgeEditorRequest, requirements bridgeEditorRequestRequirements) (vscode.EditorRequest, error) {
	path, workDir, err := sanitizeEditorPathContext(raw.Path, raw.WorkDir)
	if err != nil {
		return vscode.EditorRequest{}, err
	}
	if raw.Version == nil {
		return vscode.EditorRequest{}, errors.New("version is required")
	}
	if requirements.Position && raw.Position == nil {
		return vscode.EditorRequest{}, errors.New("position is required")
	}
	if requirements.Range && raw.Range == nil {
		return vscode.EditorRequest{}, errors.New("range is required")
	}
	if requirements.NewName && strings.TrimSpace(raw.NewName) == "" {
		return vscode.EditorRequest{}, errors.New("newName is required")
	}
	return vscode.EditorRequest{
		Path:     path,
		Version:  *raw.Version,
		WorkDir:  workDir,
		Position: raw.Position,
		Range:    raw.Range,
		Context:  raw.Context,
		Options:  raw.Options,
		NewName:  raw.NewName,
		Query:    raw.Query,
	}, nil
}

func sanitizeEditorPathContext(rawPath, rawWorkDir string) (string, string, error) {
	path, err := sanitizePath(rawPath, false)
	if err != nil {
		return "", "", err
	}
	workDir := rawWorkDir
	if workDir == "" {
		workDir = filepath.Dir(path)
	}
	workDir, err = sanitizePath(workDir, true)
	if err != nil {
		return "", "", err
	}
	if path != workDir && !strings.HasPrefix(path, workDir+string(filepath.Separator)) {
		return "", "", errors.New("path must be within workDir")
	}
	return path, workDir, nil
}

func writeEditorBridgeError(w http.ResponseWriter, err error) {
	var bridgeErr *vscode.BridgeError
	if errors.As(err, &bridgeErr) {
		status := http.StatusBadGateway
		switch bridgeErr.Code {
		case "invalid_request", "invalid_position":
			status = http.StatusBadRequest
		case "version_conflict":
			status = http.StatusConflict
		case "bridge_not_ready":
			status = http.StatusServiceUnavailable
		case "capability_unavailable":
			status = http.StatusNotImplemented
		case "document_not_open":
			status = http.StatusNotFound
		}
		writeBridgeError(w, status, bridgeErr.Code, bridgeErr.Message)
		return
	}
	writeBridgeError(w, http.StatusInternalServerError, "bridge_error", "bridge editor request failed")
}

func diagnosticsToLSPReport(path string, version *int, entries []diagnostics.Diagnostic) vscode.EditorDiagnosticReport {
	report := vscode.EditorDiagnosticReport{
		URI:         pathToDocumentURI(path),
		Path:        path,
		Version:     version,
		Diagnostics: make([]vscode.EditorDiagnostic, 0, len(entries)),
	}
	for _, entry := range entries {
		report.Diagnostics = append(report.Diagnostics, vscode.EditorDiagnostic{
			Range: vscode.DocumentRange{
				Start: diagnosticsPosition(entry.Line, entry.Column),
				End:   diagnosticsPosition(entry.Line, entry.Column+1),
			},
			Severity: diagnosticsSeverity(entry.Severity),
			Source:   entry.Source,
			Message:  entry.Message,
		})
	}
	return report
}

func diagnosticsDocumentToReport(doc vscode.EditorDiagnosticsDocument, version *int) vscode.EditorDiagnosticReport {
	if version == nil {
		version = &doc.Version
	}
	return vscode.EditorDiagnosticReport{
		URI:         pathToDocumentURI(doc.Path),
		Path:        doc.Path,
		Version:     version,
		Diagnostics: doc.Diagnostics,
	}
}

func diagnosticsPosition(line, column int) vscode.DocumentPosition {
	if line < 1 {
		line = 1
	}
	if column < 1 {
		column = 1
	}
	return vscode.DocumentPosition{Line: line - 1, Character: column - 1}
}

func diagnosticsSeverity(severity string) int {
	switch strings.ToLower(severity) {
	case diagnostics.SeverityError:
		return vscode.LSPDiagnosticSeverityError
	case diagnostics.SeverityWarning:
		return vscode.LSPDiagnosticSeverityWarning
	case diagnostics.SeverityInfo:
		return vscode.LSPDiagnosticSeverityInformation
	default:
		return vscode.LSPDiagnosticSeverityHint
	}
}

func pathToDocumentURI(path string) string {
	if strings.TrimSpace(path) == "" {
		return ""
	}
	return (&url.URL{Scheme: "file", Path: filepath.ToSlash(path)}).String()
}
