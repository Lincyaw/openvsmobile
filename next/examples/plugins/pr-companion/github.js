// PR Companion — GitHub HTTP client.
//
// Standalone module. Imports nothing from `@openvsmobile/sdk`; intentional
// so it can be unit-tested with a `fetch` mock without spawning the plugin
// host. The rest of the plugin (index.js / auth.js / render/* / state.js)
// will import this in Phases 2-5; for now it ships alone.
//
// Design contract (see docs/design/plugins/pr-companion.md):
//   * ETag / If-Modified-Since on every GET. Caller passes the prior ETag
//     and gets back `notModified` + the same ETag on 304.
//   * Rate-limit awareness: X-RateLimit-* parsed into a structured value
//     and stashed on the client so `lastRateLimit()` returns the most
//     recent reading (including from 304 responses).
//   * Pagination via Link header, with hard caps per endpoint so a runaway
//     PR can't blow out memory.
//   * No retries. The plugin's polling loop IS the retry; backing off
//     here would mask 5xx storms and burn battery during outages.
//   * No caching beyond the lastRateLimit slot. The plugin's state layer
//     (Phase 2) owns the request-level cache.
//   * No logging side-effects. Callers wrap with their own logger.
//
// Returned shapes are intentionally narrow — only the fields the design
// doc's panels render. Phase 2-5 workers read the JSDoc typedefs below
// as the source of truth; extending them later is a one-line addition,
// rendering fields we never expose is permanent bloat.
//
// TODO(phase-2): if option (b) was taken on test discovery, add a vitest
// include glob so github.test.js runs in `pnpm test`.

const GITHUB_API = "https://api.github.com";
const ACCEPT = "application/vnd.github+json";
const API_VERSION = "2022-11-28";
const DEFAULT_TIMEOUT_MS = 10_000;

const NOTIFICATIONS_PAGE_CAP = 100; // one page is usually enough
const PULL_FILES_PAGE_CAP = 300; // huge PRs go through github.com
const PULL_COMMENTS_PAGE_CAP = 500;
const PER_PAGE = 100;

/**
 * @typedef {Object} RateLimitInfo
 * @property {number} limit
 * @property {number} remaining
 * @property {Date} resetAt
 */

/**
 * Subset of GitHub API response — only the fields we render.
 * @typedef {Object} Notification
 * @property {string} id
 * @property {string} reason
 * @property {string} updatedAt
 * @property {string | null} lastReadAt
 * @property {{ fullName: string, owner: string, name: string }} repository
 * @property {{ title: string, url: string, type: string }} subject
 */

/**
 * Subset of GitHub API response — only the fields we render.
 * @typedef {Object} Pull
 * @property {number} number
 * @property {string} title
 * @property {string} body
 * @property {string} state
 * @property {boolean} draft
 * @property {boolean} merged
 * @property {{ login: string, avatarUrl: string }} user
 * @property {string} headSha
 * @property {number} additions
 * @property {number} deletions
 * @property {number} changedFiles
 * @property {string} createdAt
 * @property {string} updatedAt
 * @property {string} htmlUrl
 */

/**
 * Subset of GitHub API response — only the fields we render.
 * `patch` may be null when the file is too large or binary; the render
 * layer is responsible for showing a "view on GitHub" affordance.
 * @typedef {Object} PullFile
 * @property {string} filename
 * @property {string} status
 * @property {number} additions
 * @property {number} deletions
 * @property {string | null} patch
 */

/**
 * Subset of GitHub API response — only the fields we render.
 * Covers both issue comments (top-level) and review-thread comments;
 * `path` / `line` / `inReplyToId` are null for issue comments.
 * @typedef {Object} PullComment
 * @property {number} id
 * @property {{ login: string, avatarUrl: string }} user
 * @property {string} body
 * @property {string} createdAt
 * @property {string} htmlUrl
 * @property {number | null} inReplyToId
 * @property {string | null} path
 * @property {number | null} line
 */

