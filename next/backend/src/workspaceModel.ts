// Per-workspace resident model: file decoration map, HEAD info, monotonic
// version counter, event journal, subscriber list, and the chokidar-driven
// drain loop that emits coherent bursts of notifications.
//
// One model per open workspace. Lifetimes match the workspace's: created at
// `workspace.open`, disposed at `workspace.close`. WebSocket connections
// attach as subscribers via `subscribe`; disconnect detaches them (via
// `removeSubscriberAcrossAll`).
//
// See docs/design/mobile-code-platform.md §4.1 — "Event delivery contract"
// and "Journal and resync" — for the wire contract this implementation
// satisfies. The conventions invariant we lean on hardest: only one drain
// runs at a time per workspace, and drains emit events in causal order
// (head → tree → decoration → commit) so the client never sees a decoration
// for a path that doesn't exist yet.

import { readFile } from "node:fs/promises";
import { join, relative, resolve, sep } from "node:path";
import { type FSWatcher, watch } from "chokidar";
import ignoreFactory, { type Ignore } from "ignore";
import type { WebSocket } from "ws";
import {
  isGitRepo,
  readCommitSubject,
  readHeadInfo,
  readStatus,
  revList,
  type GitHeadInfo,
  type GitStatusEntry,
} from "./git.js";
import { sendNotification } from "./rpc.js";

// ---- Tunable module constants (see CLAUDE.md first principles #4) ----

/// Maximum number of journal entries we retain per workspace before old ones
/// fall off. A subscribe call whose `sinceVersion` lies inside this window
/// gets a replay; otherwise we drop to snapshot mode.
const JOURNAL_MAX_EVENTS = 200;
/// Maximum age of journal entries. Even with low event volume, anything
/// older than this is considered stale (an idle client that comes back
/// after this window gets a snapshot, not a replay of long-forgotten
/// work). 5 minutes covers a phone backgrounded across a coffee break;
/// snapshot cost is small but the UI flicker on every brief disconnect
/// is annoying when it's too short.
const JOURNAL_MAX_AGE_MS = 300_000;
/// Debounce window for coalescing watcher events. .git/HEAD writes bypass
/// this to make branch switches feel instant.
const DRAIN_DEBOUNCE_MS = 100;
/// Tree watcher poll interval (chokidar's `interval`) — only used as a
/// fallback on filesystems where native events don't work; on Linux inotify
/// drives it and this knob is mostly informational.
const TREE_WATCH_INTERVAL_MS = 250;

// ---- Event types (mirror the wire protocol) ----

export type DecorationStatus = "M" | "A" | "D" | "?" | "U" | null;

export interface DecorationEntry {
  path: string;
  status: DecorationStatus;
}

export interface TreeRename {
  from: string;
  to: string;
}

export type JournalEvent =
  | {
      kind: "head.changed";
      version: number;
      ts: number;
      branch: string;
      headSha: string;
      ahead: number;
      behind: number;
    }
  | {
      kind: "tree.delta";
      version: number;
      ts: number;
      added: string[];
      removed: string[];
      renamed: TreeRename[];
    }
  | {
      kind: "decoration.delta";
      version: number;
      ts: number;
      entries: DecorationEntry[];
    }
  | {
      kind: "commit.added";
      version: number;
      ts: number;
      branch: string;
      sha: string;
      subject: string;
    };

export interface SubscribeRequest {
  sinceVersion?: number;
  paths?: string[];
}

export interface SubscribeResult {
  mode: "current" | "replay" | "snapshot";
  baseVersion: number;
}

/// A connection that has called `workspace.subscribe` for this workspace.
/// We track the ws + a path filter (currently unhonored — see
/// CLAUDE.md first principles #5) + the version we last delivered, so future
/// per-subscriber filtering work has a place to live.
interface Subscriber {
  ws: WebSocket;
  // TODO: honor paths filter — see CLAUDE.md first principles #5
  paths: string[] | null;
  lastDeliveredVersion: number;
}

export interface WorkspaceModelOptions {
  workspaceId: string;
  root: string;
  /// Optional callback fired when a head.changed or tree.delta event is
  /// emitted. The process-global diff cache uses this to drop entries whose
  /// content has invalidated. Defined as a hook (rather than the model
  /// reaching into ProcessState) so the model stays a self-contained unit
  /// with no upward dependency.
  onInvalidate?: () => void;
}

export class WorkspaceModel {
  public readonly workspaceId: string;
  public readonly root: string;
  private readonly onInvalidate: (() => void) | null;

