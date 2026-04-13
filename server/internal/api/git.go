package api

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/Lincyaw/vscode-mobile/server/internal/git"
)

// handleGitStatus handles GET /api/git/status?path=<dir>.
func (s *Server) handleGitStatus(w http.ResponseWriter, r *http.Request) {
	rawPath := r.URL.Query().Get("path")
	if rawPath == "" {
		http.Error(w, "missing 'path' parameter", http.StatusBadRequest)
		return
	}
	path, err := sanitizePath(rawPath, true)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}

	entries, err := s.git.Status(path)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if entries == nil {
		entries = []git.StatusEntry{}
	}

	writeJSON(w, http.StatusOK, entries)
}

// handleGitDiff handles GET /api/git/diff?path=<dir>&file=<file>&staged=true.
func (s *Server) handleGitDiff(w http.ResponseWriter, r *http.Request) {
	rawPath := r.URL.Query().Get("path")
	if rawPath == "" {
		http.Error(w, "missing 'path' parameter", http.StatusBadRequest)
		return
	}
	path, err := sanitizePath(rawPath, true)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}

	filePath := r.URL.Query().Get("file")
	if filePath != "" {
		filePath, err = sanitizeRelativePath(filePath, path)
		if err != nil {
			http.Error(w, "invalid file path: "+err.Error(), http.StatusBadRequest)
			return
		}
	}
	staged := r.URL.Query().Get("staged") == "true"

	diff, err := s.git.Diff(path, filePath, staged)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write([]byte(diff))
}

// handleGitLog handles GET /api/git/log?path=<dir>&count=20.
func (s *Server) handleGitLog(w http.ResponseWriter, r *http.Request) {
	rawPath := r.URL.Query().Get("path")
	if rawPath == "" {
		http.Error(w, "missing 'path' parameter", http.StatusBadRequest)
		return
	}
	path, err := sanitizePath(rawPath, true)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}

	count := 20
	if c := r.URL.Query().Get("count"); c != "" {
		if n, err := strconv.Atoi(c); err == nil && n > 0 {
			count = n
		}
	}

	entries, err := s.git.Log(path, count)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if entries == nil {
		entries = []git.LogEntry{}
	}

	writeJSON(w, http.StatusOK, entries)
}

// handleGitBranches handles GET /api/git/branches?path=<dir>.
func (s *Server) handleGitBranches(w http.ResponseWriter, r *http.Request) {
	rawPath := r.URL.Query().Get("path")
	if rawPath == "" {
		http.Error(w, "missing 'path' parameter", http.StatusBadRequest)
		return
	}
	path, err := sanitizePath(rawPath, true)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}

	info, err := s.git.BranchInfo(path)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, info)
}

// gitPathFileRequest is the JSON body for stage/unstage requests.
type gitPathFileRequest struct {
	Path string `json:"path"`
	File string `json:"file"`
}

// gitCommitRequest is the JSON body for commit requests.
type gitCommitRequest struct {
	Path    string `json:"path"`
	Message string `json:"message"`
}

// handleGitStage handles POST /api/git/stage.
func (s *Server) handleGitStage(w http.ResponseWriter, r *http.Request) {
	var req gitPathFileRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.Path == "" || req.File == "" {
		http.Error(w, "missing 'path' or 'file' field", http.StatusBadRequest)
		return
	}
	path, err := sanitizePath(req.Path, true)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}
	file, err := sanitizeRelativePath(req.File, path)
	if err != nil {
		http.Error(w, "invalid file path: "+err.Error(), http.StatusBadRequest)
		return
	}
	if err := s.git.Stage(path, file); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// handleGitUnstage handles POST /api/git/unstage.
func (s *Server) handleGitUnstage(w http.ResponseWriter, r *http.Request) {
	var req gitPathFileRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.Path == "" || req.File == "" {
		http.Error(w, "missing 'path' or 'file' field", http.StatusBadRequest)
		return
	}
	path, err := sanitizePath(req.Path, true)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}
	file, err := sanitizeRelativePath(req.File, path)
	if err != nil {
		http.Error(w, "invalid file path: "+err.Error(), http.StatusBadRequest)
		return
	}
	if err := s.git.Unstage(path, file); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// handleGitCommit handles POST /api/git/commit.
func (s *Server) handleGitCommit(w http.ResponseWriter, r *http.Request) {
	var req gitCommitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.Path == "" {
		http.Error(w, "missing 'path' field", http.StatusBadRequest)
		return
	}
	if req.Message == "" {
		http.Error(w, "commit message must not be empty", http.StatusBadRequest)
		return
	}
	path, err := sanitizePath(req.Path, true)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}
	if err := s.git.Commit(path, req.Message); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}
