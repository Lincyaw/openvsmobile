// Foreground service entry-point for system-tray notification delivery.
//
// Architecture: the foreground-service isolate holds its OWN WebSocket to
// the backend. The main isolate's `BackendClient` is unchanged; the two
// connections coexist. This is the brief's "simpler architecture" path —
// the alternative (isolate-message bridge for a single shared BackendClient)
// requires shuttling JSON-RPC frames across a SendPort, which is feasible
// but adds substantial code for v0 needs that are limited to:
//
//   1. Hold a WS open so `notification.show` pushes land while the app is
//      backgrounded.
//   2. Post each push to the system tray via a per-level Android channel.
//   3. Cancel system-tray entries when `notification.deleted` /
//      `notification.superseded` arrive.
//
// Both connections are cheap when idle (heartbeat-like keepalive via the
// JSON-RPC layer or socket-level pings; no app-layer messages flow when
// no notifications arrive). The trade-off is documented here so a future
// PR can revisit.
//
// What this file does:
//   * Defines the per-level Android notification channels (created on
//     plugin init in `_initLocalNotifications`).
//   * `NotificationForegroundHandler` runs on the foreground-service
//     isolate, opens a WebSocket, runs `auth.handshake` with the SAME
//     deviceId the main isolate uses (so this device counts as one device
//     for multi-device read sync, not two), subscribes to notifications,
//     reconnects with exponential backoff, and routes:
//        notification.show       → flutter_local_notifications.show
//        notification.deleted    → cancel(id) for each
//        notification.superseded → cancel(oldId)
//     Everything else (terminal/workspace pushes the backend fans out to
//     every subscriber) is silently dropped — this isolate has a narrow job.
//   * Persists service connection params (host/port/token/deviceId) through
//     `FlutterForegroundTask.saveData` so `onStart` can read them on the
//     service isolate without going back to the main isolate. The main
//     isolate writes these before calling `startService`.
//
// See design §4.5 "Foreground service".

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

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

/// Service id used by `FlutterForegroundTask.startService`. Arbitrary
/// constant; chosen to be distinct from any per-event tray id we ever
/// allocate (those derive from FNV-1a hashes which never equal 0xF6F6).
const int kForegroundServiceId = 0xF6F6;

/// Keys we store/read on the foreground-service prefs surface
/// (`FlutterForegroundTask.saveData`). The plugin namespaces them
/// automatically under its own prefix; the names below are still
/// kebab-case to match the conventions §4 discipline for the app's
/// regular SharedPreferences keys.
class _ServicePrefs {
  _ServicePrefs._();
  static const String host = 'svc-host';
  static const String port = 'svc-port';
  static const String token = 'svc-token';
  static const String deviceId = 'svc-device-id';
  // Comma-separated list of muted sources (system-tray delivery only —
  // the in-app center still shows them). Refreshed when the main isolate
  // saves notification prefs.
  static const String mutedSources = 'svc-muted-sources';
  // Quiet hours in minutes-since-midnight; -1 = unset. When set, system-
  // tray delivery is forced silent during the window regardless of level.
  static const String quietStart = 'svc-quiet-start';
  static const String quietEnd = 'svc-quiet-end';
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

/// Top-level entry point referenced by `FlutterForegroundTask.startService`
/// as the `callback:`. Must be top-level (no closure capture).
@pragma('vm:entry-point')
void startNotificationForegroundHandler() {
  FlutterForegroundTask.setTaskHandler(NotificationForegroundHandler());
}

/// Top-level tap handler for `flutter_local_notifications`. We unpack the
/// `payload` (a JSON object containing the notification id) and store it
/// on a static field; `main.dart` polls this on `resume` and pushes the
/// notification center route.
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

/// Set by [onNotificationTap] when the user taps a tray notification.
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

/// Service-side task handler. Runs on its own isolate; cannot touch the
/// main isolate's AppState/BackendClient. All settings come from
/// `FlutterForegroundTask.getData(key:)` (parent → isolate channel).
class NotificationForegroundHandler extends TaskHandler {
  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  bool _stopped = false;
  int _backoffStep = 0;
  Timer? _reconnectTimer;
  int _nextRpcId = 1;

  /// Local-notifications plugin instance — service-isolate-scoped.
  final FlutterLocalNotificationsPlugin _notif =
      FlutterLocalNotificationsPlugin();
  bool _notifInitialized = false;

