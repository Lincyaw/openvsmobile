// Unit tests for the PR Companion GitHub HTTP client. Runs inside the
// backend's vitest invocation via an extra include glob in
// `next/backend/vitest.config.ts`.
//
// Tests stub the global `fetch` per test rather than introducing an HTTP
// mock library — the surface we exercise is small (one function per
// case, predictable URL + body shape) and the stub-per-case style keeps
// each test self-documenting about what GitHub response shape it asserts
// on. Real network calls are never made.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  createGithubClient,
  extractRateLimit,
  parseLinkHeader,
} from "./github.js";

/**
 * Build a minimal Response-shaped object. We don't use the real
 * `Response` constructor because we need precise control over the
 * `headers.get` lookup keys and the body deserialization.
 */
function fakeResponse({ status = 200, body = {}, headers = {} } = {}) {
  /** @type {Record<string, string>} */
  const lower = {};
  for (const [k, v] of Object.entries(headers)) {
    if (v !== null && v !== undefined) lower[k.toLowerCase()] = String(v);
  }
  return {
    status,
    headers: {
      get(name) {
        return lower[String(name).toLowerCase()] ?? null;
      },
    },
    async json() {
      return body;
    },
  };
}

/** Capture every call's URL + init so tests can assert on them. */
let calls = [];
let fetchImpl = () => Promise.resolve(fakeResponse());

beforeEach(() => {
  calls = [];
  fetchImpl = () => Promise.resolve(fakeResponse());
  // @ts-expect-error — replacing the global for the test
  globalThis.fetch = (url, init) => {
    calls.push({ url: String(url), init });
    return fetchImpl(url, init);
  };
});

afterEach(() => {
  vi.restoreAllMocks();
});

const RATE_HEADERS = {
  "x-ratelimit-limit": "5000",
  "x-ratelimit-remaining": "4998",
  "x-ratelimit-reset": "1700000000",
};

function newClient() {
  return createGithubClient({ token: "test-token", userAgent: "pr-companion-test/0.1" });
}

describe("parseLinkHeader", () => {
  it("parses a multi-rel header", () => {
    const header = '<https://api.github.com/x?page=2>; rel="next", <https://api.github.com/x?page=10>; rel="last"';
    const out = parseLinkHeader(header);
    expect(out.next).toBe("https://api.github.com/x?page=2");
    expect(out.last).toBe("https://api.github.com/x?page=10");
  });

  it("returns empty object on null / missing header", () => {
    expect(parseLinkHeader(null)).toEqual({});
    expect(parseLinkHeader(undefined)).toEqual({});
    expect(parseLinkHeader("")).toEqual({});
  });

  it("skips malformed entries", () => {
    const header = '<https://api.github.com/x?page=2>; rel="next", garbage entry';
    const out = parseLinkHeader(header);
    expect(out.next).toBe("https://api.github.com/x?page=2");
    expect(Object.keys(out)).toHaveLength(1);
  });
});

describe("extractRateLimit", () => {
  it("parses rate-limit headers into a structured value", () => {
    const headers = {
      get(name) {
        return RATE_HEADERS[name.toLowerCase()] ?? null;
      },
    };
    const info = extractRateLimit(/** @type {Headers} */ (/** @type {unknown} */ (headers)));
    expect(info).not.toBeNull();
    expect(info.limit).toBe(5000);
    expect(info.remaining).toBe(4998);
    expect(info.resetAt).toBeInstanceOf(Date);
    expect(info.resetAt.getTime()).toBe(1700000000 * 1000);
  });

  it("returns null when any header is missing", () => {
    const headers = {
      get(name) {
        if (name.toLowerCase() === "x-ratelimit-limit") return "5000";
        return null;
      },
    };
    expect(extractRateLimit(/** @type {Headers} */ (/** @type {unknown} */ (headers)))).toBeNull();
  });
});

