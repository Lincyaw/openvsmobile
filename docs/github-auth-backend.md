# GitHub Auth Backend

This project ships a Go-server auth foundation for GitHub App device flow plus
workspace-aware repository context endpoints. The server owns the GitHub user
tokens; the Flutter client only receives non-secret status metadata plus the
short-lived device flow values needed to complete authorization.

## Endpoints

All routes are available with or without the `/api` prefix:

- `GET /github/repos/current`
- `POST /github/resolve-local-file`
- `POST /github/auth/device/start`
- `POST /github/auth/device/poll`
- `GET /github/auth/status`
- `POST /github/auth/disconnect`
- `GET /github/account`
- `GET /github/issues`
- `GET /github/issues/{number}`
- `POST /github/issues/{number}/comments`
- `GET /github/pulls`
- `GET /github/pulls/{number}`
- `GET /github/pulls/{number}/files`
- `GET /github/pulls/{number}/comments`
- `POST /github/pulls/{number}/comments`
- `POST /github/pulls/{number}/reviews`

### `GET /github/repos/current`

Derives the current repository identity from the server workspace git remote.
The backend prefers `origin` when multiple remotes exist and supports both
HTTPS and SSH remote formats.

Example response for an authenticated, accessible repo:

```json
{
  "status": "ok",
  "repository": {
    "github_host": "github.com",
    "owner": "octo-org",
    "name": "mobile-app",
    "full_name": "octo-org/mobile-app",
    "remote_name": "origin",
    "remote_url": "git@github.com:octo-org/mobile-app.git",
    "repo_root": "/workspace/mobile-app",
    "private": true
  },
  "auth": {
    "authenticated": true,
    "github_host": "github.com",
    "account_login": "octocat",
    "account_id": 9,
    "access_token_expires_at": "2026-04-20T12:05:00Z",
    "refresh_token_expires_at": "2026-04-20T13:00:00Z",
    "needs_refresh": false,
    "needs_reauth": false
  }
}
```

Possible `status` values:

- `ok`: repo identity was derived and the authenticated account can probe it
- `repo_not_github`: the workspace is not a git repo, has no remote, or the preferred remote is not GitHub
- `not_authenticated`: repo identity was derived but no GitHub auth session is available
- `reauth_required`: a stored session exists but refresh is required before repo probing
- `repo_access_unavailable`: the repo identity was derived but GitHub rejected repo access
- `app_not_installed_for_repo`: the current repo resolved locally but the GitHub App is not installed for it

`repository` is still returned for all of the statuses above when local git
resolution succeeds, so the client can continue showing owner/name metadata.

### `POST /github/resolve-local-file`

Request body:

```json
{
  "workspace_path": "/workspace/mobile-app",
  "path": "docs/notes.md"
}
```

`workspace_path` is optional and defaults to the server work dir. `path` may
also be sent as `relative_path`.

This endpoint resolves a local workspace path against the current repository
root. It rejects traversal attempts, never escapes the repo root, and returns
`exists: false` instead of an error when the target path is missing.

Example response:

```json
{
  "repo_root": "/workspace/mobile-app",
  "relative_path": "docs/notes.md",
  "local_path": "/workspace/mobile-app/docs/notes.md",
  "exists": false
}
```

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


## Collaboration endpoints

All collaboration routes derive the current repository from the same workspace
`path`/repo-context logic as `GET /github/repos/current`. `path` is optional on
all `GET` endpoints and defaults to the server work dir. `workspace_path` is the
matching optional field for `POST` requests.

### `GET /github/account`

Returns the authenticated GitHub account for the current repository host.

Example response:

```json
{
  "github_host": "github.com",
  "repository": {
    "github_host": "github.com",
    "owner": "octo-org",
    "name": "mobile-app",
    "full_name": "octo-org/mobile-app",
    "remote_name": "origin",
    "remote_url": "git@github.com:octo-org/mobile-app.git",
    "repo_root": "/workspace/mobile-app"
  },
  "account": {
    "login": "octocat",
    "id": 9,
    "name": "The Octocat",
    "avatar_url": "https://avatars.githubusercontent.com/u/9?v=4",
    "html_url": "https://github.com/octocat"
  }
}
```

### `GET /github/issues`

