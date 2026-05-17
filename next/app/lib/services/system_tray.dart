// System-tray notification posting, run on the main isolate.
//
// History: this used to live inside the foreground-service isolate
// (`notification_foreground_service.dart`), which held its own WebSocket
// to the backend and called `flutter_local_notifications.show()` directly
// when `notification.show` pushes arrived. That isolate's WS sometimes
// silently failed (handshake/subscribe errors only logged via
// `debugPrint`), and because tray posting was wired exclusively through
// it, a single failure made the entire system-tray surface dark even
// though the main isolate kept receiving the same pushes and updating
// the in-app notification center.
//
// New shape: the main isolate's `BackendClient` is the sole WS, and
// `main.dart` fans `notification.show` / `notification.deleted` /
// `notification.superseded` events to `SystemTrayController` to post to
// the tray. The foreground service stays — Android still needs an active
// FGS to keep the main isolate alive on aggressive OEMs — but it has
// degenerated to a pure "keep the process resident" shell with no
// network responsibilities.
//
// This file owns:
//   * The per-level Android notification channels (created on `init`).
//   * The tray id derivation (FNV-1a over the notification id string).
//   * The mute / quiet-hours suppression policy used at post time.
//   * The pending-tap slot (`consumePendingTapNotificationId`) consumed
//     by `main.dart` on resume to route to the notification center.
//
// FCM's background isolate (`fcm_service.dart`) still calls
// `flutter_local_notifications` directly because it runs in a separate
// isolate when the app is dead; it shares the channel ids defined here
// (`NotificationChannels.*`) so user channel-level overrides apply
// uniformly across both transports.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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

/// Map a notification id (string UUID) to a stable 32-bit int for the
/// `flutter_local_notifications` API, which keys posts/cancels by int.
/// `String.hashCode` is platform-stable for the Dart VM but cross-isolate
/// stability isn't documented as a contract; we use FNV-1a to be explicit.
int trayIdForNotification(String id) {
  var h = 0x811c9dc5;
  for (final c in id.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h & 0x7FFFFFFF;
}

/// Set by [_onNotificationTap] when the user taps a tray notification.
/// `main.dart` reads + clears this on app resume to populate the
/// notification center's `initialItemId`.
String? _pendingTapNotificationId;

/// Drain (and clear) the pending tap id. Safe to call from the main
/// isolate.
String? consumePendingTapNotificationId() {
  final v = _pendingTapNotificationId;
  _pendingTapNotificationId = null;
  return v;
}

/// Top-level tap handler for `flutter_local_notifications`. We unpack the
/// `payload` (a JSON object containing the notification id) and store it
/// on a static field; `main.dart` polls this on `resume` and pushes the
/// notification center route.
///
/// Must be top-level (no closure capture) so the plugin can resolve it
/// when a tap delivers while the app is dead.
@pragma('vm:entry-point')
void onNotificationTap(NotificationResponse response) {
  final payload = response.payload;
  if (payload == null) return;
  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      final id = decoded['id'];
      if (id is String) {
        _pendingTapNotificationId = id;
      }
    }
  } on FormatException {
    // Malformed payload — drop it. The app will still open via the
    // intent flow.
  }
}

/// Main-isolate facade that owns the `flutter_local_notifications`
/// plugin instance, creates the per-level channels on `init`, and
/// posts / cancels system-tray entries on behalf of the
/// notification surface.
class SystemTrayController {
  SystemTrayController();

  final FlutterLocalNotificationsPlugin _notif =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Last platform-level failure observed when posting to the tray.
  /// Exposed so future diagnostic surfaces (a Settings → Diagnostics
  /// page) can render it without having to scrape `debugPrint`. Null
  /// means "no error since last successful post / init".
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  Future<void> init() async {
    if (_initialized) return;
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    );
    // The plugin throws `LateInitializationError` in environments where
    // no platform implementation is registered (widget tests, desktop
    // hosts without the FFI bits). Treat that as "no tray surface
    // available" and degrade silently — `show()` will hit the same
    // path and route the failure through `lastError`.
    try {
      final initOk = await _notif.initialize(
        initSettings,
        onDidReceiveNotificationResponse: onNotificationTap,
      );
      debugPrint('SystemTray: _notif.initialize() returned $initOk');
    } catch (e) {
      debugPrint('SystemTray: initialize failed: $e');
      lastError.value = 'initialize failed: $e';
      _initialized = true;
      return;
    }

