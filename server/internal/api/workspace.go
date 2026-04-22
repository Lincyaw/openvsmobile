package api

import (
	"errors"
	"net/http"
	"strings"

	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

type bridgeWorkspaceRequest struct {
	Query   string `json:"query,omitempty"`
	WorkDir string `json:"workDir,omitempty"`
	Max     int    `json:"max,omitempty"`
}

func (s *Server) handleBridgeWorkspaceFolders(w http.ResponseWriter, r *http.Request) {
	if s.workspaceService == nil {
		writeBridgeError(w, http.StatusNotFound, "capability_unavailable", "workspace bridge is not configured")
		return
	}
	folders, err := s.workspaceService.Folders()
	if err != nil {
		writeWorkspaceBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, folders)
}

func (s *Server) handleBridgeWorkspaceSymbols(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeWorkspaceQuery(w, r, true, func(req vscode.WorkspaceQuery) (any, error) {
		return s.workspaceService.Symbols(req)
	})
}

func (s *Server) handleBridgeWorkspaceSearchFiles(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeWorkspaceQuery(w, r, true, func(req vscode.WorkspaceQuery) (any, error) {
		return s.workspaceService.SearchFiles(req)
	})
}

func (s *Server) handleBridgeWorkspaceSearchText(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeWorkspaceQuery(w, r, true, func(req vscode.WorkspaceQuery) (any, error) {
		return s.workspaceService.SearchText(req)
	})
}

func (s *Server) handleBridgeWorkspaceProblems(w http.ResponseWriter, r *http.Request) {
	s.handleBridgeWorkspaceQuery(w, r, false, func(req vscode.WorkspaceQuery) (any, error) {
		return s.workspaceService.Problems(req)
	})
}

func (s *Server) handleBridgeWorkspaceQuery(w http.ResponseWriter, r *http.Request, requireQuery bool, fn func(vscode.WorkspaceQuery) (any, error)) {
	if s.workspaceService == nil {
		writeBridgeError(w, http.StatusNotFound, "capability_unavailable", "workspace bridge is not configured")
		return
	}
	var raw bridgeWorkspaceRequest
	if !decodeBridgeDocumentRequest(w, r, &raw) {
		return
	}
	req, err := sanitizeBridgeWorkspaceRequest(raw, requireQuery)
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	result, err := fn(req)
	if err != nil {
		writeWorkspaceBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func sanitizeBridgeWorkspaceRequest(raw bridgeWorkspaceRequest, requireQuery bool) (vscode.WorkspaceQuery, error) {
	query := strings.TrimSpace(raw.Query)
	if requireQuery && query == "" {
		return vscode.WorkspaceQuery{}, errors.New("query is required")
	}
	workDir := strings.TrimSpace(raw.WorkDir)
	if workDir != "" {
		cleaned, err := sanitizePath(workDir, true)
		if err != nil {
			return vscode.WorkspaceQuery{}, err
		}
		workDir = cleaned
	}
	if raw.Max < 0 {
		return vscode.WorkspaceQuery{}, errors.New("max must be zero or greater")
	}
	return vscode.WorkspaceQuery{
		Query:   query,
		WorkDir: workDir,
		Max:     raw.Max,
	}, nil
}

func writeWorkspaceBridgeError(w http.ResponseWriter, err error) {
	var bridgeErr *vscode.BridgeError
	if errors.As(err, &bridgeErr) {
		status := http.StatusBadGateway
		switch bridgeErr.Code {
		case "invalid_request":
			status = http.StatusBadRequest
		case "bridge_not_ready":
			status = http.StatusServiceUnavailable
		case "capability_unavailable":
			status = http.StatusNotImplemented
		}
		writeBridgeError(w, status, bridgeErr.Code, bridgeErr.Message)
		return
	}
	writeBridgeError(w, http.StatusInternalServerError, "bridge_error", "bridge workspace request failed")
}
