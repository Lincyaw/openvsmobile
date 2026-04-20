package api

import (
	"log"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/Lincyaw/vscode-mobile/server/internal/diagnostics"
	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

// handleDiagnostics handles GET /api/diagnostics?path=<file>&workDir=<dir>.
// Returns structured diagnostic findings for the given file or directory.
func (s *Server) handleDiagnostics(w http.ResponseWriter, r *http.Request) {
	if s.diagnosticRunner == nil && s.editorService == nil {
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

	if s.editorService != nil && filePath != "" {
		if s.documentSync == nil {
			writeBridgeError(w, http.StatusServiceUnavailable, "bridge_not_ready", "document sync is not configured")
			return
		}
		snapshot, err := s.documentSync.DocumentBuffer(filePath)
		if err != nil {
			writeEditorBridgeError(w, err)
			return
		}
		doc, err := s.editorService.Diagnostics(vscode.EditorRequest{
			Path:    filePath,
			Version: snapshot.Version,
			WorkDir: workDir,
		})
		if err != nil {
			writeEditorBridgeError(w, err)
			return
		}
		if strings.EqualFold(r.URL.Query().Get("format"), "lsp") {
			version := doc.Version
			writeJSON(w, http.StatusOK, diagnosticsDocumentToReport(doc, &version))
		} else {
			writeJSON(w, http.StatusOK, doc.Diagnostics)
		}
		return
	}

	if s.diagnosticRunner == nil {
		http.Error(w, "diagnostics not configured", http.StatusServiceUnavailable)
		return
	}

	if filePath != "" {
		results, runErr = s.diagnosticRunner.RunForFile(filePath, workDir)
	} else {
		results, runErr = s.diagnosticRunner.RunForDirectory(workDir)
	}
	err = runErr

	if err != nil {
		log.Printf("[Diagnostics] error for path=%s workDir=%s: %v", filePath, workDir, err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	log.Printf("[Diagnostics] path=%s workDir=%s", filePath, workDir)
	if strings.EqualFold(r.URL.Query().Get("format"), "lsp") && filePath != "" {
		var version *int
		if s.documentSync != nil {
			if snapshot, err := s.documentSync.DocumentBuffer(filePath); err == nil {
				version = &snapshot.Version
			}
		}
		if entries, ok := results.([]diagnostics.Diagnostic); ok {
			writeJSON(w, http.StatusOK, diagnosticsToLSPReport(filePath, version, entries))
			return
		}
	}
	writeJSON(w, http.StatusOK, results)
}