  // Cached prefs read in onStart; refreshed in `onReceiveData` when the
  // main isolate sends an update.
  String? _host;
  int? _port;
  String? _token;
  String? _deviceId;
  Set<String> _mutedSources = const {};
  int _quietStart = -1;
  int _quietEnd = -1;

  final Map<int, Completer<Object?>> _pending = {};

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('FGS-HANDLER: onStart starter=$starter');
    await _initLocalNotifications();
    await _readPrefs();
    debugPrint('FGS-HANDLER: prefs host=$_host port=$_port token=${_token != null} deviceId=$_deviceId');
    if (_host == null || _port == null || _token == null) {
      debugPrint('FGS-HANDLER: missing connection prefs; not opening WS.');
      return;
    }
    debugPrint('FGS-HANDLER: starting _connect()');
    unawaited(_connect());
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Event-driven — no periodic work. The notification design is
    // push-only; idle ticks would just burn battery.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('NotificationForegroundHandler.onDestroy timeout=$isTimeout');
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeSocket();
  }

  @override
  void onReceiveData(Object data) {
    // Main isolate can push pref updates here when the user toggles mute
    // / quiet hours. We re-read from FlutterForegroundTask.getData to
    // stay deterministic about the prefs storage layout.
    debugPrint('NotificationForegroundHandler.onReceiveData $data');
    if (data is Map && data['kind'] == 'prefs-updated') {
      unawaited(_readPrefs());
    }
  }

  @override
  void onNotificationPressed() {
    // The user tapped the persistent foreground-service indicator. Bring
    // the app to the foreground; per-event tray taps go through
    // `onNotificationTap` (the flutter_local_notifications tap handler)
    // not through here.
    FlutterForegroundTask.launchApp('/notifications');
  }

  // ---------- WebSocket ----------

  Future<void> _connect() async {
    if (_stopped) return;
    final host = _host, port = _port, token = _token;
    if (host == null || port == null || token == null) return;

    final uri = Uri.parse('ws://$host:$port/rpc');
    debugPrint('FGS-HANDLER: connecting to $uri');
    WebSocketChannel ch;
    try {
      ch = WebSocketChannel.connect(uri);
      await ch.ready;
      debugPrint('FGS-HANDLER: WS connected');
    } catch (e) {
      debugPrint('FGS-HANDLER: connect failed: $e');
      _scheduleReconnect();
      return;
    }
    _ws = ch;
    _wsSub = ch.stream.listen(
      _onMessage,
      onError: (Object e) {
        debugPrint('NotificationForegroundHandler: socket error: $e');
        _onSocketGone();
      },
      onDone: _onSocketGone,
      cancelOnError: true,
    );

    // Handshake. We send the SAME deviceId the main isolate uses so the
    // backend treats both connections as the same device for read-state
    // sync (design §4.5 multi-device semantics). Two parallel WS, ONE
    // device.
    final clientInfo = <String, dynamic>{
      'name': 'openvsmobile-flutter-fgservice',
    };
    if (_deviceId != null && _deviceId!.isNotEmpty) {
      clientInfo['deviceId'] = _deviceId;
    }
    try {
      await _rawCall('auth.handshake', {
        'token': token,
        'protocolVersion': '1.0',
        'client': clientInfo,
      });
      debugPrint('FGS-HANDLER: handshake OK');
    } catch (e) {
      debugPrint('FGS-HANDLER: handshake failed: $e');
      await _closeSocket();
      _scheduleReconnect();
      return;
    }
    try {
      await _rawCall('notification.subscribe');
      debugPrint('FGS-HANDLER: subscribe OK');
    } catch (e) {
      debugPrint('FGS-HANDLER: subscribe failed: $e');
    }
    _backoffStep = 0;
  }

  void _onSocketGone() {
    _wsSub?.cancel();
    _wsSub = null;
    _ws = null;
    if (_stopped) return;
    _scheduleReconnect();
  }

  Future<void> _closeSocket() async {
    try {
      await _wsSub?.cancel();
    } on StateError {
      // Already closed.
    }
    _wsSub = null;
    try {
      await _ws?.sink.close(ws_status.normalClosure);
    } on StateError {
      // Already closed.
    }
    _ws = null;
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    _reconnectTimer?.cancel();
    // Same backoff schedule as the main BackendClient.
    const schedule = [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ];
    final delay = schedule[_backoffStep.clamp(0, schedule.length - 1)];
    _backoffStep++;
    _reconnectTimer = Timer(delay, () => unawaited(_connect()));
  }

