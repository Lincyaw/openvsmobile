// Foreground service entry-point for system-tray notification delivery.
//
// Architecture choice (v0): the foreground-service isolate holds its OWN
// WebSocket to the backend. The main isolate's `BackendClient` stays
// untouched; they are two parallel connections. This is the brief's
// "simpler architecture" path — the alternative (isolate-message bridge
// between the main BackendClient and the service handler) requires
// shuttling JSON-RPC frames across a `SendPort`, which is feasible but
// significantly more code for a v0 that only needs the service to:
//
//   1. Hold the WS open so `notification.show` pushes land while the app
//      is backgrounded.
//   2. Post each push to the system tray via the per-level Android channel.
//
// Both connections are cheap when idle (heartbeat every 25s, no traffic
// otherwise). The trade-off is documented here so a future PR can revisit.
//
// IMPORTANT — what this file does NOT do in this PR:
//   * It does not actually start the foreground service yet. The
//     `flutter_foreground_task` dep is wired and the channels are defined,
//     but `startService()` is a follow-up: it requires per-OEM testing,
//     a notification icon resource, and POST_NOTIFICATIONS permission
//     handling on Android 13+. The Settings toggle (default true) is in
//     place so the rollout flips a single switch when ready.
//
// See design §4.5 "Foreground service".

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../notification.dart';

/// Channel ids used when posting system-tray notifications. Per-level
/// channels let the user override sound/vibration per importance class
/// from Android settings.
class NotificationChannels {
  NotificationChannels._();
  static const String low = 'openvsmobile-low';
  static const String defaultImp = 'openvsmobile-default';
  static const String high = 'openvsmobile-high';
  static const String persistent = 'openvsmobile-persistent';
}

/// Pick the system-tray channel for [level]. info/success → low (silent),
/// warning → default (sound), error → high (heads-up).
String channelForLevel(NotificationLevel level) {
  switch (level) {
    case NotificationLevel.info:
    case NotificationLevel.success:
      return NotificationChannels.low;
    case NotificationLevel.warning:
      return NotificationChannels.defaultImp;
    case NotificationLevel.error:
      return NotificationChannels.high;
  }
}

/// Foreground task handler. Invoked by `flutter_foreground_task` on its own
/// isolate. Currently a no-op scaffold; see file header for the rollout
/// plan. Kept compilable so the architecture is reviewable and the wiring
/// in `main.dart` doesn't need to grow a second seam later.
@pragma('vm:entry-point')
class NotificationForegroundHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('NotificationForegroundHandler: onStart at $timestamp '
        '(starter: $starter)');
    // TODO: open the WebSocket against the configured backend, run
    // auth.handshake + notification.subscribe, and route `notification.show`
    // pushes to FlutterForegroundTask.updateService / a system-tray post.
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Event-driven — we don't need a periodic tick.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('NotificationForegroundHandler: onDestroy at $timestamp '
        '(timeout: $isTimeout)');
  }

  @override
  void onReceiveData(Object data) {
    // Bridge slot — the main isolate can push notifications down here when
    // the simpler "two parallel WS" model is replaced with the bridge model.
    debugPrint('NotificationForegroundHandler: onReceiveData ${data.runtimeType}');
  }
}

/// Entry-point referenced from `main.dart` to register the handler with
/// `flutter_foreground_task`. Calling this is safe (idempotent) but does
/// not start the service on its own — startService is a separate explicit
/// call gated by the Settings toggle.
@pragma('vm:entry-point')
void startNotificationForegroundHandler() {
  FlutterForegroundTask.setTaskHandler(NotificationForegroundHandler());
}
