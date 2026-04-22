package api

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/gorilla/websocket"

	"github.com/Lincyaw/vscode-mobile/server/internal/terminal"
	"github.com/Lincyaw/vscode-mobile/server/internal/vscode"
)

type terminalCreateRequest struct {
	Name    string `json:"name"`
	Cwd     string `json:"cwd"`
	Profile string `json:"profile"`
	Rows    uint16 `json:"rows"`
	Cols    uint16 `json:"cols"`
}

type terminalIDRequest struct {
	ID string `json:"id"`
}

type terminalResizeRequest struct {
	ID   string `json:"id"`
	Rows uint16 `json:"rows"`
	Cols uint16 `json:"cols"`
}

type terminalRenameRequest struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type terminalSplitRequest struct {
	ParentID string `json:"parentId"`
	Name     string `json:"name"`
}

type terminalWSMessage struct {
	Type  string `json:"type"`
	Data  string `json:"data,omitempty"`
	Error string `json:"error,omitempty"`
}

func (s *Server) handleTerminalSessions(w http.ResponseWriter, r *http.Request) {
	if s.terminalService != nil {
		sessions, err := s.terminalService.List()
		if err != nil {
			writeJSONError(w, http.StatusServiceUnavailable, "terminal_list_failed", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, sessions)
		return
	}
	writeJSON(w, http.StatusOK, s.termManager.List())
}

func (s *Server) handleTerminalCreate(w http.ResponseWriter, r *http.Request) {
	var req terminalCreateRequest
	if err := decodeTerminalJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_terminal_request", err.Error())
		return
	}
	if err := validateTerminalProfile(req.Profile); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_terminal_profile", err.Error())
		return
	}
	if req.Cwd == "" {
		req.Cwd = "/"
	}
	if req.Cwd != "/" {
		cleaned, err := sanitizePath(req.Cwd, true)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "invalid_terminal_cwd", err.Error())
			return
		}
		req.Cwd = cleaned
	}

	if s.terminalService != nil {
		session, err := s.terminalService.CreateSession(terminal.CreateOptions{
			Name:    req.Name,
			WorkDir: req.Cwd,
			Profile: normalizeProfile(req.Profile),
			Rows:    req.Rows,
			Cols:    req.Cols,
		})
		if err != nil {
			writeJSONError(w, http.StatusServiceUnavailable, "terminal_create_failed", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, session)
		return
	}

	session, err := s.termManager.CreateSession(terminal.CreateOptions{
		Name:    req.Name,
		Shell:   profileShell(req.Profile),
		WorkDir: req.Cwd,
		Profile: normalizeProfile(req.Profile),
		Rows:    req.Rows,
		Cols:    req.Cols,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "terminal_create_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, session.Snapshot())
}

func (s *Server) handleTerminalAttach(w http.ResponseWriter, r *http.Request) {
	var req terminalIDRequest
	if err := decodeTerminalJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_terminal_request", err.Error())
		return
	}
	if s.terminalService != nil {
		session, _, err := s.terminalService.AttachSession(req.ID)
		if err != nil {
			writeJSONError(w, terminalStatus(err), "terminal_not_found", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, session)
		return
	}
	term, ok := s.termManager.Get(req.ID)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "terminal_not_found", "terminal session not found")
		return
	}
	writeJSON(w, http.StatusOK, term.Snapshot())
}

