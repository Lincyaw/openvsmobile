package api

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	gitauth "github.com/Lincyaw/vscode-mobile/server/internal/github"
)

type githubIssueCommentRequest struct {
	WorkspacePath string `json:"workspace_path"`
	WorkDir       string `json:"workDir"`
	WorkDirAlt    string `json:"work_dir"`
	Body          string `json:"body"`
}

type githubPullCommentRequest struct {
	WorkspacePath string `json:"workspace_path"`
	WorkDir       string `json:"workDir"`
	WorkDirAlt    string `json:"work_dir"`
	Body          string `json:"body"`
	Path          string `json:"path,omitempty"`
	CommitID      string `json:"commit_id,omitempty"`
	Side          string `json:"side,omitempty"`
	StartSide     string `json:"start_side,omitempty"`
	Line          int    `json:"line,omitempty"`
	StartLine     int    `json:"start_line,omitempty"`
	InReplyTo     int64  `json:"in_reply_to,omitempty"`
}

type githubPullReviewCommentRequest struct {
	Body      string `json:"body"`
	Path      string `json:"path,omitempty"`
	Side      string `json:"side,omitempty"`
	StartSide string `json:"start_side,omitempty"`
	Line      int    `json:"line,omitempty"`
	StartLine int    `json:"start_line,omitempty"`
}

type githubPullReviewRequest struct {
	WorkspacePath string                           `json:"workspace_path"`
	WorkDir       string                           `json:"workDir"`
	WorkDirAlt    string                           `json:"work_dir"`
	Event         string                           `json:"event,omitempty"`
	Body          string                           `json:"body,omitempty"`
	CommitID      string                           `json:"commit_id,omitempty"`
	Comments      []githubPullReviewCommentRequest `json:"comments,omitempty"`
}

func (s *Server) registerGitHubCollaborationRoutes(mux *http.ServeMux) {
	routes := []struct {
		method  string
		pattern string
		handler http.HandlerFunc
	}{
		{http.MethodGet, "/api/github/account", s.handleGitHubAccount},
		{http.MethodGet, "/github/account", s.handleGitHubAccount},
		{http.MethodGet, "/api/github/issues", s.handleGitHubIssues},
		{http.MethodGet, "/github/issues", s.handleGitHubIssues},
		{http.MethodGet, "/api/github/issues/{number}", s.handleGitHubIssue},
		{http.MethodGet, "/github/issues/{number}", s.handleGitHubIssue},
		{http.MethodPost, "/api/github/issues/{number}/comments", s.handleGitHubIssueComment},
		{http.MethodPost, "/github/issues/{number}/comments", s.handleGitHubIssueComment},
		{http.MethodGet, "/api/github/pulls", s.handleGitHubPulls},
		{http.MethodGet, "/github/pulls", s.handleGitHubPulls},
		{http.MethodGet, "/api/github/pulls/{number}", s.handleGitHubPull},
		{http.MethodGet, "/github/pulls/{number}", s.handleGitHubPull},
		{http.MethodGet, "/api/github/pulls/{number}/files", s.handleGitHubPullFiles},
		{http.MethodGet, "/github/pulls/{number}/files", s.handleGitHubPullFiles},
		{http.MethodGet, "/api/github/pulls/{number}/comments", s.handleGitHubPullComments},
		{http.MethodGet, "/github/pulls/{number}/comments", s.handleGitHubPullComments},
		{http.MethodPost, "/api/github/pulls/{number}/comments", s.handleGitHubPullComment},
		{http.MethodPost, "/github/pulls/{number}/comments", s.handleGitHubPullComment},
		{http.MethodPost, "/api/github/pulls/{number}/reviews", s.handleGitHubPullReview},
		{http.MethodPost, "/github/pulls/{number}/reviews", s.handleGitHubPullReview},
	}
	for _, route := range routes {
		mux.HandleFunc(route.method+" "+route.pattern, route.handler)
	}
}

func (s *Server) handleGitHubAccount(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	workspace := s.workspacePathForRequest(r)
	account, repository, err := service.GetCurrentRepoAccount(r.Context(), s.git, workspace)
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"account": account, "repository": repository})
}

func (s *Server) handleGitHubIssues(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	filter, err := parseCollaborationFilter(r)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	issues, err := service.ListIssues(r.Context(), s.workspacePathForRequest(r), filter)
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"issues": issues})
}

