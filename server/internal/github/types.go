package github

import (
	"errors"
	"strings"
	"time"
)

const DefaultHost = "github.com"

const (
	RepoStatusOK                   = "ok"
	RepoStatusRepoNotGitHub        = "repo_not_github"
	RepoStatusNotAuthenticated     = "not_authenticated"
	RepoStatusReauthRequired       = "reauth_required"
	RepoStatusRepoAccessUnavailable = "repo_access_unavailable"
	RepoStatusAppNotInstalled      = "app_not_installed_for_repo"
)

var (
	ErrAuthorizationPending = errors.New("github authorization pending")
	ErrSlowDown             = errors.New("github authorization slow down")
	ErrAccessDenied         = errors.New("github access denied")
	ErrExpiredToken         = errors.New("github device code expired")
	ErrBadRefreshToken      = errors.New("github bad refresh token")
	ErrRefreshNotSupported  = errors.New("github refresh token support is required")
	ErrReauthRequired       = errors.New("github reauthorization required")
	ErrNotAuthenticated     = errors.New("github not authenticated")
	ErrRepoAccessUnavailable = errors.New("github repo access unavailable")
	ErrAppNotInstalledForRepo = errors.New("github app not installed for repo")
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
	Login string `json:"login"`
	ID    int64  `json:"id"`
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
	case errors.Is(err, ErrRepoAccessUnavailable):
		return "repo_access_unavailable"
	case errors.Is(err, ErrAppNotInstalledForRepo):
		return "app_not_installed_for_repo"
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
