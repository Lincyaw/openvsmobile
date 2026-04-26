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
	gitauth "github.com/Lincyaw/vscode-mobile/server/internal/github"
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
	githubAuth       *gitauth.Service
	fileWatchHub     *FileWatchHub
}

// NewServer creates a new API server.
func NewServer(
	fs FileSystem,
	sessionIndex *claude.SessionIndex,
	pm *claude.ProcessManager,
	token string,
	gitClient *git.Git,
	termMgr *terminal.Manager,
	diagRunner *diagnostics.Runner,
	githubAuth *gitauth.Service,
) *Server {
	return &Server{
		fs:               fs,
		sessionIndex:     sessionIndex,
		processManager:   pm,
		token:            token,
		git:              gitClient,
		termManager:      termMgr,
		diagnosticRunner: diagRunner,
		githubAuth:       githubAuth,
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

	// Git endpoints (backed by the local git CLI).
	mux.HandleFunc("GET /bridge/git/repository", s.handleGitRepository)
	mux.HandleFunc("GET /bridge/git/diff", s.handleGitDiff)
	mux.HandleFunc("POST /bridge/git/stage", s.handleGitStage)
	mux.HandleFunc("POST /bridge/git/unstage", s.handleGitUnstage)
	mux.HandleFunc("POST /bridge/git/commit", s.handleGitCommit)
	mux.HandleFunc("POST /bridge/git/checkout", s.handleGitCheckout)
	mux.HandleFunc("POST /bridge/git/fetch", s.handleGitFetch)
	mux.HandleFunc("POST /bridge/git/pull", s.handleGitPull)
	mux.HandleFunc("POST /bridge/git/push", s.handleGitPush)
	mux.HandleFunc("POST /bridge/git/discard", s.handleGitDiscard)
	mux.HandleFunc("POST /bridge/git/stash", s.handleGitStash)
	mux.HandleFunc("POST /bridge/git/stash/apply", s.handleGitStashApply)

	// Search endpoints.
	mux.HandleFunc("GET /api/search", s.handleSearch)
	mux.HandleFunc("GET /api/search/files", s.handleSearchFiles)

	// Diagnostics endpoint.
	mux.HandleFunc("GET /api/diagnostics", s.handleDiagnostics)

	// Terminal endpoints (backed by the local PTY manager).
	mux.HandleFunc("GET /bridge/terminal/sessions", s.handleTerminalSessions)
	mux.HandleFunc("POST /bridge/terminal/create", s.handleTerminalCreate)
	mux.HandleFunc("POST /bridge/terminal/attach", s.handleTerminalAttach)
	mux.HandleFunc("POST /bridge/terminal/resize", s.handleTerminalResize)
	mux.HandleFunc("POST /bridge/terminal/close", s.handleTerminalClose)
	mux.HandleFunc("POST /bridge/terminal/rename", s.handleTerminalRename)
	mux.HandleFunc("POST /bridge/terminal/split", s.handleTerminalSplit)

	// GitHub auth endpoints (device flow + token storage for workbuddy).
	s.registerGitHubAuthRoutes(mux)

	// WebSocket endpoints.
	mux.HandleFunc("/ws/chat", s.handleWSChat)
	mux.HandleFunc("/ws/files", s.handleWSFiles)
	mux.HandleFunc("GET /bridge/ws/terminal/{id}", s.handleWSBridgeTerminal)

	// Health-check endpoint (unauthenticated for connectivity tests).
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

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
		if status == http.StatusOK && (strings.HasPrefix(r.URL.Path, "/ws/") || strings.HasPrefix(r.URL.Path, "/bridge/ws/")) {
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

func (rr *responseRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return rr.ResponseWriter.(http.Hijacker).Hijack()
}

func (rr *responseRecorder) Flush() {
	if f, ok := rr.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// authMiddleware checks the connection token.
func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/health" {
			next.ServeHTTP(w, r)
			return
		}
		if s.token == "" {
			next.ServeHTTP(w, r)
			return
		}
		if r.URL.Query().Get("token") == s.token {
			next.ServeHTTP(w, r)
			return
		}
		if r.Header.Get("Authorization") == "Bearer "+s.token {
			next.ServeHTTP(w, r)
			return
		}
		http.Error(w, "unauthorized", http.StatusUnauthorized)
	})
}

func (s *Server) githubAuthService() *gitauth.Service {
	return s.githubAuth
}
