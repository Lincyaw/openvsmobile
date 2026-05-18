// PR Companion — Phase 6 notification-fan-out pure helper.
//
// Computes the per-poll diff between "what the inbox knows about" and
// "what we have already shown to the user as a system notification",
// returning both the new toast payloads to fire AND the updated
// `shownNotifIds` array to persist. Lives off to the side rather than
// inline in index.js so it can be unit-tested without the SDK runtime
// (index.js calls plugin.run() at module load — see its bottom of file
// comment).
//
// Mapping rules (per Phase 6C spec):
//
//   * Skip when id is in `dismissedSet` — user already swiped that one
//     away, fanning it out as a toast contradicts the dismiss.
//   * Skip when id is already in `shownSet` — we've fanned it before.
//   * On cold start (empty `shownSet`), do NOT fire toasts; instead pre-
//     populate `shownAfter` with every current id. The next poll then
//     only fans out genuinely-new ids. This is per spec option (a) —
//     simpler and more durable across restart-pause-restart than a
//     "first poll" flag. The cold-start signal IS empty `shownSet`,
//     which collapses correctly to "first activation" because the
//     persisted state is the source of truth, not a session flag.
//
//   * title is reason-driven, body is `<owner>/<repo> #<n> — <title>`.
//   * groupKey "pr-companion" — lets the OS collapse a burst into one
//     stack rather than rendering N separate toasts.
//   * ttl 3600s — old ids in the host's notification store expire after
//     an hour. Beats stale "Review requested" toasts piling up if the
//     phone wasn't visible.
//   * No `action` field — deep-linking from a notification into the
//     plugin's inbox panel requires extending `NotificationAction`
//     (currently {open-url, copy, open-workspace}); that's a separate
//     platform change, deferred. The toast is informational only.

import { parsePullUrl } from "./inbox.js";

/**
 * Wire-stable group key. Mirrors the design-doc spec for tag-based
 * dedup ("pr-companion:${notificationId}" form was speculative; the
 * NotificationInput's `groupKey` is the canonical collapse key, and
 * one bucket per plugin matches what the host's notification panel
 * already groups on).
 */
export const FANOUT_GROUP_KEY = "pr-companion";

/**
 * Toast TTL in seconds — matches the spec ("set to ~3600 (1 hour) so
 * old ones expire from the host's store"). The host treats `ttl` as a
 * soft expiry hint; nothing breaks if a toast is read after expiry, it
 * just won't be re-surfaced when the user opens the notification
 * tray.
 */
export const FANOUT_TTL_SECONDS = 3600;

/**
 * Map a notification `reason` to the toast title. `info` for everything
 * — none of these are urgent enough for `warning`/`error`, but they
 * are not silent success-acknowledgements either. Matches the spec
 * mapping verbatim.
 *
 * @param {string} reason
 */
function titleForReason(reason) {
  switch (reason) {
    case "review_requested":
      return "Review requested";
    case "mention":
    case "team_mention":
      return "You were mentioned";
    case "assign":
      return "PR assigned to you";
    default:
      return "PR activity";
  }
}

/**
 * Format the toast body line. Returns `null` when the notification
 * can't be reduced to a `owner/repo #N — title` shape (e.g.
 * non-PullRequest subjects, or a `subject.url` we can't parse). The
 * caller treats `null` as "skip this id but still mark it shown" — we
 * don't want to re-attempt the same unparseable id every poll.
 *
 * @param {{ repository: { owner: string, name: string }, subject: { title: string, url: string, type: string } }} n
 */
function bodyForNotification(n) {
  if (n.subject?.type !== "PullRequest") return null;
  const ref = parsePullUrl(n.subject?.url ?? "");
  if (ref === null) return null;
  const title = typeof n.subject?.title === "string" ? n.subject.title : "";
  return `${ref.owner}/${ref.repo} #${ref.number} — ${title}`;
}

/**
 * @typedef {Object} ComputedToast
 * @property {string} notifId    — the GitHub notification id we just fanned out.
 *                                 Caller uses this to extend its in-memory shown-Set + persistedState.
 * @property {import("@openvsmobile/sdk").NotificationInput} input
 */

/**
 * @typedef {Object} ComputeResult
 * @property {ComputedToast[]} toasts       — toasts to fire (in arrival order).
 *                                            Empty on cold start.
 * @property {string[]}        idsToMark    — every id we should add to shownNotifIds.
 *                                            Includes BOTH fired-toast ids and
 *                                            cold-start "pre-populate" ids; the
 *                                            caller persists these unconditionally.
 * @property {boolean}         coldStart    — true when `shownSet` was empty going in.
 *                                            Useful for logging but not for control flow.
 */

/**
 * Pure: compute what to fan out + what to remember.
 *
 * @param {{
 *   notifications: Array<{ id: string, reason: string, repository: { owner: string, name: string, fullName: string }, subject: { title: string, url: string, type: string } }>,
 *   dismissedSet: Set<string>,
 *   shownSet: Set<string>,
 * }} params
 * @returns {ComputeResult}
 */
export function computeNotifFanout({ notifications, dismissedSet, shownSet }) {
  const coldStart = shownSet.size === 0;
  /** @type {ComputedToast[]} */
  const toasts = [];
  /** @type {string[]} */
  const idsToMark = [];

  for (const n of notifications) {
    if (typeof n?.id !== "string" || n.id.length === 0) continue;
    // The dismissed gate trumps everything, even on cold start: an id
    // the user already dismissed is one they explicitly don't want to
    // see again, and shouldn't get pre-populated into shownNotifIds
    // either — keeping it out leaves a future un-dismiss path (no such
    // path today, but the invariant costs nothing to maintain) able to
    // re-surface it as a "genuinely new" toast.
    if (dismissedSet.has(n.id)) continue;
    if (shownSet.has(n.id)) continue;

    if (coldStart) {
      // Pre-populate shownNotifIds without firing a toast. No body-parse
      // needed — we're just remembering the id so the next poll diffs
      // correctly. Unparseable ids still get marked here; otherwise
      // they'd be "genuinely new" on every restart.
      idsToMark.push(n.id);
      continue;
    }

    const body = bodyForNotification(n);
    if (body === null) {
      // Unparseable or non-PR subject. Mark as shown so we don't keep
      // trying to fan it out on every tick; the inbox renderer already
      // filters non-PR subjects out, so the user never sees these
      // either way.
      idsToMark.push(n.id);
      continue;
    }

    /** @type {import("@openvsmobile/sdk").NotificationInput} */
    const input = {
      // Host overrides to the plugin's manifest id; we pass an honest
      // value for clarity in audit logs / tests that read the wire
      // frame before the host scrubs it.
      source: "pr-companion",
      level: "info",
      title: titleForReason(n.reason),
      body,
      groupKey: FANOUT_GROUP_KEY,
      ttl: FANOUT_TTL_SECONDS,
    };
    toasts.push({ notifId: n.id, input });
    idsToMark.push(n.id);
  }

  return { toasts, idsToMark, coldStart };
}
