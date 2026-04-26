package api

import (
	"log"
	"net/http"
	"path/filepath"
	"strings"
)

// handleDiagnostics handles GET /api/diagnostics?path=<file>&workDir=<dir>.
// Returns structured diagnostic findings for the given file or directory.
func (s *Server) handleDiagnostics(w http.ResponseWriter, r *http.Request) {
	if s.diagnosticRunner == nil {
		http.Error(w, "diagnostics not configured", http.StatusServiceUnavailable)
		return
	}

	rawWorkDir := r.URL.Query().Get("workDir")
	if rawWorkDir == "" {
		rawWorkDir = "/"
	}
	workDir, err := sanitizePath(rawWorkDir, true)
	if err != nil {
		http.Error(w, "invalid workDir: "+err.Error(), http.StatusBadRequest)
		return
	}

	rawFilePath := r.URL.Query().Get("path")
	var filePath string
	if rawFilePath != "" {
		if filepath.IsAbs(rawFilePath) {
			// Absolute path: sanitize and verify it's under workDir.
			filePath, err = sanitizePath(rawFilePath, false)
			if err != nil {
				http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
				return
			}
			if !strings.HasPrefix(filePath, workDir+string(filepath.Separator)) && filePath != workDir {
				http.Error(w, "path must be within workDir", http.StatusBadRequest)
				return
			}
		} else {
			// Relative path: validate it doesn't escape workDir.
			filePath, err = sanitizeRelativePath(rawFilePath, workDir)
			if err != nil {
				http.Error(w, "invalid path: "+err.Error(), http.StatusBadRequest)
				return
			}
		}
	}

	var (
		results interface{}
		runErr  error
	)
	if filePath != "" {
		results, runErr = s.diagnosticRunner.RunForFile(filePath, workDir)
	} else {
		results, runErr = s.diagnosticRunner.RunForDirectory(workDir)
	}

	if runErr != nil {
		log.Printf("[Diagnostics] error for path=%s workDir=%s: %v", filePath, workDir, runErr)
		http.Error(w, runErr.Error(), http.StatusInternalServerError)
		return
	}

	log.Printf("[Diagnostics] path=%s workDir=%s", filePath, workDir)
	writeJSON(w, http.StatusOK, results)
}