    final AndroidFlutterLocalNotificationsPlugin? android;
    try {
      android = _notif.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
    } catch (e) {
      debugPrint('SystemTray: resolvePlatformSpecificImplementation failed: $e');
      _initialized = true;
      return;
    }
    if (android == null) {
      // Non-Android host (tests, future iOS work): nothing more to do.
      _initialized = true;
      return;
    }
    await android.createNotificationChannel(AndroidNotificationChannel(
      NotificationChannels.low,
      _channelName(NotificationChannels.low),
      description: _channelDescription(NotificationChannels.low),
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    ));
    await android.createNotificationChannel(AndroidNotificationChannel(
      NotificationChannels.defaultImp,
      _channelName(NotificationChannels.defaultImp),
      description: _channelDescription(NotificationChannels.defaultImp),
      importance: Importance.defaultImportance,
      playSound: true,
      enableVibration: true,
    ));
    await android.createNotificationChannel(AndroidNotificationChannel(
      NotificationChannels.high,
      _channelName(NotificationChannels.high),
      description: _channelDescription(NotificationChannels.high),
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    ));
    debugPrint('SystemTray: notification channels created');
    _initialized = true;
  }

  /// Post a tray notification for [n], honoring mute / quiet-hours
  /// suppression. Muted sources are dropped silently (they remain
  /// visible in the in-app notification center, which is the design
  /// contract for "mute"). Inside quiet hours the channel degrades
  /// to low/silent regardless of level.
  Future<void> show(
    AppNotification n, {
    required Set<String> mutedSources,
    int quietStartMinutes = -1,
    int quietEndMinutes = -1,
  }) async {
    if (mutedSources.contains(n.source)) {
      debugPrint('SystemTray: suppressing muted source ${n.source}');
      return;
    }
    final inQuiet = _inQuietHours(quietStartMinutes, quietEndMinutes);
    final channelId =
        inQuiet ? NotificationChannels.low : channelForLevel(n.level);
    debugPrint('SystemTray: show title=${n.title} '
        'level=${n.level} channel=$channelId inQuiet=$inQuiet');
    final details = AndroidNotificationDetails(
      channelId,
      _channelName(channelId),
      channelDescription: _channelDescription(channelId),
      importance: _importanceFor(channelId),
      priority: _priorityFor(channelId),
      ticker: n.title,
      icon: 'ic_notification',
      silent: inQuiet || channelId == NotificationChannels.low,
      autoCancel: true,
    );
    final payload = jsonEncode({'id': n.id});
    try {
      await _notif.show(
        trayIdForNotification(n.id),
        n.title,
        n.body,
        NotificationDetails(android: details),
        payload: payload,
      );
      lastError.value = null;
    } on PlatformException catch (e) {
      debugPrint('SystemTray: show failed: $e');
      lastError.value = 'show failed: ${e.message ?? e.code}';
    }
  }

  /// Cancel the tray entry for [id]. Called from
  /// `notification.deleted` / `notification.superseded` handlers in
  /// the main isolate.
  Future<void> cancel(String id) async {
    try {
      await _notif.cancel(trayIdForNotification(id));
    } on PlatformException catch (e) {
      debugPrint('SystemTray: cancel failed: $e');
      lastError.value = 'cancel failed: ${e.message ?? e.code}';
    }
  }

  // ---------- internal helpers ----------

  Importance _importanceFor(String channelId) {
    switch (channelId) {
      case NotificationChannels.high:
        return Importance.high;
      case NotificationChannels.defaultImp:
        return Importance.defaultImportance;
      case NotificationChannels.low:
      default:
        return Importance.low;
    }
  }

  Priority _priorityFor(String channelId) {
    switch (channelId) {
      case NotificationChannels.high:
        return Priority.high;
      case NotificationChannels.defaultImp:
        return Priority.defaultPriority;
      case NotificationChannels.low:
      default:
        return Priority.low;
    }
  }

  String _channelName(String channelId) {
    switch (channelId) {
      case NotificationChannels.high:
        return 'High-priority notifications';
      case NotificationChannels.defaultImp:
        return 'Notifications';
      case NotificationChannels.persistent:
        return 'Service status';
      case NotificationChannels.low:
      default:
        return 'Low-priority notifications';
    }
  }

  String _channelDescription(String channelId) {
    switch (channelId) {
      case NotificationChannels.high:
        return 'Errors and other items that need immediate attention.';
      case NotificationChannels.defaultImp:
        return 'Warnings and routine updates.';
      case NotificationChannels.persistent:
        return 'Indicator that openvsmobile-next is listening for backend '
            'notifications.';
      case NotificationChannels.low:
      default:
        return 'Informational and success notifications.';
    }
  }

  bool _inQuietHours(int quietStartMinutes, int quietEndMinutes) {
    if (quietStartMinutes < 0 || quietEndMinutes < 0) return false;
    if (quietStartMinutes == quietEndMinutes) return false;
    final now = DateTime.now();
    final m = now.hour * 60 + now.minute;
    if (quietStartMinutes < quietEndMinutes) {
      return m >= quietStartMinutes && m < quietEndMinutes;
    }
    // Wraps across midnight (e.g. 22:00 → 07:00).
    return m >= quietStartMinutes || m < quietEndMinutes;
  }
}
