// PR Companion — Phase 1 skeleton.
//
// What this slice ships:
//   * Two registered panels (`inbox` + `detail`) per the resolved design
//     (single fixed detail panel + in-plugin nav — see design doc §
//     "Resolved design choices" #2).
//   * `gh auth token` resolution on every activation, plus a single
//     `/user` call to surface the authenticated login in the placeholder.
//     The token is held only in auth.js's return value and in the
//     module-scoped `currentAuth` object below; it is never read,
//     logged, persisted, or serialized into the widget tree. Phase 2's
//     github.js will receive it explicitly when it lands.
//   * Workspace detection: on activation and on every
//     `onWorkspaceActivated` callback we run `git remote get-url origin`
//     inside the workspace root and parse the result against the
//     SSH-or-HTTPS GitHub remote regex. The parse result is cached by
//     workspace id and invalidated when the user switches workspaces.
//
// What is intentionally NOT in this slice (see design doc "Implementation
// phases" — Phase 2-5):
//   * Any GitHub call beyond `/user`. No /notifications, no PR fetches.
//   * Scope chip / scope switcher action sheet.
//   * Swipe-to-dismiss, persistence, undo.
//   * PR detail rendering (the detail panel is a stub).
//   * Review actions, comment sheets, checks tab.
//   * Background polling, notification fan-out.
//
// File-layout note (design doc §"File layout"): this plugin will grow to
// include github.js / state.js / render/* in later phases. Phase 1
// keeps the directory to the four files required for a runnable shell.

import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { createPlugin, ui } from "@openvsmobile/sdk";

import { resolveGhAuth } from "./auth.js";

const execFileAsync = promisify(execFile);

const INBOX_PANEL = "inbox";
const DETAIL_PANEL = "detail";

const GIT_TIMEOUT_MS = 5000;

// Regex per design doc § "Workspace model": SSH (`git@github.com:o/r`)
// and HTTPS (`https://github.com/o/r[.git]`) forms only. Anything else
// — gitlab.com, internal mirrors, no remote at all — falls through to
// the "(not a GitHub repo)" branch and the inbox banner explains why.
const GITHUB_REMOTE_RE =
  /^(?:git@github\.com:|https?:\/\/github\.com\/)([^/]+)\/([^/.]+?)(?:\.git)?$/;

/**
 * Parse a `git remote get-url origin` output into `{owner, repo}`, or
 * `null` if the remote isn't a GitHub URL we recognize.
 *
 * @param {string} remoteUrl
 * @returns {{ owner: string, repo: string } | null}
 */
export function parseGithubRemote(remoteUrl) {
  if (typeof remoteUrl !== "string") return null;
  const trimmed = remoteUrl.trim();
  if (trimmed.length === 0) return null;
  const m = GITHUB_REMOTE_RE.exec(trimmed);
  if (m === null) return null;
  return { owner: m[1], repo: m[2] };
}

/**
 * Spawn `git -C <root> remote get-url origin` and parse the result.
 * Returns `null` for any failure mode (no git, no remote, non-GitHub
 * remote). Phase 1 doesn't need to distinguish the three — they all
 * render the same "not a GitHub repo" placeholder.
 *
 * @param {string} root
 * @returns {Promise<{ owner: string, repo: string } | null>}
 */
async function detectRepoForRoot(root) {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["-C", root, "remote", "get-url", "origin"],
      { timeout: GIT_TIMEOUT_MS },
    );
    return parseGithubRemote(stdout.toString());
  } catch {
    return null;
  }
}

// Per-workspace-id cache of the parsed repo. Keyed by `WorkspaceRef.id`
// (UUID, stable across reconnect), invalidated on every
// `onWorkspaceActivated` callback by simply overwriting the entry for
// the new workspace's id. We never grow this beyond a handful of
// entries in practice — workspaces are session-scoped — so an explicit
// eviction policy is unnecessary for Phase 1.
const repoByWorkspace = new Map();

// Latest snapshot used by render(); rewritten by hydrate() before every
// re-render. Holding these at module scope keeps render() pure on its
// inputs without threading a state object through every call site.
let currentAuth = null;
let currentWorkspace = null;
let currentRepo = null;

