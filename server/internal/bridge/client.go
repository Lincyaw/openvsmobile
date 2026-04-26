package bridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Error wraps an HTTP failure from the bridge so callers can inspect status
// codes and structured error payloads.
type Error struct {
	Status int    `json:"-"`
	Code   string `json:"error"`
	Detail string `json:"detail"`
}

func (e *Error) Error() string {
	if e == nil {
		return "<nil bridge error>"
	}
	if e.Detail != "" {
		return fmt.Sprintf("bridge: %s (status=%d): %s", e.Code, e.Status, e.Detail)
	}
	if e.Code != "" {
		return fmt.Sprintf("bridge: %s (status=%d)", e.Code, e.Status)
	}
	return fmt.Sprintf("bridge: status=%d", e.Status)
}

// Client talks to the openvsmobile-bridge VS Code extension over loopback HTTP.
// Construct one per process and share it.
type Client struct {
	cache *runtimeCache
	http  *http.Client
}

// NewClient returns a Client that uses the default runtime-info path resolution
// (env var override + ~/.config/openvscode-mobile/bridge-runtime.json).
func NewClient() *Client {
	return NewClientWithPath("")
}

// NewClientWithPath returns a Client that reads the runtime-info file from
// `path`. An empty `path` falls back to ResolveInfoPath().
func NewClientWithPath(path string) *Client {
	return &Client{
		cache: newRuntimeCache(path),
		http: &http.Client{
			Timeout: 30 * time.Second,
			Transport: &http.Transport{
				MaxIdleConns:        16,
				MaxIdleConnsPerHost: 4,
				IdleConnTimeout:     30 * time.Second,
			},
		},
	}
}

// SetHTTPClient swaps the underlying HTTP client. Useful for tests that want
// to disable timeouts or add tracing transports.
func (c *Client) SetHTTPClient(client *http.Client) {
	if client != nil {
		c.http = client
	}
}

// RuntimeInfo returns the cached runtime info, refreshing it if the file's
// modification time has changed.
func (c *Client) RuntimeInfo() (RuntimeInfo, error) {
	return c.cache.Get()
}

// Available reports whether the runtime-info file is currently readable. It
// does NOT verify that the extension's HTTP server is actually responsive;
// that determination is left to the per-call connection attempt.
func (c *Client) Available() bool {
	_, err := c.cache.Get()
	return err == nil
}

// Get sends a GET against the bridge.
func (c *Client) Get(ctx context.Context, p string, query url.Values, out any) error {
	return c.do(ctx, http.MethodGet, p, query, nil, out)
}

// Post sends a POST against the bridge with a JSON body.
func (c *Client) Post(ctx context.Context, p string, body any, out any) error {
	return c.do(ctx, http.MethodPost, p, nil, body, out)
}

func (c *Client) do(ctx context.Context, method, p string, query url.Values, body any, out any) error {
	info, err := c.cache.Get()
	if err != nil {
		return err
	}

	target := info.BaseURL() + p
	if len(query) > 0 {
		target += "?" + query.Encode()
	}

	var reqBody io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("bridge: encode request body: %w", err)
		}
		reqBody = bytes.NewReader(raw)
	}

	req, err := http.NewRequestWithContext(ctx, method, target, reqBody)
	if err != nil {
		return fmt.Errorf("bridge: build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+info.Token)
	if reqBody != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		// Connection-level failure usually means the extension restarted
		// or moved port. Invalidate the cache so the next call re-reads
		// the runtime-info file.
		if isConnError(err) {
			c.cache.Invalidate()
			return fmt.Errorf("%w: %v", ErrBridgeUnavailable, err)
		}
		return fmt.Errorf("bridge: send request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("bridge: read response: %w", err)
	}

	if resp.StatusCode >= 400 {
		bridgeErr := &Error{Status: resp.StatusCode}
		if len(respBody) > 0 {
			_ = json.Unmarshal(respBody, bridgeErr)
		}
		if bridgeErr.Code == "" {
			bridgeErr.Code = http.StatusText(resp.StatusCode)
		}
		return bridgeErr
	}

	if out == nil || len(respBody) == 0 {
		return nil
	}
	if err := json.Unmarshal(respBody, out); err != nil {
		return fmt.Errorf("bridge: decode response: %w", err)
	}
	return nil
}

func isConnError(err error) bool {
	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	// Generic dial errors and EOFs we want to treat as bridge-unavailable.
	msg := err.Error()
	return strings.Contains(msg, "connection refused") ||
		strings.Contains(msg, "EOF") ||
		strings.Contains(msg, "no such file") ||
		strings.Contains(msg, "broken pipe") ||
		strings.Contains(msg, "connection reset")
}
