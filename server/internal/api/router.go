package api

import (
	"log"
	"net/http"
	"time"

	"github.com/Lincyaw/vscode-mobile/server/internal/claude"
	"github.com/Lincyaw/vscode-mobile/server/internal/diagnostics"
	"github.com/Lincyaw/vscode-mobile/server/internal/git"
	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
)

// FileSystem defines the interface for file operations.
// The vscode package will implement this interface.
type FileSystem interface {
	ReadDir(path string) ([]claude.DirEntry, error)
	ReadFile(path string) ([]byte, error)
	WriteFile(path string, content []byte) error
	Stat(path string) (*claude.FileStat, error)
	Delete(path string) error
	MkDir(path string) error
}

// Server holds the dependencies for the API handlers.
type Server struct {
	fs               FileSystem
	sessionIndex     *claude.SessionIndex
	processManager   *claude.ProcessManager
	token            string
	git              *git.Git
	termManager      *terminal.Manager
	diagnosticRunner *diagnostics.Runner
	fileWatchHub     *FileWatchHub
}

// NewServer creates a new API server.
func NewServer(fs FileSystem, sessionIndex *claude.SessionIndex, pm *claude.ProcessManager, token string, gitClient *git.Git, termMgr *terminal.Manager, diagRunner *diagnostics.Runner) *Server {
	return &Server{
		fs:               fs,
		sessionIndex:     sessionIndex,
		processManager:   pm,
		token:            token,
		git:              gitClient,
		termManager:      termMgr,
		diagnosticRunner: diagRunner,
		fileWatchHub:     NewFileWatchHub(),
	}
}

// Handler returns the top-level HTTP handler with all routes.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// REST endpoints.
	mux.HandleFunc("GET /api/files/", s.handleFilesGet)
	mux.HandleFunc("PUT /api/files/", s.handleFilesPut)
	mux.HandleFunc("DELETE /api/files/", s.handleFilesDelete)
	mux.HandleFunc("POST /api/files/", s.handleFilesPost)
	mux.HandleFunc("GET /api/sessions", s.handleSessionsList)
	mux.HandleFunc("GET /api/sessions/{id}/messages", s.handleSessionMessages)
	mux.HandleFunc("GET /api/sessions/{id}/subagents/{agentId}/messages", s.handleSubagentMessages)
	mux.HandleFunc("GET /api/sessions/{id}/subagents/{agentId}/meta", s.handleSubagentMeta)

	// Git endpoints.
	mux.HandleFunc("GET /api/git/status", s.handleGitStatus)
	mux.HandleFunc("GET /api/git/diff", s.handleGitDiff)
	mux.HandleFunc("GET /api/git/log", s.handleGitLog)
	mux.HandleFunc("GET /api/git/branches", s.handleGitBranches)
	mux.HandleFunc("POST /api/git/stage", s.handleGitStage)
	mux.HandleFunc("POST /api/git/unstage", s.handleGitUnstage)
	mux.HandleFunc("POST /api/git/commit", s.handleGitCommit)

	// Search endpoint.
	mux.HandleFunc("GET /api/search", s.handleSearch)

	// Diagnostics endpoint.
	mux.HandleFunc("GET /api/diagnostics", s.handleDiagnostics)

	// WebSocket endpoints.
	mux.HandleFunc("/ws/chat", s.handleWSChat)
	mux.HandleFunc("/ws/files", s.handleWSFiles)
	mux.HandleFunc("/ws/terminal", s.handleWSTerminal)

	// Wrap with auth and logging middlewares.
	return s.loggingMiddleware(s.authMiddleware(mux))
}

// loggingMiddleware logs incoming HTTP requests with method, path, status, and duration.
func (s *Server) loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		wrapped := &responseRecorder{ResponseWriter: w, statusCode: http.StatusOK}
		next.ServeHTTP(wrapped, r)
		log.Printf("[HTTP] %s %s -> %d in %s", r.Method, r.URL.Path, wrapped.statusCode, time.Since(start))
	})
}

type responseRecorder struct {
	http.ResponseWriter
	statusCode int
}

func (rr *responseRecorder) WriteHeader(code int) {
	rr.statusCode = code
	rr.ResponseWriter.WriteHeader(code)
}

// authMiddleware checks the connection token.
func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.token == "" {
			next.ServeHTTP(w, r)
			return
		}

		// Check query parameter.
		// NOTE: Passing auth tokens in URL query strings is a security concern
		// because URLs are logged in server logs, browser history, and proxy logs.
		// This is acceptable here as a convenience for WebSocket connections from
		// the mobile client, but the Authorization header should be preferred
		// for REST API calls.
		if r.URL.Query().Get("token") == s.token {
			next.ServeHTTP(w, r)
			return
		}

		// Check Authorization header.
		auth := r.Header.Get("Authorization")
		if auth == "Bearer "+s.token {
			next.ServeHTTP(w, r)
			return
		}

		http.Error(w, "unauthorized", http.StatusUnauthorized)
	})
}