function authBanner(auth) {
  if (auth.status === "missing") {
    return ui.section({
      id: "prcomp-auth-missing",
      children: [
        ui.banner({
          id: "prcomp-auth-missing-banner",
          title: "GitHub CLI not installed",
          body: "PR Companion uses the gh CLI to obtain a GitHub token. Install it on the host where the openvsmobile backend runs.",
          accent: "danger",
        }),
        ui.codeBlock({
          id: "prcomp-auth-missing-hint",
          code: [
            "# macOS",
            "brew install gh",
            "",
            "# Debian / Ubuntu",
            "sudo apt install gh",
            "",
            "# Arch",
            "sudo pacman -S github-cli",
          ].join("\n"),
          language: "sh",
        }),
      ],
    });
  }
  if (auth.status === "unauthed" || auth.status === "tokenInvalid") {
    const title =
      auth.status === "tokenInvalid"
        ? "GitHub rejected your token"
        : "GitHub CLI is not signed in";
    return ui.section({
      id: "prcomp-auth-unauthed",
      children: [
        ui.banner({
          id: "prcomp-auth-unauthed-banner",
          title,
          body: "Run gh auth login in the terminal to (re)authenticate. The plugin re-reads the token on every activation.",
          accent: "danger",
        }),
        ui.codeBlock({
          id: "prcomp-auth-unauthed-hint",
          code: "gh auth login",
          language: "sh",
        }),
      ],
    });
  }
  if (auth.status === "offline") {
    return ui.banner({
      id: "prcomp-auth-offline-banner",
      title: "GitHub unreachable",
      body: "Retrying on next activation.",
      accent: "info",
    });
  }
  return null;
}

function buildInboxTree() {
  // Auth-failure paths short-circuit the rest of the panel — until we
  // have a known login + token, there is no useful inbox content to
  // render. Wrapping the banner in a single-child column keeps the root
  // shape identical regardless of which branch fired.
  if (currentAuth === null || currentAuth.status !== "ok") {
    // onActivate awaits resolveGhAuth() before calling render(), so in
    // normal flow currentAuth is never null here. The fallback exists
    // only so this builder is safely callable from a future call site
    // (e.g. a manual re-render before activation completes).
    const banner = authBanner(currentAuth ?? { status: "offline", error: new Error("auth not resolved") });
    return ui.column({
      id: "prcomp-inbox-root",
      gap: "md",
      children: banner !== null ? [banner] : [],
    });
  }

  const login = currentAuth.user.login;

  // Three success-shaped sub-branches, each a single Text row per the
  // Phase-1 placeholder contract. Resist any urge to add extra
  // affordances here — Phase 2 owns the inbox UI in full.
  let greeting;
  if (currentWorkspace === null) {
    greeting = `Hello, @${login} — no workspace active`;
  } else if (currentRepo !== null) {
    greeting = `Hello, @${login} — workspace: ${currentRepo.owner}/${currentRepo.repo}`;
  } else {
    greeting = `Hello, @${login} — workspace: ${currentWorkspace.label} (not a GitHub repo; will show all repos in Phase 2)`;
  }

  return ui.column({
    id: "prcomp-inbox-root",
    gap: "md",
    children: [
      ui.text({ id: "prcomp-inbox-greeting", text: greeting }),
    ],
  });
}

function buildDetailTree() {
  return ui.section({
    id: "prcomp-detail-section",
    title: "PR Detail",
    children: [
      ui.text({
        id: "prcomp-detail-placeholder",
        text: "Open a PR from the Inbox tab. (Phase 3)",
      }),
    ],
  });
}

function render(ctx) {
  ctx.renderPanel(INBOX_PANEL, buildInboxTree());
  ctx.renderPanel(DETAIL_PANEL, buildDetailTree());
}

async function hydrateWorkspace(workspace) {
  currentWorkspace = workspace;
  if (workspace === null) {
    currentRepo = null;
    return;
  }
  if (repoByWorkspace.has(workspace.id)) {
    currentRepo = repoByWorkspace.get(workspace.id);
    return;
  }
  const repo = await detectRepoForRoot(workspace.root);
  repoByWorkspace.set(workspace.id, repo);
  currentRepo = repo;
}

const plugin = createPlugin({
  async onActivate(ctx) {
    // Order: workspace first (so a slow git spawn doesn't block the
    // first paint behind /user latency), then auth, then render. The
    // first render only happens after both are resolved — there is no
    // useful interim state (no login, no workspace label) worth
    // painting before then.
    const workspace = await ctx.currentWorkspace();
    await hydrateWorkspace(workspace);
    currentAuth = await resolveGhAuth();
    render(ctx);
  },
  async onWorkspaceActivated(ctx, workspace) {
    // Invalidate the cached repo for the workspace we're entering — the
    // remote could have been re-pointed in the terminal between
    // activations. Cheap: one process spawn per workspace switch.
    if (workspace !== null) {
      repoByWorkspace.delete(workspace.id);
    }
    await hydrateWorkspace(workspace);
    render(ctx);
  },
  onUiEvent(ctx, event) {
    // No interactive surfaces in Phase 1 — Phase 2's inbox introduces
    // the scope chip, the tab bar, and swipe events. Until then we
    // log unknown events so the wire path is observable without
    // pretending to handle anything.
    ctx.log(
      "warn",
      `pr-companion: unhandled ui.event panel=${event.panelId} node=${event.nodeId} type=${event.type}`,
    );
  },
});

plugin.run();
