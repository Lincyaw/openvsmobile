// Backpressure-aware WebSocket send.
//
// Every outbound frame in the backend funnels through `safeSend`. Before
// writing we consult `ws.bufferedAmount`: when it exceeds the high-water
// mark the peer is not draining and we'd otherwise queue indefinitely (the
// `ws` library will happily eat memory until the process OOMs). At that
// point the right move per first principle #4 — reconnect is a first-class
// path — is to drop the stalled peer; the client's reconnect logic will
// pick up cleanly.
//
// Default cap of 16 MiB is loose enough that a healthy burst of
// `terminal.data` frames sails through and tight enough that a wedged peer
// is caught long before the process is in trouble. Override via the
// `OPENVSMOBILE_WS_HWM` env var (bytes).

import type { WebSocket } from "ws";

function parseHwm(): number {
  const raw = process.env.OPENVSMOBILE_WS_HWM;
  if (raw === undefined || raw.length === 0) return 16 * 1024 * 1024;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) return 16 * 1024 * 1024;
  return Math.trunc(n);
}

/// Resolved once at module load. Tests that need a different threshold set
/// the env var before importing.
export const WS_SEND_HIGH_WATER_MARK = parseHwm();

/// Send `msg` (already-stringified JSON) over `ws`. If the socket's outbound
/// buffer is past `WS_SEND_HIGH_WATER_MARK`, log a warning and terminate the
/// socket instead — the peer is not reading and the only sane action is to
/// let it reconnect.
///
/// Returns true when the frame was queued, false when the socket was
/// terminated (or wasn't OPEN to begin with).
export function safeSend(ws: WebSocket, msg: string): boolean {
  if (ws.readyState !== ws.OPEN) return false;
  // `bufferedAmount` is typed loosely on the WS interface; treat undefined as
  // zero so unit tests with minimal stubs don't trip the warning path.
  const buffered =
    typeof (ws as { bufferedAmount?: number }).bufferedAmount === "number"
      ? (ws as { bufferedAmount: number }).bufferedAmount
      : 0;
  if (buffered > WS_SEND_HIGH_WATER_MARK) {
    console.warn(
      `[wsSend] bufferedAmount=${buffered} > hwm=${WS_SEND_HIGH_WATER_MARK}; terminating peer`,
    );
    try {
      ws.terminate();
    } catch {
      // already gone — fine.
    }
    return false;
  }
  ws.send(msg);
  return true;
}