func (s *Server) handleTerminalResize(w http.ResponseWriter, r *http.Request) {
	var req terminalResizeRequest
	if err := decodeTerminalJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_terminal_request", err.Error())
		return
	}
	var (
		session terminal.Session
		err     error
	)
	if s.terminalService != nil {
		session, err = s.terminalService.ResizeSession(req.ID, req.Rows, req.Cols)
	} else {
		session, err = s.termManager.ResizeSession(req.ID, req.Rows, req.Cols)
	}
	if err != nil {
		writeJSONError(w, terminalStatus(err), "terminal_resize_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (s *Server) handleTerminalClose(w http.ResponseWriter, r *http.Request) {
	var req terminalIDRequest
	if err := decodeTerminalJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_terminal_request", err.Error())
		return
	}
	var (
		session terminal.Session
		err     error
	)
	if s.terminalService != nil {
		session, err = s.terminalService.CloseSession(req.ID)
	} else {
		session, err = s.termManager.CloseSession(req.ID)
	}
	if err != nil {
		writeJSONError(w, terminalStatus(err), "terminal_close_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (s *Server) handleTerminalRename(w http.ResponseWriter, r *http.Request) {
	var req terminalRenameRequest
	if err := decodeTerminalJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_terminal_request", err.Error())
		return
	}
	if req.Name == "" {
		writeJSONError(w, http.StatusBadRequest, "invalid_terminal_name", "name is required")
		return
	}
	var (
		session terminal.Session
		err     error
	)
	if s.terminalService != nil {
		session, err = s.terminalService.Rename(req.ID, req.Name)
	} else {
		session, err = s.termManager.Rename(req.ID, req.Name)
	}
	if err != nil {
		writeJSONError(w, terminalStatus(err), "terminal_rename_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (s *Server) handleTerminalSplit(w http.ResponseWriter, r *http.Request) {
	var req terminalSplitRequest
	if err := decodeTerminalJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_terminal_request", err.Error())
		return
	}
	var (
		session terminal.Session
		err     error
	)
	if s.terminalService != nil {
		session, err = s.terminalService.Split(req.ParentID, req.Name)
	} else {
		session, err = s.termManager.Split(req.ParentID, req.Name)
	}
	if err != nil {
		writeJSONError(w, terminalStatus(err), "terminal_split_failed", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (s *Server) handleWSBridgeTerminal(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("id")

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()

	var (
		attachment *terminal.Attachment
		session    terminal.Session
	)
	if s.terminalService != nil {
		attachment, session, err = s.terminalService.Attach(sessionID)
		if err != nil {
			http.Error(w, err.Error(), terminalStatus(err))
			return
		}
	} else {
		term, ok := s.termManager.Get(sessionID)
		if !ok {
			http.Error(w, "terminal session not found", http.StatusNotFound)
			return
		}
		attachment, err = s.termManager.Attach(sessionID)
		if err != nil {
			http.Error(w, err.Error(), terminalStatus(err))
			return
		}
		session = term.Snapshot()
	}
	defer attachment.Close()

	if err := conn.WriteJSON(map[string]any{
		"type":    "ready",
		"session": session,
	}); err != nil {
		return
	}
	for _, chunk := range [][]byte{attachment.Backlog()} {
		if len(chunk) == 0 {
			continue
		}
		if err := conn.WriteJSON(terminalWSMessage{
			Type: "replay",
			Data: base64.StdEncoding.EncodeToString(chunk),
		}); err != nil {
			return
		}
	}

	errCh := make(chan error, 1)
	go func() {
		for chunk := range attachment.Output() {
			if err := conn.WriteJSON(terminalWSMessage{
				Type: "output",
				Data: base64.StdEncoding.EncodeToString(chunk),
			}); err != nil {
				errCh <- err
				return
			}
		}
		errCh <- nil
	}()

	readCh := make(chan []byte, 1)
	readErrCh := make(chan error, 1)
	go func() {
		for {
			_, payload, err := conn.ReadMessage()
			if err != nil {
				readErrCh <- err
				return
			}
			readCh <- payload
		}
	}()

	for {
		select {
		case outputErr := <-errCh:
			if outputErr == nil {
				_ = conn.WriteJSON(map[string]any{
					"type":    "exit",
					"session": session,
				})
			}
			return
		case err := <-readErrCh:
			_ = err
			return
		case payload := <-readCh:
			var msg terminalWSMessage
			if err := json.Unmarshal(payload, &msg); err != nil {
				_ = conn.WriteJSON(terminalWSMessage{Type: "error", Error: "invalid terminal websocket message"})
				continue
			}
			if msg.Type != "input" {
				_ = conn.WriteJSON(terminalWSMessage{Type: "error", Error: "unsupported terminal websocket message"})
				continue
			}

			input, err := decodeTerminalInput(msg.Data)
			if err != nil {
				_ = conn.WriteJSON(terminalWSMessage{Type: "error", Error: err.Error()})
				continue
			}
			if s.terminalService != nil {
				if err := s.terminalService.Input(sessionID, input); err != nil {
					writeTerminalStreamError(conn, err)
					return
				}
			} else {
				term, ok := s.termManager.Get(sessionID)
				if !ok {
					writeTerminalStreamError(conn, errors.New("terminal session not found"))
					return
				}
				if _, err := term.Write(input); err != nil {
					writeTerminalStreamError(conn, err)
					return
				}
			}
		}
	}
}

func writeTerminalStreamError(conn *websocket.Conn, err error) {
	_ = conn.WriteJSON(terminalWSMessage{Type: "error", Error: err.Error()})
}

func decodeTerminalJSONBody(r *http.Request, dest any) error {
	if r.Body == nil {
		return errors.New("request body is required")
	}
	defer r.Body.Close()

	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dest); err != nil {
		return err
	}
	return nil
}

func decodeTerminalInput(data string) ([]byte, error) {
	if data == "" {
		return nil, errors.New("input data is required")
	}
	decoded, err := base64.StdEncoding.DecodeString(data)
	if err == nil {
		return decoded, nil
	}
	return []byte(data), nil
}

func validateTerminalProfile(profile string) error {
	if !allowedShells[profileShell(profile)] {
		return fmt.Errorf("profile not allowed: %s", profile)
	}
	return nil
}

func normalizeProfile(profile string) string {
	if profile == "" {
		return "bash"
	}
	return profile
}

func profileShell(profile string) string {
	switch profile {
	case "", "bash", "/bin/bash", "/usr/bin/bash":
		return "/bin/bash"
	case "zsh", "/bin/zsh", "/usr/bin/zsh":
		return "/bin/zsh"
	case "sh", "/bin/sh":
		return "/bin/sh"
	default:
		return profile
	}
}

func terminalStatus(err error) int {
	if err == nil {
		return http.StatusOK
	}
	var bridgeErr *vscode.BridgeError
	if errors.As(err, &bridgeErr) {
		switch bridgeErr.Code {
		case "bridge_not_ready", "terminal_subscription_failed":
			return http.StatusServiceUnavailable
		case "terminal_command_failed":
			return http.StatusBadGateway
		}
	}
	if errors.Is(err, websocket.ErrBadHandshake) {
		return http.StatusBadRequest
	}
	if strings.Contains(err.Error(), "not found") {
		return http.StatusNotFound
	}
	return http.StatusBadRequest
}

var allowedShells = map[string]bool{
	"/bin/bash":     true,
	"/bin/sh":       true,
	"/bin/zsh":      true,
	"/usr/bin/bash": true,
	"/usr/bin/zsh":  true,
}