func (s *Server) handleGitHubIssue(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	number, err := parseRouteNumber(r)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	workspace := s.workspacePathForRequest(r)
	issue, _, err := service.GetCurrentRepoIssue(r.Context(), s.git, workspace, number)
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	comments, _, err := service.GetIssueComments(r.Context(), workspace, number, parseListOptionsLoose(r))
	if err != nil && !errors.Is(err, gitauth.ErrNotFound) {
		writeGitHubCollaborationError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"issue": issue, "comments": comments})
}

func (s *Server) handleGitHubIssueComment(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	number, err := parseRouteNumber(r)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	var req githubIssueCommentRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	if strings.TrimSpace(req.Body) == "" {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", "body is required")
		return
	}
	comment, err := service.CreateIssueComment(r.Context(), workspacePathFromBody(req.WorkspacePath, req.WorkDir, req.WorkDirAlt), number, gitauth.CreateIssueCommentInput{Body: req.Body})
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"comment": comment})
}

func (s *Server) handleGitHubPulls(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	filter, err := parseCollaborationFilter(r)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	pulls, err := service.ListPullRequests(r.Context(), s.workspacePathForRequest(r), filter)
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"pulls": pulls})
}

func (s *Server) handleGitHubPull(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	number, err := parseRouteNumber(r)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	workspace := s.workspacePathForRequest(r)
	pull, err := service.GetPullRequest(r.Context(), workspace, number)
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	files, _, err := service.ListCurrentRepoPullRequestFiles(r.Context(), s.git, workspace, number, parseListOptionsLoose(r))
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	comments, _, err := service.ListCurrentRepoPullRequestComments(r.Context(), s.git, workspace, number, parseListOptionsLoose(r))
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	reviews, _, err := service.GetPullRequestReviews(r.Context(), workspace, number, parseListOptionsLoose(r))
	if err != nil && !errors.Is(err, gitauth.ErrNotFound) {
		writeGitHubCollaborationError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"pull_request": pull,
		"files":        files,
		"comments":     comments,
		"reviews":      reviews,
	})
}

func (s *Server) handleGitHubPullFiles(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	number, err := parseRouteNumber(r)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	files, _, err := service.ListCurrentRepoPullRequestFiles(r.Context(), s.git, s.workspacePathForRequest(r), number, parseListOptionsLoose(r))
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"files": files})
}

func (s *Server) handleGitHubPullComments(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	number, err := parseRouteNumber(r)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	workspace := s.workspacePathForRequest(r)
	comments, _, err := service.ListCurrentRepoPullRequestComments(r.Context(), s.git, workspace, number, parseListOptionsLoose(r))
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	reviews, _, err := service.GetPullRequestReviews(r.Context(), workspace, number, parseListOptionsLoose(r))
	if err != nil && !errors.Is(err, gitauth.ErrNotFound) {
		writeGitHubCollaborationError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"comments": comments, "reviews": reviews})
}

func (s *Server) handleGitHubPullComment(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	number, err := parseRouteNumber(r)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	var req githubPullCommentRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	if strings.TrimSpace(req.Body) == "" {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", "body is required")
		return
	}
	comment, err := service.CreatePullRequestComment(r.Context(), workspacePathFromBody(req.WorkspacePath, req.WorkDir, req.WorkDirAlt), number, gitauth.CreatePullRequestCommentInput{
		Body:      req.Body,
		Path:      req.Path,
		CommitID:  req.CommitID,
		Side:      req.Side,
		StartSide: req.StartSide,
		Line:      req.Line,
		StartLine: req.StartLine,
		InReplyTo: req.InReplyTo,
	})
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"comment": comment})
}

func (s *Server) handleGitHubPullReview(w http.ResponseWriter, r *http.Request) {
	service := s.githubAuthService()
	if service == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "github_auth_disabled", "github auth is not configured")
		return
	}
	number, err := parseRouteNumber(r)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	var req githubPullReviewRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	comments := make([]gitauth.PullRequestReviewDraftComment, 0, len(req.Comments))
	for _, comment := range req.Comments {
		comments = append(comments, gitauth.PullRequestReviewDraftComment{
			Body:      comment.Body,
			Path:      comment.Path,
			Side:      comment.Side,
			StartSide: comment.StartSide,
			Line:      comment.Line,
			StartLine: comment.StartLine,
		})
	}
	review, err := service.CreatePullRequestReview(r.Context(), workspacePathFromBody(req.WorkspacePath, req.WorkDir, req.WorkDirAlt), number, gitauth.CreatePullRequestReviewInput{
		Event:    strings.ToUpper(strings.TrimSpace(req.Event)),
		Body:     req.Body,
		CommitID: req.CommitID,
		Comments: comments,
	})
	if err != nil {
		writeGitHubCollaborationError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"review": review})
}