  // Latest decoration state per relative path. Cleared entries are kept as
  // `null` only inside deltas — the map itself drops them on apply.
  private fileStatus = new Map<string, "M" | "A" | "D" | "?" | "U">();
  private head: GitHeadInfo | null = null;
  private version = 0;
  private journal: JournalEvent[] = [];
  private subscribers: Subscriber[] = [];

  // Chokidar handles. Created lazily on `init()` so tests that don't need
  // watchers can skip them.
  private treeWatcher: FSWatcher | null = null;
  private gitWatcher: FSWatcher | null = null;
  private gitignoreMatcher: Ignore = ignoreFactory();
  private gitignoreLoaded = false;
  /// Whether this workspace is a git repo. Decided once at `init()`.
  /// v0 decision: we do NOT re-detect later — a workspace opened on a
  /// non-repo stays non-repo for its lifetime. If the user runs `git init`
  /// they currently need to close + reopen the workspace. Re-init on `.git/`
  /// materialization is a v1 nicety.
  private isRepo = false;

  // Drain state.
  private drainTimer: ReturnType<typeof setTimeout> | null = null;
  private drainRunning = false;
  private drainQueued = false;
  /// True when a `.git/HEAD` write came in — bypass the debounce so the next
  /// drain fires synchronously.
  private bypassDebounce = false;

  // Pending tree-watcher events, coalesced inside a drain window.
  private pendingTreeAdds = new Set<string>();
  private pendingTreeRemoves = new Set<string>();

  constructor(opts: WorkspaceModelOptions) {
    this.workspaceId = opts.workspaceId;
    this.root = opts.root;
    this.onInvalidate = opts.onInvalidate ?? null;
  }

  /// One-time setup. Loads .gitignore, computes initial HEAD + status,
  /// installs watchers. Called from WorkspaceRegistry.open after the
  /// ActiveWorkspace is constructed.
  public async init(): Promise<void> {
    await this.reloadGitignore();
    this.isRepo = await isGitRepo(this.root);
    if (this.isRepo) {
      this.head = await readHeadInfo(this.root);
      const entries = await readStatus(this.root);
      for (const e of entries) {
        this.fileStatus.set(e.path, e.status);
      }
    }
    // Bump version to 1 even on empty workspaces so a subscribe-current
    // is distinguishable from "no model yet".
    this.version = 1;
    this.startWatchers();
  }

  // ---------- Subscription / journal ----------

  public subscribe(ws: WebSocket, req: SubscribeRequest): SubscribeResult {
    // B2: a second subscribe from the same socket replaces the prior
    // subscriber rather than stacking — otherwise every push is delivered
    // twice. Reconnect-then-resubscribe-before-prior-unsubscribe-settles is a
    // real wire pattern, not theoretical.
    this.subscribers = this.subscribers.filter((s) => s.ws !== ws);

    const paths =
      req.paths !== undefined && req.paths.length > 0 ? [...req.paths] : null;
    const baseVersion = this.version;
    const since = req.sinceVersion;
    // The subscriber object is reused across modes. lastDeliveredVersion is
    // set per-mode below — replay defers registration so the slice can be
    // delivered before live fan-out is allowed to start; the other modes
    // register synchronously.
    const subscriber: Subscriber = {
      ws,
      paths,
      lastDeliveredVersion: baseVersion,
    };

    if (since === undefined) {
      this.subscribers.push(subscriber);
      // No baseline → caller wants a fresh snapshot.
      return { mode: "snapshot", baseVersion };
    }
    if (since === baseVersion) {
      this.subscribers.push(subscriber);
      return { mode: "current", baseVersion };
    }
    if (since > baseVersion) {
      this.subscribers.push(subscriber);
      // Client claims to have seen the future. Resnapshot to be safe.
      return { mode: "snapshot", baseVersion };
    }
    // Can we replay? journal[0] is the oldest retained event.
    const oldest =
      this.journal.length > 0 ? this.journal[0].version : baseVersion + 1;
    if (since >= oldest - 1) {
      // B1: hold the subscriber OUT of `this.subscribers` until replay has
      // been delivered. Live emit() can't fan out to us during the gap
      // (we're not registered), so the slice arrives intact and in version
      // order. We register inside the same microtask, atomically with the
      // final lastDeliveredVersion bump.
      //
      // Drains can't interleave because chokidar's debounced drain fires on
      // a macrotask (setTimeout); the microtask we queue here runs before
      // any macrotask. If a drain SOMEHOW slips in (e.g. drainOnce called
      // synchronously from a test that already had work queued), the journal
      // still has the slice we captured here — `slice` is a synchronous
      // copy — and we re-walk it deterministically.
      const slice = this.journal.filter((e) => e.version > since);
      queueMicrotask(() => {
        for (const ev of slice) {
          this.emitOne(ws, ev);
        }
        // Register at the end so live emit only sees us starting from
        // events that genuinely came after we joined.
        subscriber.lastDeliveredVersion = this.version;
        this.subscribers.push(subscriber);
      });
      return { mode: "replay", baseVersion };
    }
    // Gap too large → snapshot. Register so the upcoming decoration.snapshot
    // and any subsequent drains reach us.
    this.subscribers.push(subscriber);
    return { mode: "snapshot", baseVersion };
  }

