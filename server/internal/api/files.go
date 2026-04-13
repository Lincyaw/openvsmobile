package api

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"path/filepath"
	"strings"
)

// handleFilesGet handles GET /api/files/*path.
// If the path refers to a directory, it lists entries.
// If it refers to a file, it returns the file content.
func (s *Server) handleFilesGet(w http.ResponseWriter, r *http.Request) {
	path, err := extractFilePath(r)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}

	if s.fs == nil {
		http.Error(w, "file system not configured", http.StatusServiceUnavailable)
		return
	}

	stat, err := s.fs.Stat(path)
	if err != nil {
		log.Printf("stat error for %s: %v", path, err)
		http.Error(w, "file not found", http.StatusNotFound)
		return
	}

	if stat.IsDir {
		entries, err := s.fs.ReadDir(path)
		if err != nil {
			log.Printf("readdir error for %s: %v", path, err)
			http.Error(w, "failed to read directory", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, entries)
		return
	}

	data, err := s.fs.ReadFile(path)
	if err != nil {
		log.Printf("readfile error for %s: %v", path, err)
		http.Error(w, "failed to read file", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)
	w.Write(data)
}

// handleFilesPut handles PUT /api/files/*path.
func (s *Server) handleFilesPut(w http.ResponseWriter, r *http.Request) {
	path, err := extractFilePath(r)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}

	if s.fs == nil {
		http.Error(w, "file system not configured", http.StatusServiceUnavailable)
		return
	}

	// Limit request body to 10 MB to prevent resource exhaustion.
	const maxBodySize = 10 << 20 // 10 MB
	r.Body = http.MaxBytesReader(w, r.Body, maxBodySize)

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read body (max 10MB)", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	if err := s.fs.WriteFile(path, body); err != nil {
		log.Printf("writefile error for %s: %v", path, err)
		http.Error(w, "failed to write file", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// handleFilesDelete handles DELETE /api/files/*path.
func (s *Server) handleFilesDelete(w http.ResponseWriter, r *http.Request) {
	path, err := extractFilePath(r)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}

	if s.fs == nil {
		http.Error(w, "file system not configured", http.StatusServiceUnavailable)
		return
	}

	if err := s.fs.Delete(path); err != nil {
		log.Printf("delete error for %s: %v", path, err)
		http.Error(w, "failed to delete file", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// handleFilesPost handles POST /api/files/*path.
// Currently supports creating directories when ?type=directory is set.
func (s *Server) handleFilesPost(w http.ResponseWriter, r *http.Request) {
	path, err := extractFilePath(r)
	if err != nil {
		http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
		return
	}

	if s.fs == nil {
		http.Error(w, "file system not configured", http.StatusServiceUnavailable)
		return
	}

	entryType := r.URL.Query().Get("type")
	if entryType != "directory" {
		http.Error(w, "unsupported type: must be 'directory'", http.StatusBadRequest)
		return
	}

	if err := s.fs.MkDir(path); err != nil {
		log.Printf("mkdir error for %s: %v", path, err)
		http.Error(w, "failed to create directory", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusCreated)
}

// extractFilePath extracts the file path from the request URL.
// It cleans the path to prevent directory traversal attacks.
func extractFilePath(r *http.Request) (string, error) {
	// Strip the /api/files prefix.
	path := strings.TrimPrefix(r.URL.Path, "/api/files")
	if path == "" {
		path = "/"
	}

	cleaned := filepath.Clean(path)

	// Reject paths that try to escape via ".." (after cleaning, a relative
	// path starting with ".." means traversal outside the root).
	if strings.HasPrefix(cleaned, "..") {
		return "", fmt.Errorf("path must not contain '..' traversal")
	}

	// Ensure the path is absolute (all valid file paths should be).
	if !filepath.IsAbs(cleaned) {
		return "", fmt.Errorf("path must be absolute")
	}

	return cleaned, nil
}

// writeJSON writes a JSON response.
func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("writeJSON encode error: %v", err)
	}
}