func parseCollaborationFilter(r *http.Request) (gitauth.CollaborationFilter, error) {
	page, perPage, err := parsePageOptions(r)
	if err != nil {
		return gitauth.CollaborationFilter{}, err
	}
	assigned, err := parseBoolQuery(r, "assigned_to_me")
	if err != nil {
		return gitauth.CollaborationFilter{}, err
	}
	created, err := parseBoolQuery(r, "created_by_me")
	if err != nil {
		return gitauth.CollaborationFilter{}, err
	}
	mentioned, err := parseBoolQuery(r, "mentioned")
	if err != nil {
		return gitauth.CollaborationFilter{}, err
	}
	needsReview, err := parseBoolQuery(r, "needs_review")
	if err != nil {
		return gitauth.CollaborationFilter{}, err
	}
	return gitauth.CollaborationFilter{
		State:        r.URL.Query().Get("state"),
		AssignedToMe: assigned,
		CreatedByMe:  created,
		Mentioned:    mentioned,
		NeedsReview:  needsReview,
		Page:         page,
		PerPage:      perPage,
	}, nil
}

func parseListOptionsLoose(r *http.Request) gitauth.ListOptions {
	page, perPage, _ := parsePageOptions(r)
	return gitauth.ListOptions{Sort: r.URL.Query().Get("sort"), Direction: r.URL.Query().Get("direction"), Since: r.URL.Query().Get("since"), Page: page, PerPage: perPage}
}

func parsePageOptions(r *http.Request) (int, int, error) {
	page := 0
	perPage := 0
	if raw := strings.TrimSpace(r.URL.Query().Get("page")); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value <= 0 {
			return 0, 0, errors.New("page must be a positive integer")
		}
		page = value
	}
	if raw := strings.TrimSpace(r.URL.Query().Get("per_page")); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value <= 0 {
			return 0, 0, errors.New("per_page must be a positive integer")
		}
		perPage = value
	}
	return page, perPage, nil
}

func parseBoolQuery(r *http.Request, key string) (bool, error) {
	raw := strings.TrimSpace(r.URL.Query().Get(key))
	if raw == "" {
		return false, nil
	}
	value, err := strconv.ParseBool(raw)
	if err != nil {
		return false, errors.New(key + " must be a boolean")
	}
	return value, nil
}

func parseRouteNumber(r *http.Request) (int, error) {
	raw := strings.TrimSpace(r.PathValue("number"))
	if raw == "" {
		return 0, errors.New("number is required")
	}
	number, err := strconv.Atoi(raw)
	if err != nil || number <= 0 {
		return 0, errors.New("number must be a positive integer")
	}
	return number, nil
}

func workspacePathFromQuery(r *http.Request) string {
	for _, key := range []string{"path", "workDir", "workspaceRoot"} {
		if value := strings.TrimSpace(r.URL.Query().Get(key)); value != "" {
			return value
		}
	}
	return ""
}

func (s *Server) workspacePathForRequest(r *http.Request) string {
	if path := workspacePathFromQuery(r); path != "" {
		return path
	}
	service := s.githubAuthService()
	if service == nil {
		return ""
	}
	current, err := service.ProbeCurrentRepo(r.Context(), s.git, "")
	if err != nil || current == nil || current.Repository == nil {
		return ""
	}
	return current.Repository.RepoRoot
}

func workspacePathFromBody(primary, camel, snake string) string {
	for _, value := range []string{primary, camel, snake} {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func writeGitHubCollaborationError(w http.ResponseWriter, err error) {
	status := http.StatusBadGateway
	code := gitauth.ErrorCode(err)
	switch {
	case errors.Is(err, gitauth.ErrRepoNotGitHub), errors.Is(err, gitauth.ErrInvalidRequest):
		status = http.StatusBadRequest
	case errors.Is(err, gitauth.ErrNotAuthenticated), errors.Is(err, gitauth.ErrReauthRequired):
		status = http.StatusUnauthorized
	case errors.Is(err, gitauth.ErrAppNotInstalledForRepo):
		status = http.StatusForbidden
	case errors.Is(err, gitauth.ErrRepoAccessUnavailable):
		status = http.StatusForbidden
	case errors.Is(err, gitauth.ErrNotFound):
		status = http.StatusNotFound
	}
	writeJSONError(w, status, code, err.Error())
}
