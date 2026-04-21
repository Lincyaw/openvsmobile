package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

type gitPathFilesRequest struct {
	Path  string   `json:"path"`
	File  string   `json:"file"`
	Files []string `json:"files"`
}

type gitDiffResponse struct {
	Path   string `json:"path"`
	Diff   string `json:"diff"`
	Staged bool   `json:"staged"`
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
	if s.gitService == nil && s.git == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "bridge git service is not configured")
		return
	}
	if s.gitService == nil {
		repo, err := s.git.GetRepository(repoPath)
		if err != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_repository_unavailable", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, repo)
		return
	}
	repo, err := s.gitService.GetRepository(repoPath)
	if err != nil {
		if s.git == nil {
			s.writeGitBridgeError(w, err)
			return
		}
		fallback, fallbackErr := s.git.GetRepository(repoPath)
		if fallbackErr != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_command_failed", fallbackErr.Error())
			return
		}
		writeJSON(w, http.StatusOK, fallback)
		return
	}
	writeJSON(w, http.StatusOK, repo)
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

	if s.gitService == nil && s.git == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "bridge git service is not configured")
		return
	}

	if s.gitService == nil {
		fallback, err := s.git.Diff(repoPath, file, staged)
		if err != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_repository_unavailable", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, gitDiffResponse{
			Path:   file,
			Diff:   fallback,
			Staged: staged,
		})
		return
	}

	diff, err := s.gitService.Diff(repoPath, file, staged)
	if err != nil {
		if s.git == nil {
			s.writeGitBridgeError(w, err)
			return
		}
		fallback, fallbackErr := s.git.Diff(repoPath, file, staged)
		if fallbackErr != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_command_failed", fallbackErr.Error())
			return
		}
		writeJSON(w, http.StatusOK, gitDiffResponse{
			Path:   file,
			Diff:   fallback,
			Staged: staged,
		})
		return
	}

	writeJSON(w, http.StatusOK, gitDiffResponse{
		Path:   chooseGitPath(diff.Path, file),
		Diff:   diff.Diff,
		Staged: diff.Staged,
	})
}

func (s *Server) handleGitStage(w http.ResponseWriter, r *http.Request) {
	s.handleGitCommandWithFallback(w, r, func(repoPath string, files []string) error {
		if s.gitService == nil {
			for _, f := range files {
				if err := s.git.Stage(repoPath, f); err != nil {
					return err
				}
			}
			return nil
		}
		_, err := s.gitService.Stage(repoPath, files)
		return err
	})
}

func (s *Server) handleGitUnstage(w http.ResponseWriter, r *http.Request) {
	s.handleGitCommandWithFallback(w, r, func(repoPath string, files []string) error {
		if s.gitService == nil {
			for _, f := range files {
				if err := s.git.Unstage(repoPath, f); err != nil {
					return err
				}
			}
			return nil
		}
		_, err := s.gitService.Unstage(repoPath, files)
		return err
	})
}

func (s *Server) handleGitCommit(w http.ResponseWriter, r *http.Request) {
	if s.gitService == nil && s.git == nil {
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
	if s.gitService == nil {
		if err := s.git.Commit(repoPath, req.Message); err != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
			return
		}
	} else {
		if _, err := s.gitService.Commit(repoPath, req.Message); err != nil {
			s.writeGitBridgeError(w, err)
			return
		}
	}
	s.writeRepoState(w, repoPath)
}

func (s *Server) handleGitCheckout(w http.ResponseWriter, r *http.Request) {
	if s.gitService == nil && s.git == nil {
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
	if s.gitService == nil {
		if err := s.git.Checkout(repoPath, ref); err != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
			return
		}
	} else {
		if _, err := s.gitService.Checkout(repoPath, ref, req.Create); err != nil {
			s.writeGitBridgeError(w, err)
			return
		}
	}
	s.writeRepoState(w, repoPath)
}

