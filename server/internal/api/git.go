package api

import (
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
