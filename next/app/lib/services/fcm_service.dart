// Firebase Cloud Messaging — the second notification transport.
//
// The foreground-service path (notification_foreground_service.dart) is
// the primary mechanism: it holds a WS and renders local notifications
// directly. FCM is the fall-through for cases where the OS freezes the
// service isolate (Xiaomi MIUI, Huawei EMUI, etc) and pushes never
// reach the WS.
//
// What this file does:
//   * Background message handler — top-level entry point, renders a tray
//     notification via flutter_local_notifications using the same channel
//     vocabulary as the foreground service.
//   * Foreground message handler — drops the FCM duplicate when the WS
//     path is already alive.
//   * Token registration — on app launch and on `onTokenRefresh`, push
//     the current token to the backend over the existing JSON-RPC
//     channel. SharedPreferences caches the last-sent token to avoid
//     re-registering every launch.
//
// Init is gated behind Firebase.initializeApp succeeding; on a device
// without GMS / with a missing google-services.json the init throws and
// we silently skip the whole FCM path.

import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../backend_client.dart';
import '../notification.dart';
import 'fcm_diagnostics.dart';
import 'system_tray.dart';

/// SharedPreferences key for the last token we successfully registered
/// with the backend. We avoid re-registering on every launch by diffing
/// against this; a re-registration only happens on token rotation.
const String _kLastSentFcmTokenKey = 'fcm.last-sent-token';

/// Initialize Firebase + register FCM background handler. Returns true
/// on success, false on any failure (e.g. no GMS / missing config /
/// init exception). Callers can ignore the return value — the FGS path
/// keeps working regardless.
Future<bool> initFirebaseAndFcm() async {
  try {
    await Firebase.initializeApp();
    FcmDiagnostics.instance.setFirebaseInit(ok: true);
  } catch (e) {
    FcmDiagnostics.instance.setFirebaseInit(ok: false, error: e.toString());
    return false;
  }
  try {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (e) {
    FcmDiagnostics.instance.append('onBackgroundMessage register failed: $e');
  }
  return true;
}

/// Top-level handler for FCM messages delivered while the app is
/// backgrounded (or killed and revived by the OS for delivery). Must be
/// top-level and @pragma('vm:entry-point') so the FCM isolate can resolve
/// it. We render via flutter_local_notifications because FCM's own
/// notification rendering doesn't respect our per-level channels.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // The background isolate has no app state; spin up Firebase fresh.
  // Failure here is unrecoverable for this delivery — log and bail.
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('FCM-BG: Firebase.initializeApp failed: $e');
    return;
  }
  final data = message.data;
  await _showFromFcmData(data);
}

/// Render a tray notification from an FCM data payload. Shared by the
/// foreground deduper (when WS hasn't already shown it) and the
/// background handler. Channel selection mirrors the FGS path so a user
/// who muted the "low" channel sees the same behavior on both transports.
Future<void> _showFromFcmData(Map<String, dynamic> data) async {
  final id = data['id'];
  if (id is! String || id.isEmpty) return;
  final title = (data['title'] as String?) ?? '';
  final body = data['body'] as String?;
  final levelStr = (data['level'] as String?) ?? 'info';
  final NotificationLevel level;
  switch (levelStr) {
    case 'success':
      level = NotificationLevel.success;
    case 'warning':
      level = NotificationLevel.warning;
    case 'error':
      level = NotificationLevel.error;
    default:
      level = NotificationLevel.info;
  }
  final channelId = channelForLevel(level);

  final plugin = FlutterLocalNotificationsPlugin();
  // Best-effort init — if the plugin was never initialized in this
  // isolate, initialize now with the same icon/tap-handler used by FGS.
  // `initialize` is idempotent.
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    ),
    onDidReceiveNotificationResponse: onNotificationTap,
  );
  // Recreate the channels — same idempotency story.
  final android = plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  if (android != null) {
    await android.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.low,
      'Low-priority notifications',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.defaultImp,
      'Notifications',
      importance: Importance.defaultImportance,
      playSound: true,
      enableVibration: true,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.high,
      'High-priority notifications',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    ));
  }

  final Importance importance;
  final Priority priority;
  final bool silent;
  switch (channelId) {
    case NotificationChannels.high:
      importance = Importance.high;
      priority = Priority.high;
      silent = false;
    case NotificationChannels.defaultImp:
      importance = Importance.defaultImportance;
      priority = Priority.defaultPriority;
      silent = false;
    default:
      importance = Importance.low;
      priority = Priority.low;
      silent = true;
  }

  final details = AndroidNotificationDetails(
    channelId,
    'Notifications',
    importance: importance,
    priority: priority,
    ticker: title,
    icon: 'ic_notification',
    silent: silent,
    autoCancel: true,
  );
  final payload = jsonEncode({'id': id});
  await plugin.show(
    trayIdForNotification(id),
    title,
    body,
    NotificationDetails(android: details),
    payload: payload,
  );
}