  /// Send a JSON-RPC call. Only auth.handshake and notification.subscribe
  /// are issued, sequentially, so a simple id-keyed completer map suffices.
  Future<Object?> _rawCall(String method, [Map<String, dynamic>? params]) {
    final ch = _ws;
    if (ch == null) {
      return Future.error(StateError('not connected'));
    }
    final id = _nextRpcId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final frame = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
    };
    if (params != null) frame['params'] = params;
    try {
      ch.sink.add(jsonEncode(frame));
    } catch (e) {
      _pending.remove(id);
      return Future.error(StateError('send failed: $e'));
    }
    return completer.future;
  }

  void _onMessage(dynamic raw) {
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      text = utf8.decode(raw);
    } else {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final id = decoded['id'];
    if (id != null) {
      final completer = _pending.remove(id is int ? id : (id as num).toInt());
      if (completer == null) return;
      if (decoded.containsKey('error')) {
        final err = decoded['error'];
        completer.completeError(
          StateError('rpc error: ${err is Map ? err['message'] : err}'),
        );
      } else {
        completer.complete(decoded['result']);
      }
      return;
    }
    final method = decoded['method'];
    if (method is! String) return;
    final params = decoded['params'];
    // Only process notification.* events. Everything else (terminal.*,
    // workspace.*) is fanned out to every subscriber but this isolate has
    // no business with it — drop silently.
    switch (method) {
      case 'notification.show':
        if (params is Map<String, dynamic>) {
          final raw = params['notification'];
          if (raw is Map<String, dynamic>) {
            unawaited(_handleShow(AppNotification.fromJson(raw)));
          }
        }
      case 'notification.deleted':
        if (params is Map<String, dynamic>) {
          final ids = (params['ids'] as List?)?.whereType<String>().toList() ??
              const <String>[];
          for (final i in ids) {
            unawaited(_notif.cancel(trayIdForNotification(i)));
          }
        }
      case 'notification.superseded':
        if (params is Map<String, dynamic>) {
          final oldId = params['oldId'];
          if (oldId is String) {
            unawaited(_notif.cancel(trayIdForNotification(oldId)));
          }
        }
      default:
        break; // Drop everything else.
    }
  }

  // ---------- System-tray emit ----------

  Future<void> _handleShow(AppNotification n) async {
    debugPrint('FGS-HANDLER: _handleShow title=${n.title} level=${n.level}');
    if (_mutedSources.contains(n.source)) {
      debugPrint('FGS-HANDLER: suppressing muted source ${n.source}');
      return;
    }
    final inQuiet = _inQuietHours();
    final channelId =
        inQuiet ? NotificationChannels.low : channelForLevel(n.level);
    debugPrint('FGS-HANDLER: channel=$channelId inQuiet=$inQuiet');
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
      debugPrint('FGS-HANDLER: show OK');
    } on PlatformException catch (e) {
      debugPrint('FGS-HANDLER: show failed: $e');
    }
  }

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

  bool _inQuietHours() {
    if (_quietStart < 0 || _quietEnd < 0) return false;
    if (_quietStart == _quietEnd) return false;
    final now = DateTime.now();
    final m = now.hour * 60 + now.minute;
    if (_quietStart < _quietEnd) {
      return m >= _quietStart && m < _quietEnd;
    }
    // Wraps across midnight (e.g. 22:00 → 07:00).
    return m >= _quietStart || m < _quietEnd;
  }

  // ---------- Prefs ----------

  Future<void> _readPrefs() async {
    _host = await FlutterForegroundTask.getData<String>(key: _ServicePrefs.host);
    _port = await FlutterForegroundTask.getData<int>(key: _ServicePrefs.port);
    _token =
        await FlutterForegroundTask.getData<String>(key: _ServicePrefs.token);
    _deviceId = await FlutterForegroundTask.getData<String>(
        key: _ServicePrefs.deviceId);
    final muted = await FlutterForegroundTask.getData<String>(
        key: _ServicePrefs.mutedSources);
    _mutedSources = muted == null || muted.isEmpty
        ? const <String>{}
        : muted.split(',').toSet();
    _quietStart = await FlutterForegroundTask.getData<int>(
            key: _ServicePrefs.quietStart) ??
        -1;
    _quietEnd =
        await FlutterForegroundTask.getData<int>(key: _ServicePrefs.quietEnd) ??
            -1;
  }

  Future<void> _initLocalNotifications() async {
    if (_notifInitialized) return;
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    );
    final initOk = await _notif.initialize(
      initSettings,
      onDidReceiveNotificationResponse: onNotificationTap,
    );
    debugPrint('FGS-HANDLER: _notif.initialize() returned $initOk');

    // Pre-create the per-level channels so they show up in the Android
    // Settings UI on first launch even before a notification arrives.
    final android = _notif.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) {
      debugPrint('FGS-HANDLER: AndroidFlutterLocalNotificationsPlugin is null — '
          'plugin not registered in this isolate. Trying MethodChannel fallback.');
      // Fallback: attempt to show a test notification directly through the
      // plugin's top-level API; if it works, channels will be auto-created.
      try {
        await _notif.show(
          99999,
          'Notification service started',
          'Listening for backend notifications',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              NotificationChannels.defaultImp,
              'Notifications',
              importance: Importance.defaultImportance,
            ),
          ),
        );
        debugPrint('FGS-HANDLER: fallback test notification OK');
      } on PlatformException catch (e) {
        debugPrint('FGS-HANDLER: fallback test notification failed: $e');
      }
      _notifInitialized = true;
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
    debugPrint('FGS-HANDLER: notification channels created');
    _notifInitialized = true;
  }
}

