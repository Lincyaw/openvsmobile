# GitHub Auth Backend

This project ships a Go-server auth foundation for GitHub App device flow.
The server owns the GitHub user tokens; the Flutter client only receives
non-secret status metadata plus the short-lived device flow values needed to
complete authorization.

## Endpoints

All routes are available with or without the `/api` prefix:

- `POST /github/auth/device/start`
- `POST /github/auth/device/poll`
- `GET /github/auth/status`
- `POST /github/auth/disconnect`

### `POST /github/auth/device/start`

Request body:

```json
{
  "github_host": "github.com"
}
```

Response body:

```json
{
  "github_host": "github.com",
  "device_code": "...",
  "user_code": "ABCD-EFGH",
  "verification_uri": "https://github.com/login/device",
  "expires_in": 900,
  "interval": 5
}
```

`device_code` is intentionally returned to the caller so the client can poll,
but it is not persisted by the Flutter app and must not be logged.

### `POST /github/auth/device/poll`

Request body:

```json
{
  "github_host": "github.com",
  "device_code": "..."
}
```

Possible responses:

- `{"status":"pending"}` while GitHub authorization is still in progress
- `{"status":"authorized","auth":{...}}` once the server has exchanged,
  validated, and persisted the token set
- `{"status":"error","error_code":"access_denied","message":"..."}`
  when the device flow must stop or the client should re-prompt the user

The server constrains poll statuses to `pending`, `authorized`, or `error`.

### `GET /github/auth/status`

Query string:

- `github_host` (optional; defaults to the configured default host)

Response body:

```json
{
  "authenticated": true,
  "github_host": "github.com",
  "account_login": "octocat",
  "account_id": 9,
  "access_token_expires_at": "2026-04-20T12:05:00Z",
  "refresh_token_expires_at": "2026-04-20T13:00:00Z",
  "needs_refresh": false,
  "needs_reauth": false
}
```

The response never includes `access_token` or `refresh_token`.

Current contract note: the status payload does not yet expose avatar URLs, GitHub App installation state, or per-workspace repository accessibility metadata. Flutter clients must present those as unavailable/unsupported instead of guessing.

### `POST /github/auth/disconnect`

Request body:

```json
{
  "github_host": "github.com"
}
```

Response body:

```json
{
  "disconnected": true,
  "github_host": "github.com"
}
```

Disconnect clears the persisted auth record for that host.

## Server configuration

The auth service is enabled when the Go server is started with
`-github-client-id`. Optional flags:

- `-github-host`: default GitHub host, defaults to `github.com`
- `-github-auth-store`: JSON file used for persisted auth state
- `-github-refresh-threshold`: how early the server refreshes access tokens

Example:

```bash
cd server

go run ./cmd/server \
  -github-client-id "$GITHUB_APP_CLIENT_ID" \
  -github-host github.com \
  -github-auth-store "$HOME/.claude/github-auth.json" \
  -github-refresh-threshold 5m
```

## Persistence and refresh behavior

The server stores one auth session per `github_host` in an atomically rewritten
JSON file. Each record includes:

- `access_token`
- `access_token_expires_at`
- `refresh_token`
- `refresh_token_expires_at`
- `account_login`
- `account_id`
- `github_host`

Before a token-backed GitHub API call runs, the server calls the shared refresh
preflight. If refresh succeeds, the record is replaced atomically. If refresh
fails because the refresh token is invalid or expired, callers receive a
structured `reauth_required` error so the client can restart device flow.
