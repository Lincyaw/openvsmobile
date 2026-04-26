package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/Lincyaw/vscode-mobile/server/internal/bridge"
)

type gitPathFilesRequest struct {
	Path  string   `json:"path"`
	File  string   `json:"file"`
	Files []string `json:"files"`
}

type gitCommitRequest struct {
	Path    string `json:"path"`
	Message string `json:"message"`
}

type gitCheckoutRequest struct {
	Path   string `json:"path"`
	Ref    string `json:"ref"`
	Branch string `json:"branch"`
	Create bool   `json:"create"`
}

type gitRemoteCommandRequest struct {
	Path        string `json:"path"`
	Remote      string `json:"remote"`
	Branch      string `json:"branch"`
	SetUpstream bool   `json:"setUpstream"`
}

type gitStashRequest struct {
	Path             string `json:"path"`
	Message          string `json:"message"`
	IncludeUntracked bool   `json:"includeUntracked"`
}

type gitStashApplyRequest struct {
	Path  string `json:"path"`
	Stash string `json:"stash"`
	Pop   bool   `json:"pop"`
}

func (s *Server) requireBridge(w http.ResponseWriter) bool {
	if s.bridge == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_unavailable", "openvsmobile-bridge extension is not configured")
		return false
	}
	return true
}

func (s *Server) handleGitRepository(w http.ResponseWriter, r *http.Request) {
	repoPath, err := sanitizeRequiredRepoPath(r.URL.Query().Get("path"))
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}
	if !s.requireBridge(w) {
		return
	}
	state, err := s.bridge.GitGetRepository(r.Context(), repoPath)
	if err != nil {
		writeBridgeFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleGitDiff(w http.ResponseWriter, r *http.Request) {
	repoPath, err := sanitizeRequiredRepoPath(r.URL.Query().Get("path"))
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}
	file, err := sanitizeRelativePath(r.URL.Query().Get("file"), repoPath)
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_file", err.Error())
		return
	}
	staged := strings.EqualFold(r.URL.Query().Get("staged"), "true")

	if !s.requireBridge(w) {
		return
	}

	diff, err := s.bridge.GitDiff(r.Context(), repoPath, file, staged)
	if err != nil {
		writeBridgeFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, diff)
}

func (s *Server) handleGitStage(w http.ResponseWriter, r *http.Request) {
	s.handleGitFileCommand(w, r, func(req bridge.FileCommandRequest) (bridge.RepositoryState, error) {
		return s.bridge.GitStage(r.Context(), req)
	})
}

func (s *Server) handleGitUnstage(w http.ResponseWriter, r *http.Request) {
	s.handleGitFileCommand(w, r, func(req bridge.FileCommandRequest) (bridge.RepositoryState, error) {
		return s.bridge.GitUnstage(r.Context(), req)
	})
}

func (s *Server) handleGitDiscard(w http.ResponseWriter, r *http.Request) {
	s.handleGitFileCommand(w, r, func(req bridge.FileCommandRequest) (bridge.RepositoryState, error) {
		return s.bridge.GitDiscard(r.Context(), req)
	})
}