  /// Build the decoration snapshot the client gets after a subscribe in
  /// "snapshot" mode. Only non-clean files; clean entries are implied.
  public buildDecorationSnapshot(): DecorationEntry[] {
    const out: DecorationEntry[] = [];
    for (const [path, status] of this.fileStatus) {
      out.push({ path, status });
    }
    return out;
  }

  public currentVersion(): number {
    return this.version;
  }

  /// Current HEAD info, or null on non-git workspaces. Used by the subscribe
  /// handler to seed the client's branch/ahead/behind state on initial
  /// snapshot — the drain loop only fires `head.changed` on *changes*, so a
  /// fresh subscribe would otherwise never learn the current branch.
  public currentHead(): {
    branch: string | null;
    headSha: string | null;
    ahead: number;
    behind: number;
  } | null {
    if (!this.isRepo || this.head === null) return null;
    return {
      branch: this.head.branch,
      headSha: this.head.headSha,
      ahead: this.head.ahead,
      behind: this.head.behind,
    };
  }

  /// Number of active subscribers. Exposed for tests asserting auto-cleanup
  /// on socket close; not part of the wire surface.
  public subscriberCount(): number {
    return this.subscribers.length;
  }

  /// Maximum events the in-memory journal retains. Exposed so tests can
  /// drive overflow conditions deterministically.
  public static journalMaxEvents(): number {
    return JOURNAL_MAX_EVENTS;
  }

  /// Synthesize a decoration.delta event for tests that need to fill the
  /// journal past `journalMaxEvents` without spawning hundreds of file
  /// operations. Production code never calls this.
  /// @internal
  public _testEmitSyntheticDecorationEvent(path: string): void {
    this.emit({
      kind: "decoration.delta",
      version: this.nextVersion(),
      ts: Date.now(),
      entries: [{ path, status: "M" }],
    });
  }

  public removeSubscriber(ws: WebSocket): void {
    this.subscribers = this.subscribers.filter((s) => s.ws !== ws);
  }

  public unsubscribe(ws: WebSocket): void {
    this.removeSubscriber(ws);
  }

  // ---------- Drain loop ----------

  /// Schedule a drain to run after the debounce window. Tree watcher events
  /// hit this path; .git/HEAD writes call `scheduleDrainImmediate` instead.
  public scheduleDrain(): void {
    if (this.drainTimer !== null) return;
    if (this.bypassDebounce) {
      this.bypassDebounce = false;
      this.drainNow();
      return;
    }
    this.drainTimer = setTimeout(() => {
      this.drainTimer = null;
      this.drainNow();
    }, DRAIN_DEBOUNCE_MS);
  }

  public scheduleDrainImmediate(): void {
    if (this.drainTimer !== null) {
      clearTimeout(this.drainTimer);
      this.drainTimer = null;
    }
    this.bypassDebounce = false;
    this.drainNow();
  }

  /// Public hook so tests (and the .gitignore-changed path) can force an
  /// immediate drain and await its completion. Returns when no drain is
  /// in flight.
  public async drainOnce(): Promise<void> {
    if (this.drainTimer !== null) {
      clearTimeout(this.drainTimer);
      this.drainTimer = null;
    }
    await this.runDrainBody();
    // If something queued during the drain, run again to flush.
    if (this.drainQueued) {
      this.drainQueued = false;
      await this.runDrainBody();
    }
  }

  private drainNow(): void {
    if (this.drainRunning) {
      // Serialize: queue one follow-up. We don't queue more than one because
      // a single drain handles every watcher event observed since the prior
      // one finished.
      this.drainQueued = true;
      return;
    }
    void this.runDrainBody().then(() => {
      if (this.drainQueued) {
        this.drainQueued = false;
        this.drainNow();
      }
    });
  }