// ---------- Main-isolate side: a tiny controller ----------

/// A tiny façade owned by the main isolate that decides whether/when to
/// start or stop the foreground service and persists the connection prefs
/// the service needs to do its job. Kept here (next to the handler) so the
/// service-side and main-side surfaces stay co-located.
class NotificationServiceController {
  bool _initialized = false;

  /// Configure the channel for the persistent foreground-service indicator
  /// + the per-event channels. Safe to call multiple times.
  void init() {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: NotificationChannels.persistent,
        channelName: 'Service status',
        channelDescription: 'Indicator that openvsmobile-next is listening '
            'for backend notifications.',
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

  /// Persist connection params for the service isolate, then start the
  /// service. Returns false if start was rejected (typically permission
  /// denied — the caller has already prompted; we surface state via the
  /// returned bool so the UI toggle can revert).
  Future<bool> start({
    required String host,
    required int port,
    required String token,
    required String deviceId,
    required List<String> mutedSources,
    int quietStartMinutes = -1,
    int quietEndMinutes = -1,
  }) async {
    if (!_initialized) init();
    await FlutterForegroundTask.saveData(
        key: _ServicePrefs.host, value: host);
    await FlutterForegroundTask.saveData(
        key: _ServicePrefs.port, value: port);
    await FlutterForegroundTask.saveData(
        key: _ServicePrefs.token, value: token);
    await FlutterForegroundTask.saveData(
        key: _ServicePrefs.deviceId, value: deviceId);
    await FlutterForegroundTask.saveData(
        key: _ServicePrefs.mutedSources, value: mutedSources.join(','));
    await FlutterForegroundTask.saveData(
        key: _ServicePrefs.quietStart, value: quietStartMinutes);
    await FlutterForegroundTask.saveData(
        key: _ServicePrefs.quietEnd, value: quietEndMinutes);
    final alreadyRunning = await FlutterForegroundTask.isRunningService;
    debugPrint('FGS-CTRL: isRunningService=$alreadyRunning');
    if (alreadyRunning) {
      FlutterForegroundTask.sendDataToTask({'kind': 'prefs-updated'});
      return true;
    }
    debugPrint('FGS-CTRL: calling startService...');
    final r = await FlutterForegroundTask.startService(
      serviceId: kForegroundServiceId,
      notificationTitle: 'openvsmobile-next',
      notificationText: 'Listening for backend notifications',
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

  /// Refresh just the dynamic prefs (mute list / quiet hours) without
  /// restarting the service. The handler picks up the change via the
  /// SendPort message.
  Future<void> updatePrefs({
    required List<String> mutedSources,
    int quietStartMinutes = -1,
    int quietEndMinutes = -1,
  }) async {
    await FlutterForegroundTask.saveData(
        key: _ServicePrefs.mutedSources, value: mutedSources.join(','));
    await FlutterForegroundTask.saveData(
        key: _ServicePrefs.quietStart, value: quietStartMinutes);
    await FlutterForegroundTask.saveData(
        key: _ServicePrefs.quietEnd, value: quietEndMinutes);
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask({'kind': 'prefs-updated'});
    }
  }

  Future<bool> get isRunning => FlutterForegroundTask.isRunningService;
}