/**
 * Subset of GitHub API response — only the fields we render.
 * @typedef {Object} CheckRun
 * @property {number} id
 * @property {string} name
 * @property {string} status
 * @property {string | null} conclusion
 * @property {string | null} startedAt
 * @property {string | null} completedAt
 * @property {string} htmlUrl
 * @property {string | null} logUrl
 */

/**
 * Parse a GitHub `Link` header into a relation → url map. Returns an
 * empty object when the header is missing or malformed; callers treat
 * "no next" identically to "no link header".
 *
 * Format: `<url1>; rel="next", <url2>; rel="last"` (whitespace varies).
 *
 * @param {string | null | undefined} header
 * @returns {{ next?: string, prev?: string, last?: string, first?: string }}
 */
export function parseLinkHeader(header) {
  if (typeof header !== "string" || header.length === 0) return {};
  /** @type {Record<string, string>} */
  const out = {};
  // Split on commas that separate entries — URLs do not contain unescaped
  // commas in practice for GitHub's pagination links, so a plain split is
  // safe. If GitHub ever changes that, the per-entry regex below would
  // simply skip the malformed entry rather than crash.
  const parts = header.split(",");
  for (const raw of parts) {
    const entry = raw.trim();
    // Match `<URL>; rel="name"` allowing extra params after rel.
    const match = entry.match(/^<([^>]+)>\s*;\s*rel="([^"]+)"/);
    if (match === null) continue;
    const url = match[1];
    const rel = match[2];
    out[rel] = url;
  }
  return out;
}

/**
 * Read GitHub rate-limit headers off a Response. Returns null when the
 * headers are absent (e.g. some 5xx responses don't carry them).
 *
 * @param {Headers} headers
 * @returns {RateLimitInfo | null}
 */
export function extractRateLimit(headers) {
  const limitRaw = headers.get("x-ratelimit-limit");
  const remainingRaw = headers.get("x-ratelimit-remaining");
  const resetRaw = headers.get("x-ratelimit-reset");
  if (limitRaw === null || remainingRaw === null || resetRaw === null) {
    return null;
  }
  const limit = Number(limitRaw);
  const remaining = Number(remainingRaw);
  const resetEpoch = Number(resetRaw);
  if (!Number.isFinite(limit) || !Number.isFinite(remaining) || !Number.isFinite(resetEpoch)) {
    return null;
  }
  return {
    limit,
    remaining,
    resetAt: new Date(resetEpoch * 1000),
  };
}

/**
 * Internal: build the request init for a JSON GitHub call.
 *
 * @param {Object} params
 * @param {string} params.token
 * @param {string} params.userAgent
 * @param {string} params.method
 * @param {string} [params.etag]
 * @param {string} [params.ifModifiedSince]
 * @param {unknown} [params.body]
 * @param {AbortSignal} params.signal
 * @returns {RequestInit}
 */
function buildInit({ token, userAgent, method, etag, ifModifiedSince, body, signal }) {
  /** @type {Record<string, string>} */
  const headers = {
    Accept: ACCEPT,
    Authorization: `token ${token}`,
    "User-Agent": userAgent,
    "X-GitHub-Api-Version": API_VERSION,
  };
  if (typeof etag === "string" && etag.length > 0) {
    headers["If-None-Match"] = etag;
  }
  if (typeof ifModifiedSince === "string" && ifModifiedSince.length > 0) {
    headers["If-Modified-Since"] = ifModifiedSince;
  }
  /** @type {RequestInit} */
  const init = { method, headers, signal };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  return init;
}

/**
 * Internal: classify a Response into our status union (without success).
 * Returns null when the response should be treated as a successful 2xx.
 *
 * Disambiguates rate-limited 403 (`X-RateLimit-Remaining: 0`) from
 * permission-denied 403 (no such header / nonzero remaining).
 *
 * @param {Response} response
 * @param {RateLimitInfo | null} rateLimit
 * @returns {{ status: 'notModified' } | { status: 'unauthed' } | { status: 'rateLimited', resetAt: Date } | { status: 'serverError', code: number } | null}
 */
