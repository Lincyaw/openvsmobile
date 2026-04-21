package github

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	gitctx "github.com/Lincyaw/vscode-mobile/server/internal/git"
)

type Service struct {
	client           *Client
	store            *Store
	clientID         string
	defaultHost      string
	refreshThreshold time.Duration
	now              func() time.Time
}

func NewService(client *Client, store *Store, clientID, defaultHost string, refreshThreshold time.Duration) *Service {
	if refreshThreshold <= 0 {
		refreshThreshold = 5 * time.Minute
	}
	return &Service{
		client:           client,
		store:            store,
		clientID:         clientID,
		defaultHost:      NormalizeHost(defaultHost),
		refreshThreshold: refreshThreshold,
		now:              time.Now,
	}
}

func (s *Service) SetNow(now func() time.Time) {
	if now != nil {
		s.now = now
	}
}

func (s *Service) ResolveHost(host string) string {
	return s.host(host)
}

func (s *Service) StartDeviceFlow(ctx context.Context, host string) (*DeviceCodeResponse, error) {
	return s.client.StartDeviceFlow(ctx, s.host(host), s.clientID)
}

func (s *Service) PollDeviceFlow(ctx context.Context, host, deviceCode string) (*PollResult, error) {
	host = s.host(host)
	resp, err := s.client.ExchangeDeviceCode(ctx, host, s.clientID, deviceCode)
	if err != nil {
		switch {
		case errors.Is(err, ErrAuthorizationPending), errors.Is(err, ErrSlowDown):
			return &PollResult{Status: "pending"}, nil
		case errors.Is(err, ErrAccessDenied), errors.Is(err, ErrExpiredToken), errors.Is(err, ErrBadRefreshToken), errors.Is(err, ErrRefreshNotSupported):
			return &PollResult{Status: "error", ErrorCode: ErrorCode(err), Message: err.Error()}, nil
		default:
			return nil, err
		}
	}

	now := s.now().UTC()
	record := AuthRecord{
		GitHubHost:            host,
		AccessToken:           resp.AccessToken,
		AccessTokenExpiresAt:  now.Add(time.Duration(resp.ExpiresIn) * time.Second),
		RefreshToken:          resp.RefreshToken,
		RefreshTokenExpiresAt: now.Add(time.Duration(resp.RefreshTokenExpiresIn) * time.Second),
	}
	if err := validateTokenRecord(record); err != nil {
		return &PollResult{Status: "error", ErrorCode: ErrorCode(err), Message: err.Error()}, nil
	}

	user, err := s.client.GetUser(ctx, host, record.AccessToken)
	if err != nil {
		return nil, err
	}
	record.AccountLogin = user.Login
	record.AccountID = user.ID

	if err := s.store.Save(record); err != nil {
		return nil, err
	}
	status := BuildAuthStatus(&record, now, s.refreshThreshold)
	return &PollResult{Status: "authorized", Auth: &status}, nil
}

func (s *Service) GetStatus(_ context.Context, host string) (*AuthStatus, error) {
	record, err := s.store.Load(s.host(host))
	if err != nil {
		return nil, err
	}
	status := BuildAuthStatus(record, s.now().UTC(), s.refreshThreshold)
	status.GitHubHost = s.host(host)
	return &status, nil
}

func (s *Service) Disconnect(_ context.Context, host string) error {
	return s.store.Delete(s.host(host))
}

func (s *Service) EnsureFreshToken(ctx context.Context, host string) (*AuthRecord, error) {
	host = s.host(host)
	record, err := s.store.Load(host)
	if err != nil {
		return nil, err
	}
	if record == nil {
		return nil, ErrNotAuthenticated
	}
	now := s.now().UTC()
	if record.AccessToken != "" && (record.AccessTokenExpiresAt.IsZero() || record.AccessTokenExpiresAt.After(now.Add(s.refreshThreshold))) {
		return record, nil
	}
	if record.RefreshToken == "" || (!record.RefreshTokenExpiresAt.IsZero() && !record.RefreshTokenExpiresAt.After(now)) {
		return nil, ErrReauthRequired
	}

	resp, err := s.client.RefreshToken(ctx, host, s.clientID, record.RefreshToken)
	if err != nil {
		if errors.Is(err, ErrBadRefreshToken) {
			return nil, ErrReauthRequired
		}
		return nil, err
	}
	next := *record
	next.AccessToken = resp.AccessToken
	next.AccessTokenExpiresAt = now.Add(time.Duration(resp.ExpiresIn) * time.Second)
	if resp.RefreshToken != "" {
		next.RefreshToken = resp.RefreshToken
	}
	if resp.RefreshTokenExpiresIn > 0 {
		next.RefreshTokenExpiresAt = now.Add(time.Duration(resp.RefreshTokenExpiresIn) * time.Second)
	}
	if err := validateTokenRecord(next); err != nil {
		if errors.Is(err, ErrRefreshNotSupported) {
			return nil, ErrReauthRequired
		}
		return nil, err
	}
	if err := s.store.Save(next); err != nil {
		return nil, err
	}
	return &next, nil
}

func (s *Service) GetUser(ctx context.Context, host string) (*User, error) {
	record, err := s.EnsureFreshToken(ctx, host)
	if err != nil {
		return nil, err
	}
	return s.client.GetUser(ctx, record.GitHubHost, record.AccessToken)
}

