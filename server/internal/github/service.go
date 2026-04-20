package github

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
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
