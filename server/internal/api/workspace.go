package api

import (
	"net/http"

	"github.com/Lincyaw/vscode-mobile/server/internal/bridge"
)

// handleWorkspaceFolders forwards GET /api/workspace/folders to the bridge.
func (s *Server) handleWorkspaceFolders(w http.ResponseWriter, r *http.Request) {
	if !s.requireBridge(w) {
		return
	}
	folders, err := s.bridge.WorkspaceFolders(r.Context())
	if err != nil {
		writeBridgeFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, folders)
}

// handleWorkspaceFindFiles forwards GET /api/workspace/findFiles to the bridge.
func (s *Server) handleWorkspaceFindFiles(w http.ResponseWriter, r *http.Request) {
	if !s.requireBridge(w) {
		return
	}
	q := r.URL.Query()
	opts := bridge.FindFilesOptions{
		Glob:     q.Get("glob"),
		Excludes: q.Get("excludes"),
	}
	if v := q.Get("maxResults"); v != "" {
		var n int
		if _, err := fmtAtoi(v, &n); err == nil && n > 0 {
			opts.MaxResults = n
		}
	}
	matches, err := s.bridge.FindFiles(r.Context(), opts)
	if err != nil {
		writeBridgeFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, matches)
}

// handleWorkspaceFindText forwards GET /api/workspace/findText to the bridge.
func (s *Server) handleWorkspaceFindText(w http.ResponseWriter, r *http.Request) {
	if !s.requireBridge(w) {
		return
	}
	q := r.URL.Query()
	query := q.Get("query")
	if query == "" {
		writeBridgeError(w, http.StatusBadRequest, "invalid_request", "query is required")
		return
	}
	opts := bridge.FindTextOptions{
		Query:           query,
		IsRegex:         q.Get("isRegex") == "true",
		IsCaseSensitive: q.Get("isCaseSensitive") == "true",
		IsWordMatch:     q.Get("isWordMatch") == "true",
		Include:         q.Get("include"),
		Exclude:         q.Get("exclude"),
	}
	matches, err := s.bridge.FindText(r.Context(), opts)
	if err != nil {
		writeBridgeFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, matches)
}

// fmtAtoi is a tiny zero-import helper to convert a numeric query string to int.
func fmtAtoi(s string, dst *int) (int, error) {
	v := 0
	for _, ch := range s {
		if ch < '0' || ch > '9' {
			return 0, errAtoi(s)
		}
		v = v*10 + int(ch-'0')
	}
	*dst = v
	return 1, nil
}

type atoiError string

func (e atoiError) Error() string { return "invalid integer: " + string(e) }

func errAtoi(s string) error { return atoiError(s) }
