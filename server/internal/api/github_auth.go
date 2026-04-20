package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	gitauth "github.com/Lincyaw/vscode-mobile/server/internal/github"
)

type githubAuthStartRequest struct {
	GitHubHost string `json:"github_host"`
}

type githubAuthPollRequest struct {
	GitHubHost string `json:"github_host"`
	DeviceCode string `json:"device_code"`
}

type githubAuthDisconnectRequest struct {
	GitHubHost string `json:"github_host"`
}

type githubAuthErrorResponse struct {
	ErrorCode string `json:"error_code"`
	Message   string `json:"message"`
}

func (s *Server) registerGitHubAuthRoutes(mux *http.ServeMux) {
	routes := []struct {
		method  string
		pattern string
		handler http.HandlerFunc
	}{
		{http.MethodPost, "/api/github/auth/device/start", s.handleGitHubAuthDeviceStart},
		{http.MethodPost, "/api/github/auth/device/poll", s.handleGitHubAuthDevicePoll},
		{http.MethodGet, "/api/github/auth/status", s.handleGitHubAuthStatus},
		{http.MethodPost, "/api/github/auth/disconnect", s.handleGitHubAuthDisconnect},
		{http.MethodPost, "/github/auth/device/start", s.handleGitHubAuthDeviceStart},
		{http.MethodPost, "/github/auth/device/poll", s.handleGitHubAuthDevicePoll},
		{http.MethodGet, "/github/auth/status", s.handleGitHubAuthStatus},
		{http.MethodPost, "/github/auth/disconnect", s.handleGitHubAuthDisconnect},
	}
	for _, route := range routes {
		mux.HandleFunc(route.method+" "+route.pattern, route.handler)
	}
}

func (s *Server) handleGitHubAuthDeviceStart(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	var req githubAuthStartRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	resp, err := service.StartDeviceFlow(r.Context(), req.GitHubHost)
	if err != nil {
		writeGitHubAuthError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"github_host":      service.ResolveHost(req.GitHubHost),
		"device_code":      resp.DeviceCode,
		"user_code":        resp.UserCode,
		"verification_uri": resp.VerificationURI,
		"expires_in":       resp.ExpiresIn,
		"interval":         resp.Interval,
	})
}

func (s *Server) handleGitHubAuthDevicePoll(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	var req githubAuthPollRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	if strings.TrimSpace(req.DeviceCode) == "" {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", "device_code is required")
		return
	}
	resp, err := service.PollDeviceFlow(r.Context(), req.GitHubHost, req.DeviceCode)
	if err != nil {
		writeGitHubAuthError(w, err)
		return
	}
	payload := map[string]any{
		"status":      resp.Status,
		"github_host": service.ResolveHost(req.GitHubHost),
	}
	if resp.ErrorCode != "" {
		payload["error_code"] = resp.ErrorCode
	}
	if resp.Message != "" {
		payload["message"] = resp.Message
	}
	if resp.Auth != nil {
		payload["auth"] = resp.Auth
	}
	writeJSON(w, http.StatusOK, payload)
}

func (s *Server) handleGitHubAuthStatus(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	status, err := service.GetStatus(r.Context(), r.URL.Query().Get("github_host"))
	if err != nil {
		writeGitHubAuthError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, status)
}

func (s *Server) handleGitHubAuthDisconnect(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	var req githubAuthDisconnectRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	if err := service.Disconnect(r.Context(), req.GitHubHost); err != nil {
		writeGitHubAuthError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"disconnected": true,
		"github_host":  service.ResolveHost(req.GitHubHost),
	})
}

func decodeJSONBody(r *http.Request, out any) error {
	if r.Body == nil {
		return nil
	}
	defer r.Body.Close()
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		return err
	}
	if len(strings.TrimSpace(string(body))) == 0 {
		return nil
	}
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	decoder.DisallowUnknownFields()
	return decoder.Decode(out)
}

func writeGitHubAuthError(w http.ResponseWriter, err error) {
	status := http.StatusInternalServerError
	code := gitauth.ErrorCode(err)
	switch {
	case errors.Is(err, gitauth.ErrNotAuthenticated), errors.Is(err, gitauth.ErrReauthRequired):
		status = http.StatusUnauthorized
	case errors.Is(err, gitauth.ErrAccessDenied), errors.Is(err, gitauth.ErrExpiredToken), errors.Is(err, gitauth.ErrBadRefreshToken), errors.Is(err, gitauth.ErrRefreshNotSupported):
		status = http.StatusBadGateway
	}
	writeJSONError(w, status, code, err.Error())
}

func writeJSONError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, githubAuthErrorResponse{ErrorCode: code, Message: message})
}