  private async runDrainBody(): Promise<void> {
    this.drainRunning = true;
    try {
      await this.runDrainBodyInner();
    } catch (err) {
      // M2: any throw from porcelain parsing / status diffing aborts the
      // drain. Operational error, not user-facing — log and reschedule one
      // follow-up so the next watcher tick (or this one's queued retry)
      // re-attempts. We don't add retry counters in v0; if the drain stays
      // broken every event will keep logging until someone notices.
      console.error(
        `[workspaceModel] drain failed for ${this.root}:`,
        err,
      );
      // Reschedule via the queued flag — the trailing block in `drainNow`
      // will pick it up after we mark drainRunning=false.
      this.drainQueued = true;
    } finally {
      this.drainRunning = false;
      this.pruneJournal();
    }
  }

  private async runDrainBodyInner(): Promise<void> {
    // Non-repo workspace: nothing to read from git. Tree watcher still fires
    // here so we drain pending tree events to keep the queue bounded, but we
    // do not spawn `git status` / `git rev-parse` / `git rev-list`.
    if (!this.isRepo) {
      this.pendingTreeAdds.clear();
      this.pendingTreeRemoves.clear();
      return;
    }

    const previousHead = this.head;
    const newHead = await readHeadInfo(this.root);
    // 1. HEAD diff
    let headChanged = false;
    if (!headInfoEqual(previousHead, newHead)) {
      this.head = newHead;
      headChanged = true;
    }
    if (headChanged && newHead !== null) {
      this.emit({
        kind: "head.changed",
        version: this.nextVersion(),
        ts: Date.now(),
        branch: newHead.branch,
        headSha: newHead.headSha,
        ahead: newHead.ahead,
        behind: newHead.behind,
      });
    }

    // 2. Tree delta — coalesce add/remove.
    const adds = [...this.pendingTreeAdds];
    const removes = [...this.pendingTreeRemoves];
    this.pendingTreeAdds.clear();
    this.pendingTreeRemoves.clear();
    // add+delete inside the same window cancels out.
    const addSet = new Set(adds);
    const removeSet = new Set(removes);
    const filteredAdds = adds.filter((p) => !removeSet.has(p));
    const filteredRemoves = removes.filter((p) => !addSet.has(p));
    // Rename detection lives in the status pass below — porcelain v2's
    // rename code (kind "2") tells us which (from, to) pairs to surface.
    const renamedPairs: TreeRename[] = [];

    // 3. Decoration delta. Always re-read status; coalescing tree events
    // doesn't avoid this because a watcher can drop kernel events under
    // pressure and we want to converge eventually.
    const statusEntries = await readStatus(this.root);
    // Surface renames detected by git status as tree renames as well.
    for (const e of statusEntries) {
      if (e.renamedFrom !== undefined && e.renamedFrom.length > 0) {
        renamedPairs.push({ from: e.renamedFrom, to: e.path });
      }
    }

    if (
      filteredAdds.length > 0 ||
      filteredRemoves.length > 0 ||
      renamedPairs.length > 0
    ) {
      this.emit({
        kind: "tree.delta",
        version: this.nextVersion(),
        ts: Date.now(),
        added: filteredAdds,
        removed: filteredRemoves,
        renamed: renamedPairs,
      });
    }

    const decorationDelta = this.diffStatus(statusEntries);
    if (decorationDelta.length > 0) {
      this.emit({
        kind: "decoration.delta",
        version: this.nextVersion(),
        ts: Date.now(),
        entries: decorationDelta,
      });
    }

    // 4. Commit advance on current branch.
    if (
      headChanged &&
      newHead !== null &&
      previousHead !== null &&
      newHead.branch === previousHead.branch &&
      previousHead.headSha.length > 0 &&
      newHead.headSha.length > 0 &&
      previousHead.headSha !== newHead.headSha
    ) {
      const shas = await revList(
        this.root,
        previousHead.headSha,
        newHead.headSha,
      );
      for (const sha of shas) {
        const subject = await readCommitSubject(this.root, sha);
        this.emit({
          kind: "commit.added",
          version: this.nextVersion(),
          ts: Date.now(),
          branch: newHead.branch,
          sha,
          subject,
        });
      }
    }
  }