describe("listNotifications", () => {
  it("happy path returns mapped items + etag + rate limit", async () => {
    fetchImpl = () =>
      Promise.resolve(
        fakeResponse({
          status: 200,
          body: [
            {
              id: "1",
              reason: "review_requested",
              updated_at: "2026-01-01T00:00:00Z",
              last_read_at: null,
              repository: {
                full_name: "octo/repo",
                name: "repo",
                owner: { login: "octo" },
              },
              subject: {
                title: "Fix the thing",
                url: "https://api.github.com/repos/octo/repo/pulls/42",
                type: "PullRequest",
              },
              // node_id and other unrendered fields are dropped on map
              node_id: "abc",
            },
          ],
          headers: { etag: 'W/"abc"', "last-modified": "Wed, 01 Jan 2026 00:00:00 GMT", ...RATE_HEADERS },
        }),
      );

    const client = newClient();
    const result = await client.listNotifications({ participating: true });

    expect(result.status).toBe("ok");
    expect(result.items).toHaveLength(1);
    expect(result.items[0].id).toBe("1");
    expect(result.items[0].repository.fullName).toBe("octo/repo");
    expect(result.items[0].subject.title).toBe("Fix the thing");
    // narrowed: node_id is not on the mapped shape
    expect("node_id" in result.items[0]).toBe(false);
    expect(result.etag).toBe('W/"abc"');
    expect(result.lastModified).toBe("Wed, 01 Jan 2026 00:00:00 GMT");
    expect(result.rateLimit.limit).toBe(5000);

    // Outgoing request sanity
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toContain("/notifications");
    expect(calls[0].url).toContain("participating=true");
    expect(calls[0].init.headers.Authorization).toBe("token test-token");
    expect(calls[0].init.headers["User-Agent"]).toBe("pr-companion-test/0.1");
    expect(calls[0].init.headers["X-GitHub-Api-Version"]).toBe("2022-11-28");
  });

  it("304 returns notModified with the caller's etag", async () => {
    fetchImpl = () =>
      Promise.resolve(fakeResponse({ status: 304, headers: RATE_HEADERS }));

    const client = newClient();
    const result = await client.listNotifications({ sinceETag: 'W/"prev"' });

    expect(result.status).toBe("notModified");
    expect(result.etag).toBe('W/"prev"');
    expect(result.rateLimit.limit).toBe(5000);
    expect(calls[0].init.headers["If-None-Match"]).toBe('W/"prev"');
  });

  it("401 returns unauthed", async () => {
    fetchImpl = () => Promise.resolve(fakeResponse({ status: 401, headers: RATE_HEADERS }));

    const client = newClient();
    const result = await client.listNotifications();

    expect(result.status).toBe("unauthed");
  });

  it("403 with remaining=0 returns rateLimited", async () => {
    fetchImpl = () =>
      Promise.resolve(
        fakeResponse({
          status: 403,
          headers: {
            "x-ratelimit-limit": "5000",
            "x-ratelimit-remaining": "0",
            "x-ratelimit-reset": "1700000500",
          },
        }),
      );

    const client = newClient();
    const result = await client.listNotifications();

    expect(result.status).toBe("rateLimited");
    expect(result.resetAt).toBeInstanceOf(Date);
    expect(result.resetAt.getTime()).toBe(1700000500 * 1000);
  });

  it("403 without rate-limit headers returns serverError 403", async () => {
    fetchImpl = () => Promise.resolve(fakeResponse({ status: 403 }));

    const client = newClient();
    const result = await client.listNotifications();

    expect(result.status).toBe("serverError");
    expect(result.code).toBe(403);
  });

  it("403 with remaining=42 (permission denied, not rate-limited) returns serverError 403", async () => {
    fetchImpl = () =>
      Promise.resolve(
        fakeResponse({
          status: 403,
          headers: {
            "x-ratelimit-limit": "5000",
            "x-ratelimit-remaining": "42",
            "x-ratelimit-reset": "1700000500",
          },
        }),
      );

    const client = newClient();
    const result = await client.listNotifications();

    expect(result.status).toBe("serverError");
    expect(result.code).toBe(403);
  });

  it("network error returns offline", async () => {
    fetchImpl = () => Promise.reject(new TypeError("fetch failed: connection refused"));

    const client = newClient();
    const result = await client.listNotifications();

    expect(result.status).toBe("offline");
    expect(result.error).toBeInstanceOf(Error);
    expect(result.error.message).toContain("fetch failed");
  });

  it("AbortError (timeout) returns offline", async () => {
    fetchImpl = () => {
      const err = new Error("The operation was aborted.");
      err.name = "AbortError";
      return Promise.reject(err);
    };

    const client = newClient();
    const result = await client.listNotifications();

    expect(result.status).toBe("offline");
    expect(result.error.name).toBe("AbortError");
  });
});

describe("pagination", () => {
  it("follows next links and caps at the per-endpoint maximum", async () => {
    // Three pages of 100 notifications each, all with rel=next set to
    // the following page. We assert that the cap (100) trims to one page
    // worth — the rest are discarded without follow-up fetches.
    const page = (n) => {
      const items = [];
      for (let i = 0; i < 100; i += 1) {
        items.push({
          id: String((n - 1) * 100 + i),
          reason: "subscribed",
          updated_at: "2026-01-01T00:00:00Z",
          repository: { full_name: "o/r", name: "r", owner: { login: "o" } },
          subject: { title: `t${i}`, url: "u", type: "PullRequest" },
        });
      }
      const headers = { ...RATE_HEADERS };
      if (n < 3) headers.link = `<https://api.github.com/notifications?page=${n + 1}>; rel="next"`;
      return fakeResponse({ status: 200, body: items, headers });
    };
    let n = 0;
    fetchImpl = () => {
      n += 1;
      return Promise.resolve(page(n));
    };

    const client = newClient();
    const result = await client.listNotifications();

    expect(result.status).toBe("ok");
    // Cap is 100 — exactly one page worth.
    expect(result.items).toHaveLength(100);
    expect(calls).toHaveLength(1);
  });
});

