package github

import (
	"encoding/json"
	"errors"
	"strings"
	"time"
)

const DefaultHost = "github.com"

const (
	RepoStatusOK                    = "ok"
	RepoStatusRepoNotGitHub         = "repo_not_github"
	RepoStatusNotAuthenticated      = "not_authenticated"
	RepoStatusReauthRequired        = "reauth_required"
	RepoStatusRepoAccessUnavailable = "repo_access_unavailable"
	RepoStatusAppNotInstalled       = "app_not_installed_for_repo"
)

var (
	ErrAuthorizationPending   = errors.New("github authorization pending")
	ErrSlowDown               = errors.New("github authorization slow down")
	ErrAccessDenied           = errors.New("github access denied")
	ErrExpiredToken           = errors.New("github device code expired")
	ErrBadRefreshToken        = errors.New("github bad refresh token")
	ErrRefreshNotSupported    = errors.New("github refresh token support is required")
	ErrReauthRequired         = errors.New("github reauthorization required")
	ErrNotAuthenticated       = errors.New("github not authenticated")
	ErrRepoNotGitHub          = errors.New("current workspace is not a github repository")
	ErrRepoAccessUnavailable  = errors.New("github repo access unavailable")
	ErrAppNotInstalledForRepo = errors.New("github app not installed for repo")
	ErrInvalidRequest         = errors.New("github invalid request")
	ErrNotFound               = errors.New("github resource not found")
)

type DeviceCodeResponse struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURI string `json:"verification_uri"`
	ExpiresIn       int    `json:"expires_in"`
	Interval        int    `json:"interval"`
}

type TokenResponse struct {
	AccessToken           string `json:"access_token"`
	TokenType             string `json:"token_type"`
	Scope                 string `json:"scope"`
	RefreshToken          string `json:"refresh_token"`
	ExpiresIn             int    `json:"expires_in"`
	RefreshTokenExpiresIn int    `json:"refresh_token_expires_in"`
	Error                 string `json:"error"`
	ErrorDescription      string `json:"error_description"`
	ErrorURI              string `json:"error_uri"`
}

type User struct {
	Login     string `json:"login"`
	ID        int64  `json:"id"`
	AvatarURL string `json:"avatar_url,omitempty"`
	HTMLURL   string `json:"html_url,omitempty"`
}

type Repository struct {
	ID         int64  `json:"id,omitempty"`
	GitHubHost string `json:"github_host,omitempty"`
	Owner      string `json:"owner,omitempty"`
	Name       string `json:"name,omitempty"`
	FullName   string `json:"full_name,omitempty"`
	RemoteName string `json:"remote_name,omitempty"`
	RemoteURL  string `json:"remote_url,omitempty"`
	RepoRoot   string `json:"repo_root,omitempty"`
	Private    bool   `json:"private,omitempty"`
}

func (r *Repository) UnmarshalJSON(data []byte) error {
	type repositoryAlias Repository
	type repositoryOwner struct {
		Login string `json:"login"`
	}
	type repositoryWire struct {
		repositoryAlias
		Owner json.RawMessage `json:"owner"`
	}

	var payload repositoryWire
	if err := json.Unmarshal(data, &payload); err != nil {
		return err
	}

	*r = Repository(payload.repositoryAlias)
	if len(payload.Owner) == 0 || string(payload.Owner) == "null" {
		return nil
	}

	var owner string
	if err := json.Unmarshal(payload.Owner, &owner); err == nil {
		r.Owner = strings.TrimSpace(owner)
		return nil
	}

	var nestedOwner repositoryOwner
	if err := json.Unmarshal(payload.Owner, &nestedOwner); err == nil {
		r.Owner = strings.TrimSpace(nestedOwner.Login)
	}
	return nil
}

type AppInstallation struct {
	ID int64 `json:"id"`
}