function classify(response, rateLimit) {
  if (response.status === 304) return { status: "notModified" };
  if (response.status === 401) return { status: "unauthed" };
  if (response.status === 403) {
    const remaining = response.headers.get("x-ratelimit-remaining");
    if (remaining !== null && Number(remaining) === 0 && rateLimit !== null) {
      return { status: "rateLimited", resetAt: rateLimit.resetAt };
    }
    return { status: "serverError", code: 403 };
  }
  if (response.status >= 500 && response.status < 600) {
    return { status: "serverError", code: response.status };
  }
  if (response.status >= 400) {
    // 404 / 422 / etc. land here. We don't have a richer vocabulary for
    // them today; callers can switch on `code` if they need to.
    return { status: "serverError", code: response.status };
  }
  return null;
}

/**
 * Construct a per-session GitHub client. Token is closure-captured and
 * never persisted by this module.
 *
 * @param {{ token: string, userAgent: string }} params
 */
export function createGithubClient({ token, userAgent }) {
  if (typeof token !== "string" || token.length === 0) {
    throw new TypeError("createGithubClient: token is required");
  }
  if (typeof userAgent !== "string" || userAgent.length === 0) {
    throw new TypeError("createGithubClient: userAgent is required (GitHub policy)");
  }

  /** @type {RateLimitInfo | null} */
  let lastRateLimit = null;

  /**
   * Run a single request with timeout + rate-limit bookkeeping. Returns
   * a normalized `{ response, rateLimit }` on transport success, or one
   * of our offline-shaped error objects on transport failure / timeout.
   *
   * @param {string} url
   * @param {RequestInit & { signal?: never }} init
   * @returns {Promise<{ kind: 'response', response: Response, rateLimit: RateLimitInfo | null } | { kind: 'offline', error: Error }>}
   */
  async function fetchOnce(url, init) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS);
    try {
      const response = await fetch(url, { ...init, signal: controller.signal });
      const rateLimit = extractRateLimit(response.headers);
      if (rateLimit !== null) lastRateLimit = rateLimit;
      return { kind: "response", response, rateLimit };
    } catch (error) {
      // AbortError (timeout) and TypeError (network) both surface as
      // "offline" to the caller — distinguishing them at the protocol
      // layer would tempt callers into different retry policies, but
      // the spec is explicit that retry is the polling loop's job.
      const err = error instanceof Error ? error : new Error(String(error));
      return { kind: "offline", error: err };
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Internal helper: GET a single URL, returning a normalized envelope.
   * Used by every read method; pagination wrappers loop over this.
   *
   * @param {string} url
   * @param {{ etag?: string, ifModifiedSince?: string }} [opts]
   */
  async function getJson(url, opts = {}) {
    const init = buildInit({
      token,
      userAgent,
      method: "GET",
      etag: opts.etag,
      ifModifiedSince: opts.ifModifiedSince,
      // Signal injected inside fetchOnce so we can clear the timer.
      signal: /** @type {AbortSignal} */ (/** @type {unknown} */ (undefined)),
    });
    const result = await fetchOnce(url, init);
    if (result.kind === "offline") {
      return { status: /** @type {const} */ ("offline"), error: result.error };
    }
    const { response, rateLimit } = result;
    const classified = classify(response, rateLimit);
    if (classified !== null) {
      if (classified.status === "notModified") {
        return {
          status: /** @type {const} */ ("notModified"),
          etag: opts.etag ?? null,
          rateLimit,
        };
      }
      return classified;
    }
    let body;
    try {
      body = await response.json();
    } catch (error) {
      const err = error instanceof Error ? error : new Error(String(error));
      return { status: /** @type {const} */ ("serverError"), code: response.status, error: err };
    }
    return {
      status: /** @type {const} */ ("ok"),
      body,
      etag: response.headers.get("etag"),
      lastModified: response.headers.get("last-modified"),
      linkHeader: response.headers.get("link"),
      rateLimit,
    };
  }

  /**
   * Internal helper: POST a JSON body, returning a normalized envelope.
   * Reads don't need this; only the write methods do. We do not return
   * the response body to callers today — every write the design doc
   * specifies is fire-and-forget from the plugin's perspective (the
   * polling loop will pick up the resulting state change).
   *
   * @param {string} url
   * @param {unknown} body
   */
  async function postJson(url, body) {
    const init = buildInit({
      token,
      userAgent,
      method: "POST",
      body,
      signal: /** @type {AbortSignal} */ (/** @type {unknown} */ (undefined)),
    });
    const result = await fetchOnce(url, init);
    if (result.kind === "offline") {
      return { status: /** @type {const} */ ("offline"), error: result.error };
    }
    const { response, rateLimit } = result;
    const classified = classify(response, rateLimit);
    if (classified !== null) {
      // POSTs don't 304; the `notModified` branch is unreachable but
      // collapsing it here would mean classify() returns two shapes.
      // Cheaper to just pass it through as a serverError than to fork
      // the helper.
      if (classified.status === "notModified") {
        return { status: /** @type {const} */ ("serverError"), code: 304 };
      }
      return classified;
    }
    return { status: /** @type {const} */ ("ok"), rateLimit };
  }

  /**
   * Internal helper: PATCH a JSON body. Used by `markNotificationRead`.
   *
   * @param {string} url
   * @param {unknown} body
   */
  async function patchJson(url, body) {
    const init = buildInit({
      token,
      userAgent,
      method: "PATCH",
      body,
      signal: /** @type {AbortSignal} */ (/** @type {unknown} */ (undefined)),
    });
    const result = await fetchOnce(url, init);
    if (result.kind === "offline") {
      return { status: /** @type {const} */ ("offline"), error: result.error };
    }
    const { response, rateLimit } = result;
    const classified = classify(response, rateLimit);
    if (classified !== null) {
      if (classified.status === "notModified") {
        return { status: /** @type {const} */ ("serverError"), code: 304 };
      }
      return classified;
    }
    return { status: /** @type {const} */ ("ok"), rateLimit };
  }

  // -- Narrowing mappers -------------------------------------------------
  //
  // Each mapper takes a raw GitHub JSON object and projects it down to
  // the JSDoc typedef above. We do NOT pass through `node_id`, `installation`,
  // `requested_teams`, or any other field that isn't rendered — see the
  // module header for the rationale.

  /**
   * @param {Record<string, unknown>} raw
   * @returns {Notification}
   */
  function mapNotification(raw) {
    const repo = /** @type {Record<string, unknown>} */ (raw.repository ?? {});
    const repoOwner = /** @type {Record<string, unknown>} */ (repo.owner ?? {});
    const subject = /** @type {Record<string, unknown>} */ (raw.subject ?? {});
    return {
      id: String(raw.id ?? ""),
      reason: String(raw.reason ?? ""),
      updatedAt: String(raw.updated_at ?? ""),
      lastReadAt: raw.last_read_at === null || raw.last_read_at === undefined
        ? null
        : String(raw.last_read_at),
      repository: {
        fullName: String(repo.full_name ?? ""),
        owner: String(repoOwner.login ?? ""),
        name: String(repo.name ?? ""),
      },
      subject: {
        title: String(subject.title ?? ""),
        url: String(subject.url ?? ""),
        type: String(subject.type ?? ""),
      },
    };
  }

  /**
   * @param {Record<string, unknown>} raw
   * @returns {Pull}
   */
  function mapPull(raw) {
    const user = /** @type {Record<string, unknown>} */ (raw.user ?? {});
    const head = /** @type {Record<string, unknown>} */ (raw.head ?? {});
    return {
      number: Number(raw.number ?? 0),
      title: String(raw.title ?? ""),
      body: typeof raw.body === "string" ? raw.body : "",
      state: String(raw.state ?? ""),
      draft: raw.draft === true,
      merged: raw.merged === true,
      user: {
        login: String(user.login ?? ""),
        avatarUrl: String(user.avatar_url ?? ""),
      },
      headSha: String(head.sha ?? ""),
      additions: Number(raw.additions ?? 0),
      deletions: Number(raw.deletions ?? 0),
      changedFiles: Number(raw.changed_files ?? 0),
      createdAt: String(raw.created_at ?? ""),
      updatedAt: String(raw.updated_at ?? ""),
      htmlUrl: String(raw.html_url ?? ""),
    };
  }

  /**
   * @param {Record<string, unknown>} raw
   * @returns {PullFile}
   */
  function mapPullFile(raw) {
    return {
      filename: String(raw.filename ?? ""),
      status: String(raw.status ?? ""),
      additions: Number(raw.additions ?? 0),
      deletions: Number(raw.deletions ?? 0),
      patch: typeof raw.patch === "string" ? raw.patch : null,
    };
  }

  /**
   * @param {Record<string, unknown>} raw
   * @returns {PullComment}
   */
  function mapPullComment(raw) {
    const user = /** @type {Record<string, unknown>} */ (raw.user ?? {});
    return {
      id: Number(raw.id ?? 0),
      user: {
        login: String(user.login ?? ""),
        avatarUrl: String(user.avatar_url ?? ""),
      },
      body: typeof raw.body === "string" ? raw.body : "",
      createdAt: String(raw.created_at ?? ""),
      htmlUrl: String(raw.html_url ?? ""),
      inReplyToId: raw.in_reply_to_id === undefined || raw.in_reply_to_id === null
        ? null
        : Number(raw.in_reply_to_id),
      path: typeof raw.path === "string" ? raw.path : null,
      line: typeof raw.line === "number" ? raw.line : null,
    };
  }

  /**
   * @param {Record<string, unknown>} raw
   * @returns {CheckRun}
   */
  function mapCheckRun(raw) {
    return {
      id: Number(raw.id ?? 0),
      name: String(raw.name ?? ""),
      status: String(raw.status ?? ""),
      conclusion: raw.conclusion === null || raw.conclusion === undefined
        ? null
        : String(raw.conclusion),
      startedAt: raw.started_at === null || raw.started_at === undefined
        ? null
        : String(raw.started_at),
      completedAt: raw.completed_at === null || raw.completed_at === undefined
        ? null
        : String(raw.completed_at),
      htmlUrl: String(raw.html_url ?? ""),
      logUrl: typeof raw.details_url === "string" ? raw.details_url : null,
    };
  }

  // -- Pagination ---------------------------------------------------------
  //
  // GitHub returns a `Link` header with `rel="next"` until the last page.
  // We walk it greedily up to `cap` items; the per-page size is fixed at
  // 100 (the GitHub max) so the cap is in items not pages.

  /**
   * @template T
   * @param {string} firstUrl
   * @param {(raw: Record<string, unknown>) => T} map
   * @param {number} cap
   * @param {{ etag?: string, ifModifiedSince?: string }} firstOpts
   */
  async function paginate(firstUrl, map, cap, firstOpts) {
    let url = firstUrl;
    /** @type {T[]} */
    const items = [];
    let firstResponse = null;
    let opts = firstOpts;
    while (url !== null && url !== undefined && items.length < cap) {
      const res = await getJson(url, opts);
      // Conditional headers only apply to the first page; subsequent
      // page URLs are returned by GitHub as fresh resource URLs.
      opts = {};
      if (res.status !== "ok") {
        // First-page non-2xx is the response. Mid-pagination failure
        // is reported the same way — partial results are not safer
        // than an explicit error.
        if (firstResponse === null) return res;
        return res;
      }
      if (firstResponse === null) firstResponse = res;
      const body = /** @type {unknown[]} */ (res.body);
      if (!Array.isArray(body)) {
        // Defensive: a paginated endpoint that returns a non-array is
        // a GitHub-side bug; surface it as serverError rather than
        // crashing the plugin.
        return { status: /** @type {const} */ ("serverError"), code: 500 };
      }
      for (const raw of body) {
        if (items.length >= cap) break;
        items.push(map(/** @type {Record<string, unknown>} */ (raw)));
      }
      const link = parseLinkHeader(res.linkHeader);
      url = link.next ?? null;
    }
    // The etag / lastModified / rateLimit we return are the FIRST page's
    // — that's the one the caller will use as the conditional-request
    // key on the next poll. Per-page etags from deeper pages are not
    // useful since the next call always starts at page 1.
    return {
      status: /** @type {const} */ ("ok"),
      items,
      etag: firstResponse.etag,
      lastModified: firstResponse.lastModified,
      rateLimit: firstResponse.rateLimit,
    };
  }

  // -- Public methods -----------------------------------------------------

  /**
   * GET /notifications. ETag + If-Modified-Since both supported because
   * GitHub specifically recommends the latter for this endpoint.
   *
   * @param {{ participating?: boolean, sinceETag?: string, sinceLastModified?: string }} [opts]
   */
  async function listNotifications(opts = {}) {
    const query = new URLSearchParams();
    query.set("per_page", String(PER_PAGE));
    if (opts.participating === true) query.set("participating", "true");
    const url = `${GITHUB_API}/notifications?${query.toString()}`;
    return paginate(
      url,
      mapNotification,
      NOTIFICATIONS_PAGE_CAP,
      { etag: opts.sinceETag, ifModifiedSince: opts.sinceLastModified },
    );
  }

  /**
   * PATCH /notifications/threads/{id} → mark as read. GitHub's API
   * uses PATCH (not DELETE) for this; the request body is empty.
   *
   * @param {string} notificationId
   */
  async function markNotificationRead(notificationId) {
    if (typeof notificationId !== "string" || notificationId.length === 0) {
      throw new TypeError("markNotificationRead: notificationId is required");
    }
    const url = `${GITHUB_API}/notifications/threads/${encodeURIComponent(notificationId)}`;
    return patchJson(url, {});
  }

  /**
   * GET /repos/{owner}/{repo}/pulls/{number}.
   *
   * @param {{ owner: string, repo: string, number: number, etag?: string }} params
   */
  async function getPull(params) {
    const { owner, repo, number, etag } = params;
    const url = `${GITHUB_API}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/pulls/${number}`;
    const res = await getJson(url, { etag });
    if (res.status !== "ok") return res;
    return {
      status: /** @type {const} */ ("ok"),
      pull: mapPull(/** @type {Record<string, unknown>} */ (res.body)),
      etag: res.etag,
      rateLimit: res.rateLimit,
    };
  }

  /**
   * GET /repos/{owner}/{repo}/pulls/{number}/files.
   *
   * @param {{ owner: string, repo: string, number: number, etag?: string }} params
   */
  async function listPullFiles(params) {
    const { owner, repo, number, etag } = params;
    const url = `${GITHUB_API}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/pulls/${number}/files?per_page=${PER_PAGE}`;
    const res = await paginate(url, mapPullFile, PULL_FILES_PAGE_CAP, { etag });
    if (res.status !== "ok") return res;
    return {
      status: /** @type {const} */ ("ok"),
      files: res.items,
      etag: res.etag,
      rateLimit: res.rateLimit,
    };
  }

  /**
   * GET /repos/{owner}/{repo}/issues/{number}/comments — top-level PR
   * conversation. Review-thread comments live on a different endpoint
   * (`/pulls/{n}/comments`); the design doc renders both into the same
   * "Conversation" tab, so callers will invoke both methods and merge.
   *
   * @param {{ owner: string, repo: string, number: number, etag?: string }} params
   */
  async function listPullComments(params) {
    const { owner, repo, number, etag } = params;
    const url = `${GITHUB_API}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues/${number}/comments?per_page=${PER_PAGE}`;
    const res = await paginate(url, mapPullComment, PULL_COMMENTS_PAGE_CAP, { etag });
    if (res.status !== "ok") return res;
    return {
      status: /** @type {const} */ ("ok"),
      comments: res.items,
      etag: res.etag,
      rateLimit: res.rateLimit,
    };
  }

  /**
   * GET /repos/{owner}/{repo}/commits/{ref}/check-runs. The response
   * wraps the array in `{ total_count, check_runs }` so we unpack
   * before paginating; in practice one page covers every PR we expect
   * to view on a phone.
   *
   * @param {{ owner: string, repo: string, ref: string, etag?: string }} params
   */
  async function listCheckRuns(params) {
    const { owner, repo, ref, etag } = params;
    const url = `${GITHUB_API}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/commits/${encodeURIComponent(ref)}/check-runs?per_page=${PER_PAGE}`;
    const res = await getJson(url, { etag });
    if (res.status !== "ok") return res;
    const body = /** @type {Record<string, unknown>} */ (res.body);
    const rawRuns = Array.isArray(body.check_runs) ? body.check_runs : [];
    const checkRuns = rawRuns.map((raw) =>
      mapCheckRun(/** @type {Record<string, unknown>} */ (raw)),
    );
    return {
      status: /** @type {const} */ ("ok"),
      checkRuns,
      etag: res.etag,
      rateLimit: res.rateLimit,
    };
  }

  /**
   * POST /repos/{owner}/{repo}/pulls/{number}/reviews — submit a review
   * with one of three events. The design doc names these as the only
   * three v0 review actions; merge / close / request-reviewer
   * deliberately do not have a method.
   *
   * @param {{ owner: string, repo: string, number: number, event: 'APPROVE' | 'REQUEST_CHANGES' | 'COMMENT', body?: string }} params
   */
  async function postReview(params) {
    const { owner, repo, number, event, body } = params;
    if (event !== "APPROVE" && event !== "REQUEST_CHANGES" && event !== "COMMENT") {
      throw new TypeError(`postReview: invalid event ${String(event)}`);
    }
    const url = `${GITHUB_API}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/pulls/${number}/reviews`;
    /** @type {Record<string, unknown>} */
    const payload = { event };
    if (typeof body === "string" && body.length > 0) payload.body = body;
    return postJson(url, payload);
  }

  /**
   * POST /repos/{owner}/{repo}/issues/{number}/comments — top-level PR
   * comment (the GitHub UI calls these "issue comments" since PRs are a
   * subclass of issues at the API level).
   *
   * @param {{ owner: string, repo: string, number: number, body: string }} params
   */
  async function postPullComment(params) {
    const { owner, repo, number, body } = params;
    if (typeof body !== "string" || body.length === 0) {
      throw new TypeError("postPullComment: body is required");
    }
    const url = `${GITHUB_API}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues/${number}/comments`;
    return postJson(url, { body });
  }

  /**
   * POST /repos/{owner}/{repo}/pulls/{number}/comments/{commentId}/replies
   * — reply within an existing review thread. The design doc reserves
   * starting a NEW line-anchored thread for v1; this method is for
   * adding to a thread that already exists.
   *
   * @param {{ owner: string, repo: string, number: number, replyToId: number, body: string }} params
   */
  async function postPullCommentReply(params) {
    const { owner, repo, number, replyToId, body } = params;
    if (typeof body !== "string" || body.length === 0) {
      throw new TypeError("postPullCommentReply: body is required");
    }
    if (!Number.isInteger(replyToId) || replyToId <= 0) {
      throw new TypeError("postPullCommentReply: replyToId must be a positive integer");
    }
    const url = `${GITHUB_API}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/pulls/${number}/comments/${replyToId}/replies`;
    return postJson(url, { body });
  }

  function lastRateLimitGetter() {
    return lastRateLimit;
  }

  return {
    listNotifications,
    markNotificationRead,
    getPull,
    listPullFiles,
    listPullComments,
    listCheckRuns,
    postReview,
    postPullComment,
    postPullCommentReply,
    lastRateLimit: lastRateLimitGetter,
  };
}
