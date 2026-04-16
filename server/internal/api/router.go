package api

import (
	"bufio"
	"log"
	"net"
	"net/http"
	"strings"
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
	fileWatcher      *FileWatcher
}

// NewServer creates a new API server.
func NewServer(fs FileSystem, sessionIndex *claude.SessionIndex, pm *claude.ProcessManager, token string, gitClient *git.Git, termMgr *terminal.Manager, diagRunner *diagnostics.Runner) *Server {
	hub := NewFileWatchHub()
	var fw *FileWatcher
	if fs != nil {
		var err error
		fw, err = NewFileWatcher(hub)
		if err != nil {
			log.Printf("[Server] failed to create file watcher: %v", err)
		}
	}
	return &Server{
		fs:               fs,
		sessionIndex:     sessionIndex,
		processManager:   pm,
		token:            token,
		git:              gitClient,
		termManager:      termMgr,
		diagnosticRunner: diagRunner,
		fileWatchHub:     hub,
		fileWatcher:      fw,
	}
}

// Close releases server resources.
func (s *Server) Close() error {
	if s.fileWatcher != nil {
		return s.fileWatcher.Close()
	}
	return nil
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
	mux.HandleFunc("GET /api/git/show", s.handleGitShowCommit)
	mux.HandleFunc("POST /api/git/stage", s.handleGitStage)
	mux.HandleFunc("POST /api/git/unstage", s.handleGitUnstage)
	mux.HandleFunc("POST /api/git/commit", s.handleGitCommit)
	mux.HandleFunc("POST /api/git/checkout", s.handleGitCheckout)

	// Search endpoints.
	mux.HandleFunc("GET /api/search", s.handleSearch)
	mux.HandleFunc("GET /api/search/files", s.handleSearchFiles)

	// Diagnostics endpoint.
	mux.HandleFunc("GET /api/diagnostics", s.handleDiagnostics)

	// WebSocket endpoints.
	mux.HandleFunc("/ws/chat", s.handleWSChat)
	mux.HandleFunc("/ws/files", s.handleWSFiles)
	mux.HandleFunc("/ws/terminal", s.handleWSTerminal)

	// Health-check endpoint (unauthenticated for connectivity tests).
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	// Wrap with auth and logging middlewares.
	return s.loggingMiddleware(s.authMiddleware(mux))
}

// loggingMiddleware logs incoming HTTP requests with method, path, status, and duration.
func (s *Server) loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		wrapped := &responseRecorder{ResponseWriter: w, statusCode: http.StatusOK}
		next.ServeHTTP(wrapped, r)
		status := wrapped.statusCode
		// If the connection was hijacked for WebSocket, the status stays at the
		// default 200 because WriteHeader was never called through the wrapper.
		if status == http.StatusOK && strings.HasPrefix(r.URL.Path, "/ws/") {
			status = http.StatusSwitchingProtocols
		}
		log.Printf("[HTTP] %s %s -> %d in %s", r.Method, r.URL.Path, status, time.Since(start))
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

// Hijack implements http.Hijacker so that WebSocket upgrades work
// through the logging middleware. Without this, gorilla/websocket's
// Upgrade() fails with "response does not implement http.Hijacker".
func (rr *responseRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return rr.ResponseWriter.(http.Hijacker).Hijack()
}

// Flush implements http.Flusher for streaming responses.
func (rr *responseRecorder) Flush() {
	if f, ok := rr.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// authMiddleware checks the connection token.
func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Health endpoint is unauthenticated so the client can verify
		// connectivity before checking credentials.
		if r.URL.Path == "/api/health" {
			next.ServeHTTP(w, r)
			return
		}

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