type AuthRecord struct {
	GitHubHost            string    `json:"github_host"`
	AccessToken           string    `json:"access_token"`
	AccessTokenExpiresAt  time.Time `json:"access_token_expires_at"`
	RefreshToken          string    `json:"refresh_token"`
	RefreshTokenExpiresAt time.Time `json:"refresh_token_expires_at"`
	AccountLogin          string    `json:"account_login"`
	AccountID             int64     `json:"account_id"`
}

type AuthStatus struct {
	Authenticated         bool       `json:"authenticated"`
	GitHubHost            string     `json:"github_host"`
	AccountLogin          string     `json:"account_login,omitempty"`
	AccountID             int64      `json:"account_id,omitempty"`
	AccessTokenExpiresAt  *time.Time `json:"access_token_expires_at,omitempty"`
	RefreshTokenExpiresAt *time.Time `json:"refresh_token_expires_at,omitempty"`
	NeedsRefresh          bool       `json:"needs_refresh"`
	NeedsReauth           bool       `json:"needs_reauth"`
}

type PollResult struct {
	Status    string      `json:"status"`
	ErrorCode string      `json:"error_code,omitempty"`
	Message   string      `json:"message,omitempty"`
	Auth      *AuthStatus `json:"auth,omitempty"`
}

type CurrentRepoContext struct {
	Status     string      `json:"status"`
	ErrorCode  string      `json:"error_code,omitempty"`
	Repository *Repository `json:"repository,omitempty"`
	Auth       *AuthStatus `json:"auth,omitempty"`
	Message    string      `json:"message,omitempty"`
}

type Account struct {
	Login     string `json:"login"`
	ID        int64  `json:"id"`
	Name      string `json:"name,omitempty"`
	AvatarURL string `json:"avatar_url,omitempty"`
	HTMLURL   string `json:"html_url,omitempty"`
}

type Actor struct {
	Login     string `json:"login"`
	ID        int64  `json:"id"`
	AvatarURL string `json:"avatar_url,omitempty"`
	HTMLURL   string `json:"html_url,omitempty"`
}

type Label struct {
	Name  string `json:"name"`
	Color string `json:"color,omitempty"`
}

type PullRequestRef struct {
	Label string `json:"label,omitempty"`
	Ref   string `json:"ref,omitempty"`
	SHA   string `json:"sha,omitempty"`
}

type PullRequestChecks struct {
	State        string                `json:"state"`
	TotalCount   int                   `json:"total_count"`
	SuccessCount int                   `json:"success_count"`
	PendingCount int                   `json:"pending_count"`
	FailureCount int                   `json:"failure_count"`
	Checks       []PullRequestCheckRun `json:"checks"`
}

type PullRequestCheckRun struct {
	Name        string     `json:"name"`
	Status      string     `json:"status"`
	Conclusion  string     `json:"conclusion,omitempty"`
	DetailsURL  string     `json:"details_url,omitempty"`
	StartedAt   *time.Time `json:"started_at,omitempty"`
	CompletedAt *time.Time `json:"completed_at,omitempty"`
}

type Issue struct {
	Number        int        `json:"number"`
	Title         string     `json:"title"`
	State         string     `json:"state"`
	Body          string     `json:"body,omitempty"`
	HTMLURL       string     `json:"html_url,omitempty"`
	CommentsCount int        `json:"comments_count"`
	Locked        bool       `json:"locked"`
	Author        *Actor     `json:"author,omitempty"`
	Assignees     []Actor    `json:"assignees,omitempty"`
	Labels        []Label    `json:"labels,omitempty"`
	CreatedAt     *time.Time `json:"created_at,omitempty"`
	UpdatedAt     *time.Time `json:"updated_at,omitempty"`
	ClosedAt      *time.Time `json:"closed_at,omitempty"`
}