func (s *Server) handleGitFetch(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommandWithFallback(w, r, func(path string, req gitRemoteCommandRequest) error {
		if s.gitService == nil {
			return s.git.Fetch(path, req.Remote)
		}
		_, err := s.gitService.Fetch(path, req.Remote)
		return err
	})
}

func (s *Server) handleGitPull(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommandWithFallback(w, r, func(path string, req gitRemoteCommandRequest) error {
		if s.gitService == nil {
			return s.git.Pull(path, req.Remote, req.Branch)
		}
		_, err := s.gitService.Pull(path, req.Remote, req.Branch)
		return err
	})
}

func (s *Server) handleGitPush(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommandWithFallback(w, r, func(path string, req gitRemoteCommandRequest) error {
		if s.gitService == nil {
			return s.git.Push(path, req.Remote, req.Branch, req.SetUpstream)
		}
		_, err := s.gitService.Push(path, req.Remote, req.Branch, req.SetUpstream)
		return err
	})
}

func (s *Server) handleGitDiscard(w http.ResponseWriter, r *http.Request) {
	s.handleGitCommandWithFallback(w, r, func(repoPath string, files []string) error {
		if s.gitService == nil {
			for _, f := range files {
				if err := s.git.Discard(repoPath, f); err != nil {
					return err
				}
			}
			return nil
		}
		_, err := s.gitService.Discard(repoPath, files)
		return err
	})
}

func (s *Server) handleGitStash(w http.ResponseWriter, r *http.Request) {
	if s.gitService == nil && s.git == nil {
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
	if s.gitService == nil {
		if err := s.git.Stash(repoPath, req.Message, req.IncludeUntracked); err != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
			return
		}
	} else {
		if _, err := s.gitService.Stash(repoPath, req.Message, req.IncludeUntracked); err != nil {
			s.writeGitBridgeError(w, err)
			return
		}
	}
	s.writeRepoState(w, repoPath)
}

func (s *Server) handleGitStashApply(w http.ResponseWriter, r *http.Request) {
	if s.gitService == nil && s.git == nil {
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
	if s.gitService == nil {
		if err := s.git.StashApply(repoPath, req.Stash, req.Pop); err != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
			return
		}
	} else {
		if _, err := s.gitService.StashApply(repoPath, req.Stash, req.Pop); err != nil {
			s.writeGitBridgeError(w, err)
			return
		}
	}
	s.writeRepoState(w, repoPath)
}

func (s *Server) handleGitCommandWithFallback(w http.ResponseWriter, r *http.Request, command func(string, []string) error) {
	if s.gitService == nil && s.git == nil {
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
	if err := command(repoPath, files); err != nil {
		if s.gitService == nil {
			writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
		} else {
			s.writeGitBridgeError(w, err)
		}
		return
	}
	s.writeRepoState(w, repoPath)
}

func (s *Server) handleGitRemoteCommandWithFallback(w http.ResponseWriter, r *http.Request, command func(string, gitRemoteCommandRequest) error) {
	if s.gitService == nil && s.git == nil {
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
	if err := command(repoPath, req); err != nil {
		if s.gitService == nil {
			writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
		} else {
			s.writeGitBridgeError(w, err)
		}
		return
	}
	s.writeRepoState(w, repoPath)
}

func (s *Server) writeRepoState(w http.ResponseWriter, repoPath string) {
	if s.gitService == nil {
		repo, err := s.git.GetRepository(repoPath)
		if err != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_repository_unavailable", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, repo)
		return
	}
	repo, err := s.gitService.GetRepository(repoPath)
	if err != nil {
		if s.git == nil {
			s.writeGitBridgeError(w, err)
			return
		}
		fallback, fallbackErr := s.git.GetRepository(repoPath)
		if fallbackErr != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_command_failed", fallbackErr.Error())
			return
		}
		writeJSON(w, http.StatusOK, fallback)
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

func chooseGitPath(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