func (s *Service) ProbeCurrentRepo(ctx context.Context, gitClient *gitctx.Git, path string) (*CurrentRepoContext, error) {
	if gitClient == nil {
		return nil, fmt.Errorf("git client is not configured")
	}

	repoContext, err := gitClient.ResolveRepoContext(path)
	if err != nil {
		repository := &Repository{}
		if repoContext != nil {
			repository.RepoRoot = repoContext.RepoRoot
		}
		switch {
		case errors.Is(err, gitctx.ErrNotRepository), errors.Is(err, gitctx.ErrNoRemote), errors.Is(err, gitctx.ErrRepoNotGitHub):
			return &CurrentRepoContext{
				Status:     RepoStatusRepoNotGitHub,
				ErrorCode:  RepoStatusRepoNotGitHub,
				Repository: repository,
				Message:    err.Error(),
			}, nil
		default:
			return nil, err
		}
	}
	return s.ProbeRepository(ctx, &Repository{
		GitHubHost: repoContext.GitHubHost,
		Owner:      repoContext.Owner,
		Name:       repoContext.Name,
		FullName:   repoContext.FullName,
		RemoteName: repoContext.RemoteName,
		RemoteURL:  repoContext.RemoteURL,
		RepoRoot:   repoContext.RepoRoot,
	})
}

func (s *Service) ProbeRepository(ctx context.Context, repository *Repository) (*CurrentRepoContext, error) {
	if repository == nil {
		return nil, fmt.Errorf("repository is required")
	}

	result := &CurrentRepoContext{
		Status:     RepoStatusNotAuthenticated,
		ErrorCode:  RepoStatusNotAuthenticated,
		Repository: repository,
		Auth: &AuthStatus{
			Authenticated: false,
			GitHubHost:    repository.GitHubHost,
		},
	}
	if !strings.Contains(repository.GitHubHost, "github") {
		result.Status = RepoStatusRepoNotGitHub
		result.ErrorCode = RepoStatusRepoNotGitHub
		result.Message = "remote host is not GitHub"
		return result, nil
	}
	if s == nil {
		return result, nil
	}

	status, err := s.GetStatus(ctx, repository.GitHubHost)
	if err != nil {
		return nil, err
	}
	status.GitHubHost = repository.GitHubHost
	result.Auth = status

	record, err := s.EnsureFreshToken(ctx, repository.GitHubHost)
	switch {
	case errors.Is(err, ErrNotAuthenticated):
		result.ErrorCode = RepoStatusNotAuthenticated
		return result, nil
	case errors.Is(err, ErrReauthRequired):
		result.Status = RepoStatusReauthRequired
		result.ErrorCode = RepoStatusReauthRequired
		if result.Auth != nil {
			result.Auth.NeedsReauth = true
		}
		return result, nil
	case err != nil:
		return nil, err
	}

	freshStatus := BuildAuthStatus(record, s.now().UTC(), s.refreshThreshold)
	freshStatus.GitHubHost = repository.GitHubHost
	result.Auth = &freshStatus

	repoDetails, err := s.client.GetRepo(ctx, repository.GitHubHost, repository.Owner, repository.Name, record.AccessToken)
	if err != nil {
		switch {
		case IsAPIStatus(err, http.StatusNotFound), IsAPIStatus(err, http.StatusForbidden), errors.Is(err, ErrRepoAccessUnavailable):
			result.Status = RepoStatusRepoAccessUnavailable
			result.ErrorCode = RepoStatusRepoAccessUnavailable
			result.Message = "repository access is unavailable for the authenticated account"
			return result, nil
		}
		var apiErr *APIError
		if errors.As(err, &apiErr) {
			result.Status = RepoStatusRepoAccessUnavailable
			result.ErrorCode = RepoStatusRepoAccessUnavailable
			result.Message = apiErr.Message
			return result, nil
		}
		return nil, err
	}

	if _, err := s.client.GetRepoInstallation(ctx, repository.GitHubHost, repository.Owner, repository.Name, record.AccessToken); err != nil {
		switch {
		case errors.Is(err, ErrAppNotInstalledForRepo):
			result.Status = RepoStatusAppNotInstalled
			result.ErrorCode = RepoStatusAppNotInstalled
			result.Repository = mergeRepositoryContext(repository, repoDetails)
			result.Message = "GitHub App is not installed for this repository"
			return result, nil
		case errors.Is(err, ErrRepoAccessUnavailable), IsAPIStatus(err, http.StatusForbidden):
			result.Status = RepoStatusRepoAccessUnavailable
			result.ErrorCode = RepoStatusRepoAccessUnavailable
			result.Repository = mergeRepositoryContext(repository, repoDetails)
			result.Message = "repository access is unavailable for the authenticated account"
			return result, nil
		default:
			return nil, err
		}
	}

	result.Status = RepoStatusOK
	result.ErrorCode = ""
	result.Repository = mergeRepositoryContext(repository, repoDetails)
	return result, nil
}

func mergeRepositoryContext(base, details *Repository) *Repository {
	if base == nil && details == nil {
		return nil
	}
	if base == nil {
		return details
	}
	if details == nil {
		return base
	}
	merged := *base
	if details.GitHubHost != "" {
		merged.GitHubHost = details.GitHubHost
	}
	if details.Owner != "" {
		merged.Owner = details.Owner
	}
	if details.Name != "" {
		merged.Name = details.Name
	}
	if details.FullName != "" {
		merged.FullName = details.FullName
	}
	merged.Private = details.Private
	return &merged
}

func (s *Service) host(host string) string {
	if strings.TrimSpace(host) == "" {
		if s.defaultHost != "" {
			return s.defaultHost
		}
		return DefaultHost
	}
	return NormalizeHost(host)
}

func validateTokenRecord(record AuthRecord) error {
	if record.AccessToken == "" {
		return fmt.Errorf("missing access token")
	}
	if record.RefreshToken == "" || record.AccessTokenExpiresAt.IsZero() || record.RefreshTokenExpiresAt.IsZero() {
		return ErrRefreshNotSupported
	}
	return nil
}