/// Foreground FCM handler — invoked while the app is alive. The
/// foreground-service WS has already delivered this notification through
/// the primary path, so we'd just be duplicating. Drop it. (If a future
/// design wants FCM to be primary, this is the dedup hook.)
void onForegroundFcmMessage(RemoteMessage _) {
  // No-op: WS path wins in foreground.
}

/// Main-isolate FCM controller. Owned by the top-level app widget; lives
/// for the app's lifetime. Hooks `onTokenRefresh` and exposes a
/// `registerWithBackend` call that the app fires after backend handshake.
class FcmController {
  // Lazy getter — `FirebaseMessaging.instance` throws when Firebase wasn't
  // initialized (test environment, devices without GMS). Touching it only
  // inside init() lets a single try/catch keep the rest of the app alive.
  FirebaseMessaging get _messaging => FirebaseMessaging.instance;
  StreamSubscription<String>? _refreshSub;
  StreamSubscription<RemoteMessage>? _msgSub;
  String? _deviceId;
  BackendClient? _client;
  bool _initialized = false;

  Future<void> init({
    required BackendClient client,
    required String deviceId,
  }) async {
    _client = client;
    _deviceId = deviceId;
    if (_initialized) return;
    _initialized = true;

    try {
      // Request POST_NOTIFICATIONS on Android 13+. The OS-level prompt
      // is also fired by the foreground service, but doing it here too
      // is harmless and covers the "user disabled FGS but kept FCM" case.
      final settings = await _messaging.requestPermission();
      FcmDiagnostics.instance
          .setPermission(settings.authorizationStatus.toString());
      _msgSub = FirebaseMessaging.onMessage.listen(onForegroundFcmMessage);
      _refreshSub = _messaging.onTokenRefresh.listen((token) {
        FcmDiagnostics.instance.append('onTokenRefresh fired');
        unawaited(_registerIfChanged(token));
      });
      FcmDiagnostics.instance.setControllerInit(ok: true);
    } catch (e) {
      // Firebase not initialized (test env / no GMS) — leave _initialized
      // true so we don't retry on every reconnect, and let registerWith-
      // Backend become a no-op.
      FcmDiagnostics.instance
          .setControllerInit(ok: false, error: e.toString());
    }
  }

  /// Called once after the backend connection is established. Reads the
  /// current FCM token and (if it changed since last successful register)
  /// pushes it to the backend.
  Future<void> registerWithBackend() async {
    if (!_initialized) {
      FcmDiagnostics.instance
          .append('registerWithBackend skipped: controller not initialized');
      return;
    }
    FcmDiagnostics.instance.append('registerWithBackend: calling getToken()…');
    String? token;
    try {
      // getToken() is known to block forever on some Xiaomi devices; cap it
      // so the diagnostic state moves forward even when FCM is sick.
      token = await _messaging.getToken().timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TimeoutException(
                'getToken() did not return within 20s — likely SERVICE_NOT_AVAILABLE'),
          );
    } catch (e) {
      FcmDiagnostics.instance.setToken(error: e.toString());
      return;
    }
    FcmDiagnostics.instance.setToken(token: token);
    if (token == null || token.isEmpty) return;
    await _registerIfChanged(token);
  }

  Future<void> _registerIfChanged(String token) async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_kLastSentFcmTokenKey);
    if (last == token) {
      FcmDiagnostics.instance
          .setRegister(status: 'skipped: token unchanged since last register');
      return;
    }
    final client = _client;
    final deviceId = _deviceId;
    if (client == null || deviceId == null || deviceId.isEmpty) {
      FcmDiagnostics.instance.setRegister(
          status:
              'skipped: client=${client != null} deviceId=${deviceId ?? "null"}');
      return;
    }
    try {
      await client.call('notification.registerFcmToken', {
        'token': token,
        'deviceId': deviceId,
        'platform': 'android',
      });
      await prefs.setString(_kLastSentFcmTokenKey, token);
      FcmDiagnostics.instance.setRegister(status: 'ok');
    } catch (e) {
      FcmDiagnostics.instance.setRegister(status: 'failed: $e');
    }
  }

  Future<void> dispose() async {
    await _refreshSub?.cancel();
    await _msgSub?.cancel();
  }
}
