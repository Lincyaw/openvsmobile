// Foreground service shell — keeps the OS from killing the main isolate.
//
// History: this file used to host an isolate-side WebSocket that
// subscribed to `notification.show` independently of the main isolate's
// `BackendClient`. That second WS occasionally failed silently
// (handshake / subscribe errors only surfaced via `debugPrint`), and
// because tray posting was wired exclusively through it, a failure
// killed the entire system-tray surface even though the main isolate
// kept receiving the same pushes and updating the in-app notification
// center. See `services/system_tray.dart` for the new arrangement.
//
// What this file does now:
//   * Provides `NotificationServiceController` for `main.dart` to start
//     and stop the Android foreground service. The service's only
//     purpose is to keep the process resident on aggressive OEMs
//     (MIUI / EMUI / OxygenOS …) so the main isolate's WS keeps
//     receiving pushes while the user is in another app.
//   * Provides `NotificationForegroundHandler`, the task handler
//     `FlutterForegroundTask.setTaskHandler` requires. The handler is
//     intentionally empty — no network, no notification rendering,
//     no prefs. All of that now happens in the main isolate.
//
// Channel ids live in `services/system_tray.dart` so both this file
// (for the persistent FGS notification's channel) and the main-isolate
// poster can share one source of truth.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'system_tray.dart';

/// Service id used by `FlutterForegroundTask.startService`. Arbitrary
/// constant; chosen to be distinct from any per-event tray id we ever
/// allocate (those derive from FNV-1a hashes which never equal 0xF6F6).
const int kForegroundServiceId = 0xF6F6;

/// Top-level entry point referenced by `FlutterForegroundTask.startService`
/// as the `callback:`. Must be top-level (no closure capture).
@pragma('vm:entry-point')
void startNotificationForegroundHandler() {
  FlutterForegroundTask.setTaskHandler(NotificationForegroundHandler());
}

/// Service-side task handler. Runs on its own isolate but does no real
/// work: the main isolate's `BackendClient` + `SystemTrayController`
/// own notification delivery. This handler exists purely to satisfy
/// the `flutter_foreground_task` API contract — registering a handler
/// is what keeps the foreground service ticking.
class NotificationForegroundHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('FGS-HANDLER: onStart starter=$starter (keep-alive only)');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Event-driven — no periodic work.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('FGS-HANDLER: onDestroy timeout=$isTimeout');
  }

  @override
  void onReceiveData(Object data) {
    // No prefs to refresh — kept for forward-compat with the plugin's
    // SendPort contract.
    debugPrint('FGS-HANDLER: onReceiveData (ignored) $data');
  }

  @override
  void onNotificationPressed() {
    // The user tapped the persistent foreground-service indicator. Bring
    // the app to the foreground; per-event tray taps go through
    // `onNotificationTap` in `system_tray.dart`, not through here.
    FlutterForegroundTask.launchApp('/notifications');
  }
}

// ---------- Main-isolate side: a tiny controller ----------

/// A tiny façade owned by the main isolate that decides whether/when to
/// start or stop the foreground service. The service has no parameters
/// that need to be propagated to it — it does nothing but stay alive.
class NotificationServiceController {
  bool _initialized = false;

  /// Configure the channel for the persistent foreground-service
  /// indicator. Safe to call multiple times.
  void init() {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: NotificationChannels.persistent,
        channelName: 'Service status',
        channelDescription:
            'Keeps MobileCode running in the background to receive notifications.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        showBadge: false,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
        allowAutoRestart: true,
      ),
    );
    _initialized = true;
  }

  /// Start the keep-alive foreground service. Returns false if start
  /// was rejected (typically permission denied — the caller has
  /// already prompted; we surface state via the returned bool so the
  /// UI toggle can revert).
  Future<bool> start() async {
    if (!_initialized) init();
    final alreadyRunning = await FlutterForegroundTask.isRunningService;
    debugPrint('FGS-CTRL: isRunningService=$alreadyRunning');
    if (alreadyRunning) {
      return true;
    }
    debugPrint('FGS-CTRL: calling startService...');
    final r = await FlutterForegroundTask.startService(
      serviceId: kForegroundServiceId,
      notificationTitle: 'MobileCode',
      notificationText: 'Background ready',
      callback: startNotificationForegroundHandler,
    );
    debugPrint('FGS-CTRL: startService result=$r (${r.runtimeType})');
    return r is ServiceRequestSuccess;
  }

  Future<bool> stop() async {
    if (!await FlutterForegroundTask.isRunningService) return true;
    final r = await FlutterForegroundTask.stopService();
    return r is ServiceRequestSuccess;
  }

  Future<bool> get isRunning => FlutterForegroundTask.isRunningService;
}
