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
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.apiBaseURL(host)+"/user", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Authorization", "Bearer "+accessToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, &HostError{Host: NormalizeHost(host), Err: err}
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, &HostError{Host: NormalizeHost(host), Err: fmt.Errorf("github user lookup failed: status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))}
	}

	var user User
	if err := json.NewDecoder(resp.Body).Decode(&user); err != nil {
		return nil, &HostError{Host: NormalizeHost(host), Err: fmt.Errorf("decode github user: %w", err)}
	}
	return &user, nil
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
