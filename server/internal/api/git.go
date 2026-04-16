package api

import (
	"encoding/json"
	"log"
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
	log.Printf("[Git] status path=%s", path)

	entries, err := s.git.Status(path)
	if err != nil {
		log.Printf("[Git] status error for %s: %v", path, err)
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
	log.Printf("[Git] diff path=%s", path)

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
		log.Printf("[Git] diff error for %s: %v", path, err)
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
	log.Printf("[Git] log path=%s", path)

	count := 20
	if c := r.URL.Query().Get("count"); c != "" {
		if n, err := strconv.Atoi(c); err == nil && n > 0 {
			count = n
		}
	}

	entries, err := s.git.Log(path, count)
	if err != nil {
		log.Printf("[Git] log error for %s: %v", path, err)
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
	log.Printf("[Git] branches path=%s", path)

	info, err := s.git.BranchInfo(path)
	if err != nil {
		log.Printf("[Git] branches error for %s: %v", path, err)
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

// gitCheckoutRequest is the JSON body for checkout requests.
type gitCheckoutRequest struct {
	Path   string `json:"path"`
	Branch string `json:"branch"`
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
		log.Printf("[Git] stage error for %s/%s: %v", path, file, err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("[Git] staged %s in %s", file, path)
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
		log.Printf("[Git] unstage error for %s/%s: %v", path, file, err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("[Git] unstaged %s in %s", file, path)
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
		log.Printf("[Git] commit error in %s: %v", path, err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("[Git] committed in %s: %s", path, req.Message)
	w.WriteHeader(http.StatusOK)
}

// handleGitShowCommit handles GET /api/git/show?path=<dir>&hash=<hash>.
func (s *Server) handleGitShowCommit(w http.ResponseWriter, r *http.Request) {
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
	hash := r.URL.Query().Get("hash")
	if hash == "" {
		http.Error(w, "missing 'hash' parameter", http.StatusBadRequest)
		return
	}
	log.Printf("[Git] show commit path=%s hash=%s", path, hash)

	out, err := s.git.ShowCommit(path, hash)
	if err != nil {
		log.Printf("[Git] show commit error for %s/%s: %v", path, hash, err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write([]byte(out))
}

// handleGitCheckout handles POST /api/git/checkout.
func (s *Server) handleGitCheckout(w http.ResponseWriter, r *http.Request) {
	var req gitCheckoutRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.Path == "" || req.Branch == "" {
		http.Error(w, "missing 'path' or 'branch' field", http.StatusBadRequest)
		return
	}
	path, err := sanitizePath(req.Path, true)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}
	if err := s.git.Checkout(path, req.Branch); err != nil {
		log.Printf("[Git] checkout error in %s to %s: %v", path, req.Branch, err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("[Git] checked out %s in %s", req.Branch, path)
	w.WriteHeader(http.StatusOK)
}