Supported query params are passed through to the repo issues REST API with
snake_case responses: `state`, `sort`, `direction`, `since`, `labels`,
`creator`, `mentioned`, `assignee`, `milestone`, `page`, and `per_page`.
Pull-request-backed issue records are filtered out from this list.

Example response:

```json
{
  "repository": {
    "full_name": "octo-org/mobile-app"
  },
  "issues": [
    {
      "number": 42,
      "title": "Fix flaky mobile reconnect",
      "state": "open",
      "body": "Reconnect can stall after sleep...",
      "html_url": "https://github.com/octo-org/mobile-app/issues/42",
      "comments_count": 3,
      "locked": false,
      "author": {
        "login": "octocat",
        "id": 9
      },
      "labels": [
        {
          "name": "bug",
          "color": "d73a4a"
        }
      ],
      "created_at": "2026-04-19T10:00:00Z",
      "updated_at": "2026-04-20T08:30:00Z"
    }
  ]
}
```

### `GET /github/issues/{number}`

Returns the normalized issue detail payload for the current repository.

### `POST /github/issues/{number}/comments`

Request body:

```json
{
  "workspace_path": "/workspace/mobile-app",
  "body": "I can take this one."
}
```

Response body:

```json
{
  "repository": {
    "full_name": "octo-org/mobile-app"
  },
  "comment": {
    "id": 1001,
    "body": "I can take this one.",
    "html_url": "https://github.com/octo-org/mobile-app/issues/42#issuecomment-1001",
    "author": {
      "login": "octocat",
      "id": 9
    },
    "created_at": "2026-04-20T09:00:00Z"
  }
}
```

### `GET /github/pulls`

Supported query params: `state`, `assigned_to_me`, `created_by_me`, `mentioned`,
`needs_review`, `head`, `base`, `sort`, `direction`, `page`, and `per_page`.
Current-user PR filters use a repo-scoped search query so they can be combined
with pagination and state while still returning normalized PR payloads.

### `GET /github/pulls/{number}`

Returns the normalized pull request detail plus aggregated commit status/check
summary under `pull_request.checks`.

Example `checks` payload:

```json
{
  "state": "pending",
  "total_count": 3,
  "success_count": 1,
  "pending_count": 1,
  "failure_count": 1,
  "checks": [
    {
      "name": "ci / unit-tests",
      "status": "completed",
      "conclusion": "success",
      "details_url": "https://github.com/octo-org/mobile-app/actions/runs/1"
    },
    {
      "name": "buildkite/mobile",
      "status": "pending",
      "details_url": "https://buildkite.example/run/2"
    }
  ]
}
```

### `GET /github/pulls/{number}/files`

Returns normalized changed-file entries with `filename`, `status`, `additions`,
`deletions`, `changes`, optional `patch`, and optional `previous_filename`.

### `GET /github/pulls/{number}/comments`

Returns normalized review-thread comment entries for the pull request.
Supported query params: `sort`, `direction`, `since`, `page`, and `per_page`.

### `POST /github/pulls/{number}/comments`

Creates a PR review comment. For inline comments provide `body`, `path`,
`commit_id`, and `line`; for replies provide `body` plus `in_reply_to`.
Optional multi-line anchors use `side`, `start_line`, and `start_side`.

### `POST /github/pulls/{number}/reviews`

Creates a pull-request review. `event` should be one of `COMMENT`, `APPROVE`,
or `REQUEST_CHANGES`. Draft review comments use normalized snake_case fields.

Example request:

```json
{
  "workspace_path": "/workspace/mobile-app",
  "event": "REQUEST_CHANGES",
  "body": "Please tighten the retry bounds.",
  "comments": [
    {
      "body": "This branch can loop forever.",
      "path": "server/internal/github/service.go",
      "line": 142,
      "side": "RIGHT"
    }
  ]
}
```

## Collaboration error contract

These endpoints return JSON errors via the same `error_code`/`message` envelope
used by auth routes. Expected collaboration error codes include:

- `repo_not_github`: the workspace path does not resolve to a GitHub-backed repository
- `invalid_request`: missing/invalid route params, query params, or request body
- `not_authenticated`: no stored GitHub auth session exists for the repo host
- `reauth_required`: refresh failed or the access token is no longer usable
- `repo_access_unavailable`: GitHub rejected repository access for the account
- `not_found`: the repo-scoped issue, pull request, or nested resource was not found
- `github_auth_error`: upstream GitHub request failed in an unexpected way
