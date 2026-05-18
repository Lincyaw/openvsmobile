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
// Background delivery uses the ntfy app as the second transport — it
// renders its own system-tray entries and deep-links back via
// `mobilecode://notifications/<id>`. The channel ids here are used only
// by the in-app/foreground rendering path.

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

  /// In-flight (or completed) initialization future. `show()` and
  /// `cancel()` await this before touching the plugin so a
  /// `notification.show` push that arrives during bootstrap doesn't race
  /// the async channel-creation calls inside `init()`.
  Future<void>? _ready;

  /// Small-icon resource name passed to AndroidNotificationDetails.
  /// Switched at runtime by `useFallbackIcon()` from the diagnostics
  /// screen to test whether a vector-drawable rejection is the reason
  /// posts fail silently on some OEM ROMs.
  String _smallIcon = '@mipmap/ic_launcher';

  String get currentIcon => _smallIcon;
  bool get isInitialized => _initialized;

  /// Last platform-level failure observed when posting to the tray.
  /// Exposed so future diagnostic surfaces (a Settings → Diagnostics
  /// page) can render it without having to scrape `debugPrint`. Null
  /// means "no error since last successful post / init".
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  final ValueNotifier<DateTime?> lastShowAt = ValueNotifier<DateTime?>(null);
  final ValueNotifier<String?> lastShowResult = ValueNotifier<String?>(null);
  final ValueNotifier<List<String>> logs = ValueNotifier<List<String>>(const []);

  void _log(String line) {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    final entry = '[$hh:$mm:$ss] $line';
    debugPrint('SystemTray: $line');
    final next = <String>[...logs.value, entry];
    if (next.length > 100) next.removeRange(0, next.length - 100);
    logs.value = next;
  }

  Future<void> init() {
    return _ready ??= _init();
  }

  Future<void> _init() async {
    if (_initialized) return;
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
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
      _log('_notif.initialize() returned $initOk');
    } catch (e) {
      _log('init failed: $e');
      lastError.value = 'initialize failed: $e';
      _initialized = true;
      return;
    }

    final AndroidFlutterLocalNotificationsPlugin? android;
    try {
      android = _notif.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
    } catch (e) {
      _log('resolvePlatformSpecificImplementation failed: $e');
      _initialized = true;
      return;
    }
    if (android == null) {
      // Non-Android host (tests, future iOS work): nothing more to do.
      _initialized = true;
      return;
    }
    final vibrationPattern = Int64List.fromList([0, 300, 200, 300]);
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
      vibrationPattern: vibrationPattern,
    ));
    await android.createNotificationChannel(AndroidNotificationChannel(
      NotificationChannels.high,
      _channelName(NotificationChannels.high),
      description: _channelDescription(NotificationChannels.high),
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      vibrationPattern: vibrationPattern,
    ));
    _log('channels created');
    _initialized = true;
  }

  Future<void> reinit() async {
    _initialized = false;
    _ready = null;
    _log('reinit requested');
    await init();
  }

  void useFallbackIcon() {
    _smallIcon = '@mipmap/ic_launcher';
    _log('icon → @mipmap/ic_launcher (fallback)');
  }

  void resetIcon() {
    _smallIcon = '@mipmap/ic_launcher';
    _log('icon → @mipmap/ic_launcher');
  }

  Future<void> testShow() async {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    final fake = AppNotification(
      id: 'test-${now.millisecondsSinceEpoch}',
      source: 'diagnostic',
      level: NotificationLevel.error,
      title: 'Test',
      body: 'Test notification at $hh:$mm:$ss',
      timestamp: now.millisecondsSinceEpoch,
    );
    await show(fake, mutedSources: const {});
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
    // Wait for channel creation to finish — a `notification.show` push
    // that races bootstrap would otherwise hit an uninitialized plugin.
    await _ready;
    lastShowAt.value = DateTime.now();
    if (mutedSources.contains(n.source)) {
      _log('suppressing muted source ${n.source}');
      lastShowResult.value = 'suppressed (muted)';
      return;
    }
    final inQuiet = _inQuietHours(quietStartMinutes, quietEndMinutes);
    final channelId =
        inQuiet ? NotificationChannels.low : channelForLevel(n.level);
    _log('show id=${n.id} title=${n.title} level=${n.level} '
        'channel=$channelId icon=$_smallIcon inQuiet=$inQuiet');
    final details = AndroidNotificationDetails(
      channelId,
      _channelName(channelId),
      channelDescription: _channelDescription(channelId),
      importance: _importanceFor(channelId),
      priority: _priorityFor(channelId),
      ticker: n.title,
      icon: _smallIcon,
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
      lastShowResult.value = 'ok';
    } on PlatformException catch (e) {
      _log('show PlatformException: ${e.code} ${e.message}');
      lastError.value = 'show failed: ${e.message ?? e.code}';
      lastShowResult.value = 'platform error: ${e.message ?? e.code}';
    } catch (e) {
      _log('show threw: $e');
      lastError.value = '$e';
      lastShowResult.value = 'exception: ${e.runtimeType}';
    }
  }

  /// Cancel the tray entry for [id]. Called from
  /// `notification.deleted` / `notification.superseded` handlers in
  /// the main isolate.
  Future<void> cancel(String id) async {
    await _ready;
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
        return 'Indicator that MobileCode is listening for backend '
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
