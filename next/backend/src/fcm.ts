// Firebase Cloud Messaging sender — the second transport for the
// notification system (the first is the in-process WS fan-out). On Xiaomi
// MIUI and similar vendor skins the foreground-service isolate is frozen
// even with battery whitelist + autostart, so FCM is what actually wakes
// the device for background delivery.
//
// Initialization model:
//   * Reads the path to a Firebase service-account JSON from
//     $FCM_SERVICE_ACCOUNT_JSON.
//   * If unset / missing / unreadable, initFcmSender() returns null and the
//     backend simply doesn't attach a sender — `NotificationHub.publish`
//     skips the FCM branch. Single-user self-hosted deployments without
//     FCM keep working unchanged.
//
// Message shape: `data` (not `notification`). The app's
// `FirebaseMessaging.onBackgroundMessage` receives the raw key/value pairs
// and renders the system-tray entry itself via flutter_local_notifications.
// We own rendering on both transports so the channel / silent / payload
// shape stays in one place.

import { readFileSync, statSync } from "node:fs";
import type { Notification } from "./notifications.js";

// firebase-admin is a heavy dep with side-effects on import; we keep the
// import inside the init function so test runs that don't touch FCM never
// pay the cost (and don't break if the package isn't installed in a
// thinned-down dev environment).

export interface FcmSendResult {
  invalidTokens: string[];
}

export interface FcmSender {
  sendToTokens: (
    tokens: string[],
    notification: Notification,
  ) => Promise<FcmSendResult>;
}

/// Build an FCM sender from a service-account JSON path. Returns null when
/// FCM is not configured (env var unset or file unreadable) — the caller
/// treats this as "FCM disabled" and skips attaching to the hub.
export async function initFcmSender(
  serviceAccountPath: string | undefined = process.env
    .FCM_SERVICE_ACCOUNT_JSON,
): Promise<FcmSender | null> {
  if (!serviceAccountPath || serviceAccountPath.length === 0) {
    return null;
  }
  try {
    statSync(serviceAccountPath);
  } catch {
    console.warn(
      `[fcm] FCM_SERVICE_ACCOUNT_JSON=${serviceAccountPath} not readable; FCM disabled`,
    );
    return null;
  }

  let admin: typeof import("firebase-admin");
  try {
    // Dynamic import so backends that don't ship firebase-admin (older
    // releases, slimmed CI) still start cleanly when FCM isn't configured.
    admin = (await import("firebase-admin")).default;
  } catch (err) {
    console.warn("[fcm] firebase-admin not available, FCM disabled:", err);
    return null;
  }

  const raw = readFileSync(serviceAccountPath, "utf8");
  let serviceAccount: unknown;
  try {
    serviceAccount = JSON.parse(raw);
  } catch (err) {
    console.warn("[fcm] service account JSON malformed; FCM disabled:", err);
    return null;
  }

  // initializeApp throws if called twice with the same default name —
  // guard with getApps() so re-init (e.g. from tests) is a no-op.
  if (admin.apps.length === 0) {
    admin.initializeApp({
      // The `cert` typing is intentionally narrow; the JSON shape from
      // the service-account file matches ServiceAccount at runtime. We
      // cast to the typeof-imported namespace so the dynamic-import path
      // doesn't need a top-level type alias from firebase-admin.
      credential: admin.credential.cert(
        serviceAccount as import("firebase-admin").ServiceAccount,
      ),
    });
  }
  const messaging = admin.messaging();
  console.log("[fcm] initialized");

  return {
    async sendToTokens(
      tokens: string[],
      notification: Notification,
    ): Promise<FcmSendResult> {
      if (tokens.length === 0) return { invalidTokens: [] };

      // `data`-only message: we render in-app via flutter_local_notifications
      // on receive, so the OS doesn't double-post a system notification on
      // top of our channel-respecting one. All values must be strings per
      // the FCM data-message contract.
      const data: Record<string, string> = {
        id: notification.id,
        title: notification.title,
        level: notification.level,
        source: notification.source,
      };
      if (notification.body !== undefined) data.body = notification.body;

      // High-priority for warning/error so MIUI actually wakes the app;
      // info/success can ride normal priority to save battery.
      const priority: "high" | "normal" =
        notification.level === "warning" || notification.level === "error"
          ? "high"
          : "normal";

      const result = await messaging.sendEachForMulticast({
        tokens,
        data,
        android: {
          priority,
        },
      });

      const invalidTokens: string[] = [];
      result.responses.forEach((resp, idx) => {
        if (resp.success) return;
        const code = resp.error?.code;
        if (
          code === "messaging/registration-token-not-registered" ||
          code === "messaging/invalid-registration-token" ||
          code === "messaging/invalid-argument"
        ) {
          const t = tokens[idx];
          if (t !== undefined) invalidTokens.push(t);
        } else if (resp.error) {
          console.warn(
            `[fcm] send error (token kept): ${resp.error.code} ${resp.error.message}`,
          );
        }
      });
      return { invalidTokens };
    },
  };
}