func (s *Server) handleGitCommit(w http.ResponseWriter, r *http.Request) {
	if !s.requireBridge(w) {
		return
	}
	var req gitCommitRequest
	if !decodeGitJSON(w, r, &req) {
		return
	}
	repoPath, err := sanitizeRequiredRepoPath(req.Path)
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}
	if req.Message == "" {
		writeBridgeError(w, http.StatusBadRequest, "invalid_request", "commit message must not be empty")
		return
	}
	state, err := s.bridge.GitCommit(r.Context(), bridge.CommitRequest{Path: repoPath, Message: req.Message})
	if err != nil {
		writeBridgeFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleGitCheckout(w http.ResponseWriter, r *http.Request) {
	if !s.requireBridge(w) {
		return
	}
	var req gitCheckoutRequest
	if !decodeGitJSON(w, r, &req) {
		return
	}
	repoPath, err := sanitizeRequiredRepoPath(req.Path)
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}
	ref := req.Ref
	if ref == "" {
		ref = req.Branch
	}
	if ref == "" {
		writeBridgeError(w, http.StatusBadRequest, "invalid_request", "checkout requires 'ref' or 'branch'")
		return
	}
	state, err := s.bridge.GitCheckout(r.Context(), bridge.CheckoutRequest{Path: repoPath, Ref: ref, Create: req.Create})
	if err != nil {
		writeBridgeFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleGitFetch(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommand(w, r, func(req bridge.RemoteCommandRequest) (bridge.RepositoryState, error) {
		return s.bridge.GitFetch(r.Context(), req)
	})
}

func (s *Server) handleGitPull(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommand(w, r, func(req bridge.RemoteCommandRequest) (bridge.RepositoryState, error) {
		return s.bridge.GitPull(r.Context(), req)
	})
}

func (s *Server) handleGitPush(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommand(w, r, func(req bridge.RemoteCommandRequest) (bridge.RepositoryState, error) {
		return s.bridge.GitPush(r.Context(), req)
	})
}

func (s *Server) handleGitStash(w http.ResponseWriter, r *http.Request) {
	if !s.requireBridge(w) {
		return
	}
	var req gitStashRequest
	if !decodeGitJSON(w, r, &req) {
		return
	}
	repoPath, err := sanitizeRequiredRepoPath(req.Path)
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}
	state, err := s.bridge.GitStash(r.Context(), bridge.StashRequest{
		Path:             repoPath,
		Message:          req.Message,
		IncludeUntracked: req.IncludeUntracked,
	})
	if err != nil {
		writeBridgeFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleGitStashApply(w http.ResponseWriter, r *http.Request) {
	if !s.requireBridge(w) {
		return
	}
	var req gitStashApplyRequest
	if !decodeGitJSON(w, r, &req) {
		return
	}
	repoPath, err := sanitizeRequiredRepoPath(req.Path)
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}
	state, err := s.bridge.GitStashApply(r.Context(), bridge.StashApplyRequest{
		Path:  repoPath,
		Stash: req.Stash,
		Pop:   req.Pop,
	})
	if err != nil {
		writeBridgeFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleGitFileCommand(w http.ResponseWriter, r *http.Request, command func(bridge.FileCommandRequest) (bridge.RepositoryState, error)) {
	if !s.requireBridge(w) {
		return
	}
	var req gitPathFilesRequest
	if !decodeGitJSON(w, r, &req) {
		return
	}
	repoPath, files, ok := s.parseFileCommandRequest(w, req, true)
	if !ok {
		return
	}
	state, err := command(bridge.FileCommandRequest{Path: repoPath, Files: files})
	if err != nil {
		writeBridgeFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleGitRemoteCommand(w http.ResponseWriter, r *http.Request, command func(bridge.RemoteCommandRequest) (bridge.RepositoryState, error)) {
	if !s.requireBridge(w) {
		return
	}
	var req gitRemoteCommandRequest
	if !decodeGitJSON(w, r, &req) {
		return
	}
	repoPath, err := sanitizeRequiredRepoPath(req.Path)
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}
	state, err := command(bridge.RemoteCommandRequest{
		Path:        repoPath,
		Remote:      req.Remote,
		Branch:      req.Branch,
		SetUpstream: req.SetUpstream,
	})
	if err != nil {
		writeBridgeFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) parseFileCommandRequest(w http.ResponseWriter, req gitPathFilesRequest, requireFiles bool) (string, []string, bool) {
	repoPath, err := sanitizeRequiredRepoPath(req.Path)
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return "", nil, false
	}
	files := make([]string, 0, len(req.Files)+1)
	if req.File != "" {
		files = append(files, req.File)
	}
	files = append(files, req.Files...)
	files, err = sanitizeRelativePaths(files, repoPath)
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_file", err.Error())
		return "", nil, false
	}
	if requireFiles && len(files) == 0 {
		writeBridgeError(w, http.StatusBadRequest, "invalid_request", "at least one file is required")
		return "", nil, false
	}
	return repoPath, files, true
}

func sanitizeRequiredRepoPath(raw string) (string, error) {
	return sanitizePath(raw, true)
}

func sanitizeRelativePaths(raw []string, baseDir string) ([]string, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	files := make([]string, 0, len(raw))
	seen := make(map[string]struct{}, len(raw))
	for _, entry := range raw {
		if entry == "" {
			continue
		}
		file, err := sanitizeRelativePath(entry, baseDir)
		if err != nil {
			return nil, err
		}
		if _, ok := seen[file]; ok {
			continue
		}
		seen[file] = struct{}{}
		files = append(files, file)
	}
	return files, nil
}

func decodeGitJSON(w http.ResponseWriter, r *http.Request, dest interface{}) bool {
	if s := r.Header.Get("Content-Type"); s != "" && s != "application/json" && s != "application/json; charset=utf-8" {
		// Allow callers that send an empty Content-Type, but reject obviously wrong payload types.
		if len(s) >= len("application/json") && s[:len("application/json")] != "application/json" {
			writeBridgeError(w, http.StatusBadRequest, "invalid_request", fmt.Sprintf("expected application/json body, got %q", s))
			return false
		}
	}
	defer r.Body.Close()
	if err := json.NewDecoder(r.Body).Decode(dest); err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_request", "invalid request body: "+err.Error())
		return false
	}
	return true
}

// writeBridgeError preserves the response shape that the Flutter client and
// the previous bridge-backed handlers used for /bridge/* endpoints.
func writeBridgeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}{Code: code, Message: message})
}

// writeBridgeFailure forwards an error from the bridge client to the HTTP
// response, mapping bridge-side error metadata onto the response when present.
func writeBridgeFailure(w http.ResponseWriter, err error) {
	if errors.Is(err, bridge.ErrBridgeUnavailable) {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_unavailable", err.Error())
		return
	}
	var bridgeErr *bridge.Error
	if errors.As(err, &bridgeErr) {
		status := bridgeErr.Status
		if status == 0 {
			status = http.StatusBadGateway
		}
		code := bridgeErr.Code
		if code == "" {
			code = "bridge_request_failed"
		}
		message := bridgeErr.Detail
		if message == "" {
			message = bridgeErr.Error()
		}
		writeBridgeError(w, status, code, message)
		return
	}
	writeBridgeError(w, http.StatusBadGateway, "bridge_request_failed", err.Error())
}
