package api

import (
	"log"
	"net/http"
	"path/filepath"
	"strings"
)

// handleDiagnostics handles GET /api/diagnostics?path=<file>&workDir=<dir>.
// Diagnostics are sourced from the live VS Code language servers via the
// openvsmobile-bridge extension. This endpoint no longer shells out to
// `go vet` / `dart analyze`; if the bridge is unreachable it returns 503.
func (s *Server) handleDiagnostics(w http.ResponseWriter, r *http.Request) {
	if !s.requireBridge(w) {
		return
	}

	rawWorkDir := r.URL.Query().Get("workDir")
	var workDir string
	if rawWorkDir != "" {
		cleaned, err := sanitizePath(rawWorkDir, true)
		if err != nil {
			writeBridgeError(w, http.StatusBadRequest, "invalid_workdir", err.Error())
			return
		}
		workDir = cleaned
	}

	rawFilePath := r.URL.Query().Get("path")
	var filePath string
	if rawFilePath != "" {
		var err error
		if filepath.IsAbs(rawFilePath) {
			filePath, err = sanitizePath(rawFilePath, false)
			if err != nil {
				writeBridgeError(w, http.StatusBadRequest, "invalid_path", err.Error())
				return
			}
			if workDir != "" && !strings.HasPrefix(filePath, workDir+string(filepath.Separator)) && filePath != workDir {
				writeBridgeError(w, http.StatusBadRequest, "invalid_path", "path must be within workDir")
				return
			}
		} else {
			base := workDir
			if base == "" {
				writeBridgeError(w, http.StatusBadRequest, "invalid_path", "relative path requires workDir")
				return
			}
			filePath, err = sanitizeRelativePath(rawFilePath, base)
			if err != nil {
				writeBridgeError(w, http.StatusBadRequest, "invalid_path", err.Error())
				return
			}
			if filePath != "" {
				filePath = filepath.Join(base, filePath)
			}
		}
	}

	results, err := s.bridge.DiagnosticsList(r.Context(), filePath, workDir)
	if err != nil {
		log.Printf("[Diagnostics] bridge error path=%s workDir=%s: %v", filePath, workDir, err)
		writeBridgeFailure(w, err)
		return
	}

	log.Printf("[Diagnostics] path=%s workDir=%s count=%d", filePath, workDir, len(results))
	writeJSON(w, http.StatusOK, results)
}
