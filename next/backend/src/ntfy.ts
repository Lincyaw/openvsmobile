// ntfy sender — the background notification transport. Targets the user's
// own self-hosted ntfy server (single-line docker on their box). The ntfy
// Android app subscribes to a topic and renders system-tray notifications
// natively; this is the path that actually works on Chinese MIUI / EMUI /
// ColorOS devices.
//
// Initialization model:
//   * Reads $NTFY_URL (base, no trailing slash), $NTFY_TOPIC, optional
//     $NTFY_TOKEN.
//   * Either of the first two unset → initNtfySender() returns null and the
//     hub doesn't attach a sender. Deployments without ntfy keep working.
//   * On init, logs the publish URL so the user knows what to subscribe to
//     in the ntfy app.
//
// Wire shape: one HTTP POST per notification to `${NTFY_URL}/${NTFY_TOPIC}`.
// Body is the plain-text message (ntfy renders it as the notification
// content). Title, priority, click URL, and emoji tags ride in headers per
// the ntfy publish spec.
//
// The `Click` header carries `mobilecode://notifications/<id>` — when the
// user taps the ntfy tray notification, our app catches that intent via
// app_links and routes to the notification center, highlighting that id.

import type { Notification, NotificationLevel } from "./notifications.js";

export interface NtfySender {
  send: (notification: Notification) => Promise<void>;
}

interface NtfyConfig {
  url: string;
  topic: string;
  token?: string | undefined;
}

/// 10-second per-send budget. ntfy POSTs should be near-instant on a
/// local/LAN server; a request that hangs longer than this is broken
/// upstream and retrying won't help.
const SEND_TIMEOUT_MS = 10_000;

/// Map our notification level → ntfy priority (1=min, 3=default, 4=high,
/// 5=urgent). info/success are routine (3), warning bumps to 4 so it
/// breaks through DND, error is urgent so the device wakes the screen.
function levelToPriority(level: NotificationLevel): string {
  switch (level) {
    case "warning":
      return "4";
    case "error":
      return "5";
    case "info":
    case "success":
    default:
      return "3";
  }
}

/// Map level → ntfy emoji shortcode (rendered as the leading emoji on the
/// tray notification). Keeps the four levels visually distinct at a glance.
function levelToTag(level: NotificationLevel): string {
  switch (level) {
    case "info":
      return "information_source";
    case "success":
      return "white_check_mark";
    case "warning":
      return "warning";
    case "error":
      return "rotating_light";
  }
}

/// Encode a header value that may contain non-ASCII (e.g. CJK titles) per
/// RFC 2047. Pure-ASCII passes through unchanged so the common case stays
/// readable in logs and curl output. ntfy honors `Title:` either way.
function encodeHeaderValue(raw: string): string {
  // Quick ASCII check — skip the encoding round-trip for the common case.
  let asciiOnly = true;
  for (let i = 0; i < raw.length; i++) {
    if (raw.charCodeAt(i) > 0x7f) {
      asciiOnly = false;
      break;
    }
  }
  if (asciiOnly) return raw;
  const b64 = Buffer.from(raw, "utf8").toString("base64");
  return `=?UTF-8?B?${b64}?=`;
}

/// Build an NtfySender from environment. Returns null when NTFY_URL or
/// NTFY_TOPIC is unset — caller treats null as "ntfy disabled" and skips
/// attaching to the hub.
export function initNtfySender(
  env: NodeJS.ProcessEnv = process.env,
): NtfySender | null {
  const urlRaw = env.NTFY_URL;
  const topicRaw = env.NTFY_TOPIC;
  if (!urlRaw || urlRaw.length === 0) return null;
  if (!topicRaw || topicRaw.length === 0) return null;

  // Strip any accidental trailing slash so we don't emit `https://x//topic`.
  const url = urlRaw.replace(/\/+$/, "");
  const topic = topicRaw;
  const token =
    env.NTFY_TOKEN && env.NTFY_TOKEN.length > 0 ? env.NTFY_TOKEN : undefined;

  console.log(`[ntfy] enabled: ${url}/${topic}`);

  const cfg: NtfyConfig = { url, topic, token };
  return makeSender(cfg);
}

/// Visible-for-tests factory: build a sender directly from an explicit
/// config. The production path goes through initNtfySender() which reads
/// env vars; tests construct cfg directly and assert on fetch shape via a
/// stub.
export function makeSender(cfg: NtfyConfig): NtfySender {
  const target = `${cfg.url}/${cfg.topic}`;

  return {
    async send(notification: Notification): Promise<void> {
      const headers: Record<string, string> = {
        Title: encodeHeaderValue(notification.title),
        Priority: levelToPriority(notification.level),
        Click: `mobilecode://notifications/${notification.id}`,
        Tags: levelToTag(notification.level),
      };
      if (cfg.token !== undefined) {
        headers.Authorization = `Bearer ${cfg.token}`;
      }
      // ntfy reads the request body as the message text. Empty body is
      // acceptable; the title alone is enough to render a tray entry.
      const body = notification.body ?? "";

      try {
        const res = await fetch(target, {
          method: "POST",
          headers,
          body,
          signal: AbortSignal.timeout(SEND_TIMEOUT_MS),
        });
        if (!res.ok) {
          console.warn(`[ntfy] send failed: HTTP ${res.status}`);
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.warn(`[ntfy] send error: ${msg}`);
      }
    },
  };
}
