package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"strings"
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
	if s.git == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "git_unavailable", "git is not configured")
		return
	}
	repo, err := s.git.GetRepository(repoPath)
	if err != nil {
		writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
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

	if s.git == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "git_unavailable", "git is not configured")
		return
	}

	diff, err := s.git.Diff(repoPath, file, staged)
	if err != nil {
		writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
		return
	}

	writeJSON(w, http.StatusOK, gitDiffResponse{
		Path:   file,
		Diff:   diff,
		Staged: staged,
	})
}

func (s *Server) handleGitStage(w http.ResponseWriter, r *http.Request) {
	s.handleGitFileCommand(w, r, func(repoPath string, files []string) error {
		for _, f := range files {
			if err := s.git.Stage(repoPath, f); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *Server) handleGitUnstage(w http.ResponseWriter, r *http.Request) {
	s.handleGitFileCommand(w, r, func(repoPath string, files []string) error {
		for _, f := range files {
			if err := s.git.Unstage(repoPath, f); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *Server) handleGitCommit(w http.ResponseWriter, r *http.Request) {
	if s.git == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "git_unavailable", "git is not configured")
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
	if err := s.git.Commit(repoPath, req.Message); err != nil {
		writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
		return
	}
	s.writeRepoState(w, repoPath)
}

func (s *Server) handleGitCheckout(w http.ResponseWriter, r *http.Request) {
	if s.git == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "git_unavailable", "git is not configured")
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
	// The local Git.Checkout only checks out an existing branch; the bridge
	// supported a `create` flag. Preserve that behaviour by running an
	// explicit `git checkout -b <ref>` when the caller asks to create.
	if req.Create {
		// Local Git has no Checkout(create=true); fall back to running raw.
		if err := s.gitCheckoutCreate(repoPath, ref); err != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
			return
		}
	} else {
		if err := s.git.Checkout(repoPath, ref); err != nil {
			writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
			return
		}
	}
	s.writeRepoState(w, repoPath)
}

// gitCheckoutCreate performs `git checkout -b <ref>` against the repo at path.
// Implemented inline because the local Git type does not expose a public hook
// for the create flag; the underlying `run` method is unexported.
func (s *Server) gitCheckoutCreate(repoPath, ref string) error {
	// Best effort: stage the create by attempting plain checkout first; if it
	// fails, fall back to creating. This keeps behaviour idempotent without
	// exposing run() externally.
	if err := s.git.Checkout(repoPath, ref); err == nil {
		return nil
	}
	cmd := exec.Command("git", "-C", repoPath, "checkout", "-b", ref)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("git checkout -b %s: %w: %s", ref, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (s *Server) handleGitFetch(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommand(w, r, func(path string, req gitRemoteCommandRequest) error {
		return s.git.Fetch(path, req.Remote)
	})
}

func (s *Server) handleGitPull(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommand(w, r, func(path string, req gitRemoteCommandRequest) error {
		return s.git.Pull(path, req.Remote, req.Branch)
	})
}

func (s *Server) handleGitPush(w http.ResponseWriter, r *http.Request) {
	s.handleGitRemoteCommand(w, r, func(path string, req gitRemoteCommandRequest) error {
		return s.git.Push(path, req.Remote, req.Branch, req.SetUpstream)
	})
}

func (s *Server) handleGitDiscard(w http.ResponseWriter, r *http.Request) {
	s.handleGitFileCommand(w, r, func(repoPath string, files []string) error {
		for _, f := range files {
			if err := s.git.Discard(repoPath, f); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *Server) handleGitStash(w http.ResponseWriter, r *http.Request) {
	if s.git == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "git_unavailable", "git is not configured")
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
	if err := s.git.Stash(repoPath, req.Message, req.IncludeUntracked); err != nil {
		writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
		return
	}
	s.writeRepoState(w, repoPath)
}

func (s *Server) handleGitStashApply(w http.ResponseWriter, r *http.Request) {
	if s.git == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "git_unavailable", "git is not configured")
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
	if err := s.git.StashApply(repoPath, req.Stash, req.Pop); err != nil {
		writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
		return
	}
	s.writeRepoState(w, repoPath)
}

func (s *Server) handleGitFileCommand(w http.ResponseWriter, r *http.Request, command func(string, []string) error) {
	if s.git == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "git_unavailable", "git is not configured")
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
		writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
		return
	}
	s.writeRepoState(w, repoPath)
}

func (s *Server) handleGitRemoteCommand(w http.ResponseWriter, r *http.Request, command func(string, gitRemoteCommandRequest) error) {
	if s.git == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "git_unavailable", "git is not configured")
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
		writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
		return
	}
	s.writeRepoState(w, repoPath)
}

func (s *Server) writeRepoState(w http.ResponseWriter, repoPath string) {
	if s.git == nil {
		writeBridgeError(w, http.StatusServiceUnavailable, "git_unavailable", "git is not configured")
		return
	}
	repo, err := s.git.GetRepository(repoPath)
	if err != nil {
		writeBridgeError(w, http.StatusBadGateway, "git_command_failed", err.Error())
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

// writeBridgeError preserves the response shape that the Flutter client and
// the previous bridge-backed handlers used for /bridge/* endpoints.
func writeBridgeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}{Code: code, Message: message})
}