  private diffStatus(entries: GitStatusEntry[]): DecorationEntry[] {
    const next = new Map<string, "M" | "A" | "D" | "?" | "U">();
    for (const e of entries) next.set(e.path, e.status);
    const out: DecorationEntry[] = [];
    // New / changed
    for (const [path, status] of next) {
      const prev = this.fileStatus.get(path);
      if (prev !== status) {
        out.push({ path, status });
      }
    }
    // Cleared
    for (const [path] of this.fileStatus) {
      if (!next.has(path)) {
        out.push({ path, status: null });
      }
    }
    // Apply to model
    this.fileStatus = next;
    return out;
  }

  // ---------- Watchers ----------

  private startWatchers(): void {
    // Tree watcher.
    this.treeWatcher = watch(this.root, {
      ignoreInitial: true,
      followSymlinks: false,
      interval: TREE_WATCH_INTERVAL_MS,
      // Drop noisy paths at the watcher level — gitignore + .git internals.
      // This trims the queue before it reaches our drain.
      ignored: (path: string) => this.isWatcherIgnored(path),
      depth: 99,
    });
    this.treeWatcher.on("add", (p) => this.recordTreeAdd(p));
    this.treeWatcher.on("addDir", (p) => this.recordTreeAdd(p));
    this.treeWatcher.on("unlink", (p) => this.recordTreeRemove(p));
    this.treeWatcher.on("unlinkDir", (p) => this.recordTreeRemove(p));
    this.treeWatcher.on("change", () => this.scheduleDrain());
    // chokidar errors should not crash the backend — log and let the next
    // tick retry. Most often this is EMFILE under repo bursts.
    this.treeWatcher.on("error", (err) => {
      console.error(
        `[workspaceModel] tree watcher error in ${this.root}:`,
        err,
      );
    });

    // Git metadata watcher — only useful on actual repos. Skipping it on
    // non-repos avoids spurious watches on `.git/` paths that don't exist
    // (chokidar logs "missing" errors otherwise) and is the symmetric
    // counterpart to skipping git CLI invocations in the drain.
    if (!this.isRepo) return;
    const gitDir = join(this.root, ".git");
    this.gitWatcher = watch(
      [
        join(gitDir, "HEAD"),
        join(gitDir, "index"),
        join(gitDir, "MERGE_HEAD"),
        join(gitDir, "FETCH_HEAD"),
        join(gitDir, "packed-refs"),
        join(gitDir, "refs", "heads"),
      ],
      {
        ignoreInitial: true,
        followSymlinks: false,
        depth: 99,
      },
    );
    const onGitChange = (path: string): void => {
      if (path.endsWith(`${sep}HEAD`) || path.endsWith("/HEAD")) {
        // Branch switch — bypass debounce.
        this.bypassDebounce = true;
        this.scheduleDrainImmediate();
        return;
      }
      this.scheduleDrain();
    };
    this.gitWatcher.on("add", onGitChange);
    this.gitWatcher.on("change", onGitChange);
    this.gitWatcher.on("unlink", onGitChange);
    this.gitWatcher.on("error", (err) => {
      console.error(
        `[workspaceModel] git watcher error in ${this.root}:`,
        err,
      );
    });
  }

  /// True when this absolute path should be excluded from the tree watcher.
  /// We rebuild the matcher on `.gitignore` changes; this function is hot
  /// on every watcher event so it's a synchronous lookup.
  private isWatcherIgnored(absPath: string): boolean {
    // `.git` is always excluded — its contents are watched separately and
    // including them here would generate a flood of irrelevant events.
    const rel = relative(this.root, absPath);
    if (rel === "" || rel === ".") return false;
    // The `${sep}` branch is the native one: on Linux it matches a literal
    // `.git/` prefix, on Windows (where `sep === '\\'`) it matches `.git\`.
    // The explicit `.git/` branch is a cheap defensive check for the
    // Windows-only case where chokidar occasionally hands us POSIX-style
    // paths via the underlying `readdirp`; it's a no-op on Linux because
    // `sep === '/'` already covered it.
    if (rel === ".git" || rel.startsWith(`.git${sep}`) || rel.startsWith(".git/")) {
      return true;
    }
    if (!this.gitignoreLoaded) return false;
    // `ignore` expects forward slashes regardless of platform.
    const posix = rel.split(sep).join("/");
    return this.gitignoreMatcher.ignores(posix);
  }

