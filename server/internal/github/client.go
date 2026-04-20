package github

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"
)

type Client struct {
	httpClient *http.Client
	webBaseURL func(string) string
	apiBaseURL func(string) string
}

func NewClient(httpClient *http.Client) *Client {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 15 * time.Second}
	}
	return &Client{httpClient: httpClient, webBaseURL: webBaseURL, apiBaseURL: apiBaseURL}
}

func (c *Client) SetBaseURLFuncs(webBaseURLFn, apiBaseURLFn func(string) string) {
	if webBaseURLFn != nil {
		c.webBaseURL = webBaseURLFn
	}
	if apiBaseURLFn != nil {
		c.apiBaseURL = apiBaseURLFn
	}
}

func (c *Client) StartDeviceFlow(ctx context.Context, host, clientID string) (*DeviceCodeResponse, error) {
	values := url.Values{}
	values.Set("client_id", clientID)

	var resp DeviceCodeResponse
	if err := c.postForm(ctx, c.webBaseURL(host)+"/login/device/code", values, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (c *Client) ExchangeDeviceCode(ctx context.Context, host, clientID, deviceCode string) (*TokenResponse, error) {
	values := url.Values{}
	values.Set("client_id", clientID)
	values.Set("device_code", deviceCode)
	values.Set("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
	return c.exchangeToken(ctx, host, values)
}

func (c *Client) RefreshToken(ctx context.Context, host, clientID, refreshToken string) (*TokenResponse, error) {
	values := url.Values{}
	values.Set("client_id", clientID)
	values.Set("grant_type", "refresh_token")
	values.Set("refresh_token", refreshToken)
	return c.exchangeToken(ctx, host, values)
}

func (c *Client) GetUser(ctx context.Context, host, accessToken string) (*User, error) {
	var user User
	if err := c.getJSON(ctx, c.apiBaseURL(host)+"/user", accessToken, &user); err != nil {
		if apiErr, ok := err.(*APIError); ok {
			return nil, &HostError{Host: NormalizeHost(host), Err: apiErr}
		}
		return nil, err
	}
	return &user, nil
}

func (c *Client) GetRepo(ctx context.Context, host, owner, repo, accessToken string) (*Repository, error) {
	var repository Repository
	endpoint := c.apiBaseURL(host) + "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(repo)
	if err := c.getJSON(ctx, endpoint, accessToken, &repository); err != nil {
		return nil, err
	}
	repository.GitHubHost = NormalizeHost(host)
	if repository.Owner == "" {
		repository.Owner = owner
	}
	if repository.Name == "" {
		repository.Name = repo
	}
	if repository.FullName == "" && repository.Owner != "" && repository.Name != "" {
		repository.FullName = repository.Owner + "/" + repository.Name
	}
	return &repository, nil
}

func (c *Client) GetRepoInstallation(ctx context.Context, host, owner, repo, accessToken string) (*AppInstallation, error) {
	var installation AppInstallation
	endpoint := c.apiBaseURL(host) + "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(repo) + "/installation"
	if err := c.getJSON(ctx, endpoint, accessToken, &installation); err != nil {
		if IsAPIStatus(err, http.StatusNotFound) {
			return nil, &HostError{Host: NormalizeHost(host), Err: ErrAppNotInstalledForRepo}
		}
		if IsAPIStatus(err, http.StatusForbidden) {
			return nil, &HostError{Host: NormalizeHost(host), Err: ErrRepoAccessUnavailable}
		}
		return nil, err
	}
	return &installation, nil
}

func (c *Client) exchangeToken(ctx context.Context, host string, values url.Values) (*TokenResponse, error) {
	var resp TokenResponse
	if err := c.postForm(ctx, c.webBaseURL(host)+"/login/oauth/access_token", values, &resp); err != nil {
		return nil, err
	}
	if resp.Error != "" {
		return nil, &HostError{Host: NormalizeHost(host), Err: mapOAuthError(resp.Error)}
	}
	return &resp, nil
}

func (c *Client) getJSON(ctx context.Context, endpoint, accessToken string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	if strings.TrimSpace(accessToken) != "" {
		req.Header.Set("Authorization", "Bearer "+accessToken)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return &HostError{Host: NormalizeHost(hostFromURL(endpoint)), Err: err}
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return &APIError{Host: NormalizeHost(hostFromURL(endpoint)), StatusCode: resp.StatusCode, Message: strings.TrimSpace(string(body))}
	}

	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return &HostError{Host: NormalizeHost(hostFromURL(endpoint)), Err: fmt.Errorf("decode github response: %w", err)}
	}
	return nil
}

func (c *Client) postForm(ctx context.Context, endpoint string, values url.Values, out any) error {
	body := bytes.NewBufferString(values.Encode())
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, body)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return &HostError{Host: NormalizeHost(hostFromURL(endpoint)), Err: err}
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		payload, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return &HostError{Host: NormalizeHost(hostFromURL(endpoint)), Err: fmt.Errorf("github auth request failed: status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(payload)))}
	}

	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return &HostError{Host: NormalizeHost(hostFromURL(endpoint)), Err: fmt.Errorf("decode github auth response: %w", err)}
	}
	return nil
}

func mapOAuthError(code string) error {
	switch code {
	case "authorization_pending":
		return ErrAuthorizationPending
	case "slow_down":
		return ErrSlowDown
	case "access_denied":
		return ErrAccessDenied
	case "expired_token":
		return ErrExpiredToken
	case "bad_verification_code", "bad_refresh_token", "incorrect_client_credentials":
		return ErrBadRefreshToken
	default:
		return fmt.Errorf("github oauth error: %s", code)
	}
}

func webBaseURL(host string) string {
	return "https://" + NormalizeHost(host)
}

func apiBaseURL(host string) string {
	normalized := NormalizeHost(host)
	if normalized == DefaultHost {
		return "https://api.github.com"
	}
	return webBaseURL(normalized) + "/api/v3"
}

func hostFromURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	if parsed.Path != "" {
		parsed.Path = path.Clean(parsed.Path)
	}
	return parsed.Host
}
