# Notifications on Android

openvsmobile-next delivers backend notifications via a foreground service
that holds a persistent WebSocket. This is the same trade-off Telegram,
K-9 Mail, and Signal make for OS-tray delivery without FCM: a small
persistent indicator in the status bar in exchange for reliable
event delivery while the app is backgrounded or the screen is off.

## Standard Android

On stock Android (Pixel, Motorola, recent Samsung) the service runs
without extra configuration once you grant the **Post notifications**
permission on the first toggle.

The persistent indicator reads "openvsmobile-next — Listening for backend
notifications". You can hide it from the lockscreen via:

> Settings → Notifications → openvsmobile-next → Service status →
> Lock screen → Don't show.

The per-event channels ("Low-priority notifications", "Notifications",
"High-priority notifications") inherit the importance level Android
assigned when they were first created. You can raise or lower any
channel's importance from the same screen.

## OEM-specific battery whitelists

Several Android OEMs aggressively kill background processes regardless of
their foreground-service status. If notifications stop arriving after a
few minutes of screen-off time, add openvsmobile-next to the relevant
allowlist.

The exact path moves between firmware versions; the canonical reference
for each OEM is:

- **Xiaomi (MIUI / HyperOS):**
  [Don't Kill My App guide for Xiaomi](https://dontkillmyapp.com/xiaomi)
- **Oppo / OnePlus (ColorOS / OxygenOS):**
  [Don't Kill My App guide for Oppo](https://dontkillmyapp.com/oppo)
- **Huawei (EMUI / HarmonyOS):**
  [Don't Kill My App guide for Huawei](https://dontkillmyapp.com/huawei)
- **Vivo (Funtouch OS / OriginOS):**
  [Don't Kill My App guide for Vivo](https://dontkillmyapp.com/vivo)
- **Samsung One UI:**
  [Don't Kill My App guide for Samsung](https://dontkillmyapp.com/samsung)

If you don't see your OEM listed, the general guide at
<https://dontkillmyapp.com> is a good starting point.

## What the service does NOT do

- It does **not** push notifications when the backend is unreachable. The
  service silently retries with exponential backoff; the next successful
  reconnect picks up whatever the backend has queued (read state syncs via
  `deviceId`).
- It does **not** poll. Every notification arrives via the same JSON-RPC
  WebSocket the app uses while in the foreground — there is no separate
  HTTP push path, FCM token, or external service.
- It does **not** post your terminal output, file changes, or git status
  to the tray. Only `notification.show` events delivered through the
  backend's `/notify` endpoint reach the system tray.

## Disabling the service

Toggle **Background notifications** off in the in-app Notifications
settings. The persistent indicator disappears within a second. The in-app
notification center continues to work whenever the app is open.