  private async reloadGitignore(): Promise<void> {
    this.gitignoreMatcher = ignoreFactory();
    this.gitignoreLoaded = false;
    try {
      const content = await readFile(join(this.root, ".gitignore"), "utf8");
      this.gitignoreMatcher.add(content);
      this.gitignoreLoaded = true;
    } catch {
      // Missing .gitignore is fine.
    }
  }

  private recordTreeAdd(absPath: string): void {
    const rel = relative(this.root, absPath);
    if (rel.length === 0) return;
    this.pendingTreeAdds.add(rel);
    // `.gitignore` write — rebuild matcher and force a re-scan.
    if (rel === ".gitignore") {
      void this.reloadGitignore().then(() => this.scheduleDrain());
      return;
    }
    this.scheduleDrain();
  }

  private recordTreeRemove(absPath: string): void {
    const rel = relative(this.root, absPath);
    if (rel.length === 0) return;
    this.pendingTreeRemoves.add(rel);
    if (rel === ".gitignore") {
      void this.reloadGitignore().then(() => this.scheduleDrain());
      return;
    }
    this.scheduleDrain();
  }

  // ---------- Journaling / emission ----------

  private nextVersion(): number {
    this.version += 1;
    return this.version;
  }

  private emit(ev: JournalEvent): void {
    this.journal.push(ev);
    this.pruneJournal();
    if (ev.kind === "head.changed" || ev.kind === "tree.delta") {
      if (this.onInvalidate !== null) this.onInvalidate();
    }
    for (const sub of this.subscribers) {
      // Gate on lastDeliveredVersion so a subscribe-replay's microtask can
      // safely re-walk the journal slice without duplicating events that
      // were already live-fanned in the same tick. See subscribe() for the
      // matching gate on the replay side.
      if (ev.version <= sub.lastDeliveredVersion) continue;
      this.emitOne(sub.ws, ev);
      sub.lastDeliveredVersion = ev.version;
    }
  }

  private emitOne(ws: WebSocket, ev: JournalEvent): void {
    const method = methodForEvent(ev.kind);
    const params = paramsForEvent(this.workspaceId, ev);
    sendNotification(ws, method, params);
  }

  private pruneJournal(): void {
    const now = Date.now();
    while (
      this.journal.length > 0 &&
      (this.journal.length > JOURNAL_MAX_EVENTS ||
        now - this.journal[0].ts > JOURNAL_MAX_AGE_MS)
    ) {
      this.journal.shift();
    }
  }

  // ---------- Lifecycle ----------

  public async dispose(): Promise<void> {
    if (this.drainTimer !== null) {
      clearTimeout(this.drainTimer);
      this.drainTimer = null;
    }
    this.subscribers = [];
    if (this.treeWatcher !== null) {
      await this.treeWatcher.close();
      this.treeWatcher = null;
    }
    if (this.gitWatcher !== null) {
      await this.gitWatcher.close();
      this.gitWatcher = null;
    }
  }

  // ---------- Test hooks ----------

  /// Resolve a workspace-relative path to absolute. Used by callers that need
  /// to read files under the workspace without re-importing path logic.
  public absolutePath(rel: string): string {
    return resolve(this.root, rel);
  }
}

function headInfoEqual(a: GitHeadInfo | null, b: GitHeadInfo | null): boolean {
  if (a === null && b === null) return true;
  if (a === null || b === null) return false;
  return (
    a.branch === b.branch &&
    a.headSha === b.headSha &&
    a.ahead === b.ahead &&
    a.behind === b.behind
  );
}

function methodForEvent(kind: JournalEvent["kind"]): string {
  switch (kind) {
    case "head.changed":
      return "workspace.head.changed";
    case "tree.delta":
      return "workspace.tree.delta";
    case "decoration.delta":
      return "workspace.decoration.delta";
    case "commit.added":
      return "workspace.commit.added";
  }
}

function paramsForEvent(workspaceId: string, ev: JournalEvent): unknown {
  switch (ev.kind) {
    case "head.changed":
      return {
        workspaceId,
        branch: ev.branch,
        headSha: ev.headSha,
        ahead: ev.ahead,
        behind: ev.behind,
        version: ev.version,
      };
    case "tree.delta":
      return {
        workspaceId,
        added: ev.added,
        removed: ev.removed,
        renamed: ev.renamed,
        version: ev.version,
      };
    case "decoration.delta":
      return {
        workspaceId,
        entries: ev.entries,
        version: ev.version,
      };
    case "commit.added":
      return {
        workspaceId,
        branch: ev.branch,
        sha: ev.sha,
        subject: ev.subject,
        version: ev.version,
      };
  }
}

