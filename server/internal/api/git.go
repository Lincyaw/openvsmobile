package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
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

func (s *Server) handleGitRepository(w http.ResponseWriter, r *http.Request) {
	repoPath, err := sanitizeRequiredRepoPath(r.URL.Query().Get("path"))
	if err != nil {
		writeBridgeError(w, http.StatusBadRequest, "invalid_path", err.Error())
		return
	}
	if s.gitService == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "bridge git service is not configured")
		return
	}
	repo, err := s.gitService.GetRepository(repoPath)
	if err != nil {
		s.writeGitBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, repo)
}

func (s *Server) handleGitStage(w http.ResponseWriter, r *http.Request) {
	if s.gitService == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "bridge git service is not configured")
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
	repo, err := s.gitService.Stage(repoPath, files)
	if err != nil {
		s.writeGitBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, repo)
}

func (s *Server) handleGitUnstage(w http.ResponseWriter, r *http.Request) {
	if s.gitService == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "bridge git service is not configured")
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
	repo, err := s.gitService.Unstage(repoPath, files)
	if err != nil {
		s.writeGitBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, repo)
}

func (s *Server) handleGitCommit(w http.ResponseWriter, r *http.Request) {
	if s.gitService == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "bridge git service is not configured")
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
	repo, err := s.gitService.Commit(repoPath, req.Message)
	if err != nil {
		s.writeGitBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, repo)
}

func (s *Server) handleGitCheckout(w http.ResponseWriter, r *http.Request) {
	if s.gitService == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "bridge git service is not configured")
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
	repo, err := s.gitService.Checkout(repoPath, ref, req.Create)
	if err != nil {
		s.writeGitBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, repo)
}

func (s *Server) handleGitFetch(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommand(w, r, func(path string, req gitRemoteCommandRequest) (vscode.GitRepositoryDocument, error) {
		return s.gitService.Fetch(path, req.Remote)
	})
}

func (s *Server) handleGitPull(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommand(w, r, func(path string, req gitRemoteCommandRequest) (vscode.GitRepositoryDocument, error) {
		return s.gitService.Pull(path, req.Remote, req.Branch)
	})
}

func (s *Server) handleGitPush(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommand(w, r, func(path string, req gitRemoteCommandRequest) (vscode.GitRepositoryDocument, error) {
		return s.gitService.Push(path, req.Remote, req.Branch, req.SetUpstream)
	})
}

func (s *Server) handleGitDiscard(w http.ResponseWriter, r *http.Request) {
	if s.gitService == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "bridge git service is not configured")
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
	repo, err := s.gitService.Discard(repoPath, files)
	if err != nil {
		s.writeGitBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, repo)
}

func (s *Server) handleGitStash(w http.ResponseWriter, r *http.Request) {
	if s.gitService == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "bridge git service is not configured")
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
	repo, err := s.gitService.Stash(repoPath, req.Message, req.IncludeUntracked)
	if err != nil {
		s.writeGitBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, repo)
}

func (s *Server) handleGitStashApply(w http.ResponseWriter, r *http.Request) {
	if s.gitService == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "bridge git service is not configured")
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
	repo, err := s.gitService.StashApply(repoPath, req.Stash, req.Pop)
	if err != nil {
		s.writeGitBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, repo)
}

func (s *Server) handleGitRemoteCommand(w http.ResponseWriter, r *http.Request, command func(string, gitRemoteCommandRequest) (vscode.GitRepositoryDocument, error)) {
	if s.gitService == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "bridge git service is not configured")
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
	repo, err := command(repoPath, req)
	if err != nil {
		s.writeGitBridgeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, repo)
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

func (s *Server) writeGitBridgeError(w http.ResponseWriter, err error) {
	var bridgeErr *vscode.BridgeError
	if errors.As(err, &bridgeErr) {
		status := http.StatusInternalServerError
		switch bridgeErr.Code {
		case "bridge_not_ready":
			status = http.StatusServiceUnavailable
		case "git_repository_unavailable":
			status = http.StatusBadGateway
		case "git_command_failed":
			status = http.StatusBadGateway
		case "git_subscription_failed":
			status = http.StatusServiceUnavailable
		}
		writeBridgeError(w, status, bridgeErr.Code, bridgeErr.Message)
		return
	}
	writeBridgeError(w, http.StatusInternalServerError, "internal_error", err.Error())
}