type IssueComment struct {
	ID        int64      `json:"id"`
	Body      string     `json:"body"`
	HTMLURL   string     `json:"html_url,omitempty"`
	Author    *Actor     `json:"author,omitempty"`
	CreatedAt *time.Time `json:"created_at,omitempty"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
}

type PullRequest struct {
	Number              int                `json:"number"`
	Title               string             `json:"title"`
	State               string             `json:"state"`
	Body                string             `json:"body,omitempty"`
	HTMLURL             string             `json:"html_url,omitempty"`
	Draft               bool               `json:"draft"`
	Merged              bool               `json:"merged"`
	Mergeable           *bool              `json:"mergeable,omitempty"`
	MergeableState      string             `json:"mergeable_state,omitempty"`
	CommentsCount       int                `json:"comments_count"`
	ReviewCommentsCount int                `json:"review_comments_count"`
	CommitsCount        int                `json:"commits_count"`
	Additions           int                `json:"additions"`
	Deletions           int                `json:"deletions"`
	ChangedFiles        int                `json:"changed_files"`
	Author              *Actor             `json:"author,omitempty"`
	Assignees           []Actor            `json:"assignees,omitempty"`
	Labels              []Label            `json:"labels,omitempty"`
	BaseRef             PullRequestRef     `json:"base_ref"`
	HeadRef             PullRequestRef     `json:"head_ref"`
	CreatedAt           *time.Time         `json:"created_at,omitempty"`
	UpdatedAt           *time.Time         `json:"updated_at,omitempty"`
	ClosedAt            *time.Time         `json:"closed_at,omitempty"`
	MergedAt            *time.Time         `json:"merged_at,omitempty"`
	Checks              *PullRequestChecks `json:"checks,omitempty"`
}

type PullRequestFile struct {
	SHA              string `json:"sha,omitempty"`
	Filename         string `json:"filename"`
	Status           string `json:"status"`
	Additions        int    `json:"additions"`
	Deletions        int    `json:"deletions"`
	Changes          int    `json:"changes"`
	BlobURL          string `json:"blob_url,omitempty"`
	RawURL           string `json:"raw_url,omitempty"`
	Patch            string `json:"patch,omitempty"`
	PreviousFilename string `json:"previous_filename,omitempty"`
}

type PullRequestComment struct {
	ID               int64      `json:"id"`
	Body             string     `json:"body"`
	HTMLURL          string     `json:"html_url,omitempty"`
	Path             string     `json:"path,omitempty"`
	DiffHunk         string     `json:"diff_hunk,omitempty"`
	CommitID         string     `json:"commit_id,omitempty"`
	OriginalCommitID string     `json:"original_commit_id,omitempty"`
	Position         int        `json:"position,omitempty"`
	OriginalPosition int        `json:"original_position,omitempty"`
	Line             int        `json:"line,omitempty"`
	OriginalLine     int        `json:"original_line,omitempty"`
	Side             string     `json:"side,omitempty"`
	StartLine        int        `json:"start_line,omitempty"`
	StartSide        string     `json:"start_side,omitempty"`
	InReplyToID      int64      `json:"in_reply_to_id,omitempty"`
	Author           *Actor     `json:"author,omitempty"`
	CreatedAt        *time.Time `json:"created_at,omitempty"`
	UpdatedAt        *time.Time `json:"updated_at,omitempty"`
}

type PullRequestReview struct {
	ID          int64      `json:"id"`
	Body        string     `json:"body,omitempty"`
	State       string     `json:"state,omitempty"`
	CommitID    string     `json:"commit_id,omitempty"`
	HTMLURL     string     `json:"html_url,omitempty"`
	Author      *Actor     `json:"author,omitempty"`
	SubmittedAt *time.Time `json:"submitted_at,omitempty"`
}

type IssueListOptions struct {
	State     string
	Sort      string
	Direction string
	Since     string
	Labels    string
	Creator   string
	Mentioned string
	Assignee  string
	Milestone string
	Page      int
	PerPage   int
}

type PullRequestListOptions struct {
	State     string
	Head      string
	Base      string
	Sort      string
	Direction string
	Page      int
	PerPage   int
}

type ListOptions struct {
	Sort      string
	Direction string
	Since     string
	Page      int
	PerPage   int
}

type CreateIssueCommentInput struct {
	Body string `json:"body"`
}

type CreatePullRequestCommentInput struct {
	Body      string `json:"body"`
	Path      string `json:"path,omitempty"`
	CommitID  string `json:"commit_id,omitempty"`
	Side      string `json:"side,omitempty"`
	StartSide string `json:"start_side,omitempty"`
	Line      int    `json:"line,omitempty"`
	StartLine int    `json:"start_line,omitempty"`
	InReplyTo int64  `json:"in_reply_to,omitempty"`
}

type PullRequestReviewDraftComment struct {
	Body      string `json:"body"`
	Path      string `json:"path,omitempty"`
	Side      string `json:"side,omitempty"`
	StartSide string `json:"start_side,omitempty"`
	Line      int    `json:"line,omitempty"`
	StartLine int    `json:"start_line,omitempty"`
}

type CreatePullRequestReviewInput struct {
	Event    string                          `json:"event,omitempty"`
	Body     string                          `json:"body,omitempty"`
	CommitID string                          `json:"commit_id,omitempty"`
	Comments []PullRequestReviewDraftComment `json:"comments,omitempty"`
}

type HostError struct {
	Host string
	Err  error
}

func (e *HostError) Error() string {
	if e == nil {
		return ""
	}
	if e.Host == "" {
		return e.Err.Error()
	}
	return e.Host + ": " + e.Err.Error()
}

func (e *HostError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

func NormalizeHost(host string) string {
	host = strings.TrimSpace(strings.ToLower(host))
	if host == "" {
		return DefaultHost
	}
	host = strings.TrimPrefix(host, "https://")
	host = strings.TrimPrefix(host, "http://")
	host = strings.TrimSuffix(host, "/")
	return host
}

func BuildAuthStatus(record *AuthRecord, now time.Time, refreshThreshold time.Duration) AuthStatus {
	if record == nil {
		return AuthStatus{}
	}
	accessExpiry := record.AccessTokenExpiresAt
	refreshExpiry := record.RefreshTokenExpiresAt
	needsRefresh := !accessExpiry.IsZero() && !accessExpiry.After(now.Add(refreshThreshold))
	needsReauth := record.RefreshToken == "" || (!refreshExpiry.IsZero() && !refreshExpiry.After(now))
	return AuthStatus{
		Authenticated:         true,
		GitHubHost:            record.GitHubHost,
		AccountLogin:          record.AccountLogin,
		AccountID:             record.AccountID,
		AccessTokenExpiresAt:  optionalTime(accessExpiry),
		RefreshTokenExpiresAt: optionalTime(refreshExpiry),
		NeedsRefresh:          needsRefresh,
		NeedsReauth:           needsReauth,
	}
}

func optionalTime(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	v := t.UTC()
	return &v
}

func ErrorCode(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, ErrAuthorizationPending):
		return "authorization_pending"
	case errors.Is(err, ErrSlowDown):
		return "slow_down"
	case errors.Is(err, ErrAccessDenied):
		return "access_denied"
	case errors.Is(err, ErrExpiredToken):
		return "expired_token"
	case errors.Is(err, ErrBadRefreshToken):
		return "bad_refresh_token"
	case errors.Is(err, ErrRefreshNotSupported):
		return "refresh_not_supported"
	case errors.Is(err, ErrReauthRequired):
		return "reauth_required"
	case errors.Is(err, ErrNotAuthenticated):
		return "not_authenticated"
	case errors.Is(err, ErrRepoNotGitHub):
		return "repo_not_github"
	case errors.Is(err, ErrRepoAccessUnavailable):
		return "repo_access_unavailable"
	case errors.Is(err, ErrAppNotInstalledForRepo):
		return "app_not_installed_for_repo"
	case errors.Is(err, ErrInvalidRequest):
		return "invalid_request"
	case errors.Is(err, ErrNotFound):
		return "not_found"
	default:
		return "github_auth_error"
	}
}

func IsAPIStatus(err error, statusCode int) bool {
	var apiErr *APIError
	if errors.As(err, &apiErr) {
		return apiErr.StatusCode == statusCode
	}
	var hostErr *HostError
	if errors.As(err, &hostErr) {
		return IsAPIStatus(hostErr.Err, statusCode)
	}
	return false
}
