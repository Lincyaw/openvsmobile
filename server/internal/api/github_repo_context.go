package api

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	gitauth "github.com/Lincyaw/vscode-mobile/server/internal/github"
)

type resolveLocalFileRequest struct {
	WorkspacePath string `json:"workspace_path"`
	Path          string `json:"path"`
	RelativePath  string `json:"relative_path"`
}

type resolveLocalFileResponse struct {
	RepoRoot     string `json:"repo_root"`
	RelativePath string `json:"relative_path"`
	LocalPath    string `json:"local_path"`
	Exists       bool   `json:"exists"`
}

func (s *Server) registerGitHubRepoContextRoutes(mux *http.ServeMux) {
	routes := []struct {
		method  string
		pattern string
		handler http.HandlerFunc
	}{
		{http.MethodGet, "/api/github/repos/current", s.handleGitHubCurrentRepo},
		{http.MethodGet, "/github/repos/current", s.handleGitHubCurrentRepo},
		{http.MethodPost, "/api/github/resolve-local-file", s.handleGitHubResolveLocalFile},
		{http.MethodPost, "/github/resolve-local-file", s.handleGitHubResolveLocalFile},
	}
	for _, route := range routes {
		mux.HandleFunc(route.method+" "+route.pattern, route.handler)
	}
}

func (s *Server) handleGitHubCurrentRepo(w http.ResponseWriter, r *http.Request) {
	context, err := s.currentRepoContext(r)
	if err != nil {
		writeGitHubAuthError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, context)
}

func (s *Server) handleGitHubResolveLocalFile(w http.ResponseWriter, r *http.Request) {
	var req resolveLocalFileRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}

	repoContext, err := s.repoContextForWorkspace(req.WorkspacePath)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "repo_not_github", err.Error())
		return
	}

	relPath := strings.TrimSpace(req.RelativePath)
	if relPath == "" {
		relPath = strings.TrimSpace(req.Path)
	}
	if relPath == "" {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", "path is required")
		return
	}
	cleanedRelativePath, err := sanitizeRelativePath(relPath, repoContext.RepoRoot)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}

	localPath := filepath.Join(repoContext.RepoRoot, cleanedRelativePath)
	relToRoot, err := filepath.Rel(repoContext.RepoRoot, localPath)
	if err != nil || strings.HasPrefix(relToRoot, "..") {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", "path must stay within the repository root")
		return
	}

	_, statErr := os.Stat(localPath)
	if statErr != nil && !os.IsNotExist(statErr) {
		writeJSONError(w, http.StatusInternalServerError, "stat_failed", statErr.Error())
		return
	}

	writeJSON(w, http.StatusOK, resolveLocalFileResponse{
		RepoRoot:     repoContext.RepoRoot,
		RelativePath: cleanedRelativePath,
		LocalPath:    localPath,
		Exists:       statErr == nil,
	})
}

func (s *Server) currentRepoContext(r *http.Request) (*gitauth.CurrentRepoContext, error) {
	service := s.githubAuthService()
	return service.ProbeCurrentRepo(r.Context(), s.git, r.URL.Query().Get("path"))
}

func (s *Server) repoContextForWorkspace(workspacePath string) (*gitauth.Repository, error) {
	service := s.githubAuthService()
	current, err := service.ProbeCurrentRepo(context.Background(), s.git, workspacePath)
	if err != nil {
		return nil, err
	}
	if current == nil || current.Repository == nil {
		return nil, fmt.Errorf("current repository is unavailable")
	}
	if current.Status == gitauth.RepoStatusRepoNotGitHub {
		if current.Message != "" {
			return nil, fmt.Errorf(current.Message)
		}
		return nil, fmt.Errorf("current workspace is not backed by a GitHub repository")
	}
	return current.Repository, nil
}