describe("getPull", () => {
  it("maps body and forwards etag", async () => {
    fetchImpl = () =>
      Promise.resolve(
        fakeResponse({
          status: 200,
          body: {
            number: 42,
            title: "Fix the thing",
            body: "details",
            state: "open",
            draft: false,
            merged: false,
            user: { login: "octo", avatar_url: "https://x/a" },
            head: { sha: "deadbeef" },
            additions: 12,
            deletions: 3,
            changed_files: 2,
            created_at: "2026-01-01T00:00:00Z",
            updated_at: "2026-01-02T00:00:00Z",
            html_url: "https://github.com/o/r/pull/42",
            // unrendered:
            mergeable: true,
            rebaseable: true,
          },
          headers: { etag: 'W/"pull42"', ...RATE_HEADERS },
        }),
      );

    const client = newClient();
    const result = await client.getPull({ owner: "o", repo: "r", number: 42, etag: 'W/"old"' });

    expect(result.status).toBe("ok");
    expect(result.pull.number).toBe(42);
    expect(result.pull.headSha).toBe("deadbeef");
    expect(result.pull.user.avatarUrl).toBe("https://x/a");
    expect("mergeable" in result.pull).toBe(false);
    expect(result.etag).toBe('W/"pull42"');
    expect(calls[0].init.headers["If-None-Match"]).toBe('W/"old"');
  });
});

describe("listCheckRuns", () => {
  it("unwraps the { check_runs: [...] } envelope", async () => {
    fetchImpl = () =>
      Promise.resolve(
        fakeResponse({
          status: 200,
          body: {
            total_count: 2,
            check_runs: [
              {
                id: 1,
                name: "ci",
                status: "completed",
                conclusion: "success",
                started_at: "2026-01-01T00:00:00Z",
                completed_at: "2026-01-01T00:01:00Z",
                html_url: "https://github.com/o/r/runs/1",
                details_url: "https://example.com/logs/1",
              },
              {
                id: 2,
                name: "lint",
                status: "in_progress",
                conclusion: null,
                started_at: "2026-01-01T00:00:00Z",
                completed_at: null,
                html_url: "https://github.com/o/r/runs/2",
                details_url: null,
              },
            ],
          },
          headers: { etag: 'W/"runs"', ...RATE_HEADERS },
        }),
      );

    const client = newClient();
    const result = await client.listCheckRuns({ owner: "o", repo: "r", ref: "deadbeef" });

    expect(result.status).toBe("ok");
    expect(result.checkRuns).toHaveLength(2);
    expect(result.checkRuns[0].conclusion).toBe("success");
    expect(result.checkRuns[1].conclusion).toBeNull();
    expect(result.checkRuns[1].logUrl).toBeNull();
  });
});

describe("postReview", () => {
  it("POSTs the right body shape and url", async () => {
    fetchImpl = () =>
      Promise.resolve(fakeResponse({ status: 200, body: { id: 1 }, headers: RATE_HEADERS }));

    const client = newClient();
    const result = await client.postReview({
      owner: "octo",
      repo: "repo",
      number: 42,
      event: "APPROVE",
      body: "LGTM",
    });

    expect(result.status).toBe("ok");
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("https://api.github.com/repos/octo/repo/pulls/42/reviews");
    expect(calls[0].init.method).toBe("POST");
    expect(calls[0].init.headers["Content-Type"]).toBe("application/json");
    expect(JSON.parse(calls[0].init.body)).toEqual({ event: "APPROVE", body: "LGTM" });
  });

  it("omits body field when caller supplies no message", async () => {
    fetchImpl = () => Promise.resolve(fakeResponse({ status: 200, headers: RATE_HEADERS }));

    const client = newClient();
    await client.postReview({ owner: "o", repo: "r", number: 1, event: "COMMENT" });

    expect(JSON.parse(calls[0].init.body)).toEqual({ event: "COMMENT" });
  });

  it("rejects unknown event values via a TypeError", async () => {
    const client = newClient();
    await expect(
      client.postReview({ owner: "o", repo: "r", number: 1, event: /** @type {any} */ ("MERGE") }),
    ).rejects.toBeInstanceOf(TypeError);
  });
});

describe("markNotificationRead", () => {
  it("PATCHes the thread endpoint and returns ok", async () => {
    fetchImpl = () => Promise.resolve(fakeResponse({ status: 205, headers: RATE_HEADERS }));

    const client = newClient();
    const result = await client.markNotificationRead("12345");

    expect(result.status).toBe("ok");
    expect(calls[0].url).toBe("https://api.github.com/notifications/threads/12345");
    expect(calls[0].init.method).toBe("PATCH");
  });
});

describe("lastRateLimit", () => {
  it("returns null before any call, then the most-recent reading", async () => {
    const client = newClient();
    expect(client.lastRateLimit()).toBeNull();

    fetchImpl = () =>
      Promise.resolve(
        fakeResponse({
          status: 200,
          body: [],
          headers: RATE_HEADERS,
        }),
      );
    await client.listNotifications();
    const rl = client.lastRateLimit();
    expect(rl).not.toBeNull();
    expect(rl.limit).toBe(5000);
    expect(rl.remaining).toBe(4998);
  });
});
