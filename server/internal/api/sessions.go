package api

import (
	"errors"
	"log"
	"net/http"
	"os"

	"github.com/Lincyaw/vscode-mobile/server/internal/claude"
)

// handleSessionsList handles GET /api/sessions.
// Supports query params: ?q=keyword&workspaceRoot=/abs/path for filtering.
func (s *Server) handleSessionsList(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	workspaceRoot := r.URL.Query().Get("workspaceRoot")
	if workspaceRoot == "" {
		workspaceRoot = r.URL.Query().Get("project")
	}

	var sessions []claude.SessionMeta
	if query != "" || workspaceRoot != "" {
		sessions = s.sessionIndex.SearchSessions(query, workspaceRoot)
	} else {
		sessions = s.sessionIndex.ListSessions()
	}
	log.Printf("[Sessions] listed sessions (query=%q, workspaceRoot=%q, count=%d)", query, workspaceRoot, len(sessions))
	writeJSON(w, http.StatusOK, sessions)
}

// handleSessionMessages handles GET /api/sessions/:id/messages.
func (s *Server) handleSessionMessages(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	if sessionID == "" {
		http.Error(w, "missing session id", http.StatusBadRequest)
		return
	}

	messages, err := s.sessionIndex.GetMessages(sessionID)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, os.ErrPermission) {
			http.Error(w, "session not found", http.StatusNotFound)
		} else {
			log.Printf("[Sessions] error fetching messages for %s: %v", sessionID, err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
		}
		return
	}

	log.Printf("[Sessions] fetched messages for %s (count=%d)", sessionID, len(messages))
	writeJSON(w, http.StatusOK, messages)
}

// handleSubagentMessages handles GET /api/sessions/:id/subagents/:agentId/messages.
func (s *Server) handleSubagentMessages(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	agentID := r.PathValue("agentId")
	if sessionID == "" || agentID == "" {
		http.Error(w, "missing session id or agent id", http.StatusBadRequest)
		return
	}

	messages, err := s.sessionIndex.GetSubagentMessages(sessionID, agentID)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, os.ErrPermission) {
			http.Error(w, "subagent messages not found", http.StatusNotFound)
		} else {
			log.Printf("[Sessions] error fetching subagent messages for %s/%s: %v", sessionID, agentID, err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
		}
		return
	}

	log.Printf("[Sessions] fetched subagent messages for %s/%s (count=%d)", sessionID, agentID, len(messages))
	writeJSON(w, http.StatusOK, messages)
}

// handleSubagentMeta handles GET /api/sessions/:id/subagents/:agentId/meta.
func (s *Server) handleSubagentMeta(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")
	agentID := r.PathValue("agentId")
	if sessionID == "" || agentID == "" {
		http.Error(w, "missing session id or agent id", http.StatusBadRequest)
		return
	}

	meta, err := s.sessionIndex.GetSubagentMeta(sessionID, agentID)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, os.ErrPermission) {
			http.Error(w, "subagent meta not found", http.StatusNotFound)
		} else {
			log.Printf("[Sessions] error fetching subagent meta for %s/%s: %v", sessionID, agentID, err)
			http.Error(w, "internal server error", http.StatusInternalServerError)
		}
		return
	}

	log.Printf("[Sessions] fetched subagent meta for %s/%s", sessionID, agentID)
	writeJSON(w, http.StatusOK, meta)
}
