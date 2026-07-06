// WebSocket JSON-RPC client with WeChat-style always-on connection.
//
// Lifecycle:
//   configure(host, port, token) — remember settings.
//   start()                      — open + keep reopening until userDisconnect().
//   userDisconnect()             — stop and never auto-reconnect.
//   call(method, params)         — JSON-RPC request; queued during reconnect.
//
// Resilience model:
//   * Auto-reconnect with exponential backoff [1, 2, 4, 8, 16, 30, 30, …] s,
//     reset on successful handshake.
//   * Connectivity-aware: stay in `waitingForNetwork` while the OS reports
//     no link; reconnect immediately on link restore.
//   * App-lifecycle aware: external code can call [requestReconnectNow] when
//     the app comes back to the foreground.
//   * Heartbeat: `system.ping` every 25 s; force-close after 10 s of silence.
//   * Outbound queue: requests issued while transitioning queue for 15 s.
//
// The state machine is intentionally explicit so the UI can render the
// "Connecting…" banner without false-positive red errors on transient drops.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import 'settings_store.dart';
import 'version.dart';

/// Notification method names the backend pushes. Listed as constants so flow
/// control in AppState doesn't switch on bare strings — see
/// docs/conventions.md §2 (Single source of truth: AppState).
class BackendNotifications {
  BackendNotifications._();
  static const String terminalData = 'terminal.data';
  static const String terminalExit = 'terminal.exit';
  static const String terminalDetached = 'terminal.detached';
  static const String terminalRenamed = 'terminal.renamed';
  static const String workspaceClosed = 'workspace.closed';
  static const String workspaceTreeDelta = 'workspace.tree.delta';
  static const String workspaceDecorationDelta = 'workspace.decoration.delta';
  static const String workspaceDecorationSnapshot =
      'workspace.decoration.snapshot';
  static const String workspaceHeadChanged = 'workspace.head.changed';
  static const String workspaceCommitAdded = 'workspace.commit.added';
  static const String notificationShow = 'notification.show';
  static const String notificationReadChanged = 'notification.readChanged';
  static const String notificationDeleted = 'notification.deleted';
  static const String notificationSuperseded = 'notification.superseded';
  static const String pluginStateChanged = 'plugin.stateChanged';
}

/// Permanent-error JSON-RPC code returned by the backend on a failed
/// `auth.handshake`. Mirrors `RPC_ERR.unauthorized` on the server side.
const int kRpcUnauthorized = -32002;

enum BackendConnectionState {
  /// No socket; either never started or [userDisconnect] was called.
  disconnected,

  /// First connect attempt is in flight (TCP + handshake).
  connecting,

  /// Handshake succeeded; live and serviceable.
  connected,

  /// Lost a previously-good connection; backoff retry loop is running.
  reconnecting,

  /// OS reports no connectivity. Backoff is paused; we will retry the moment
  /// connectivity returns.
  waitingForNetwork,

  /// Permanent error (e.g. unauthorized). Stays here until [configure] +
  /// [start] are called again.
  failed,
}

class BackendNotification {
  final String method;
  final dynamic params;
  const BackendNotification(this.method, this.params);
}

class BackendRpcException implements Exception {
  final int code;
  final String message;
  final dynamic data;
  BackendRpcException(this.code, this.message, [this.data]);
  @override
  String toString() => 'BackendRpcException($code): $message';
}

/// Implementation contract for the OS-connectivity probe. The default
/// implementation in `main.dart` wires this to `connectivity_plus`; tests
/// can substitute a fake.
abstract class ConnectivityProbe {
  /// Emits `true` when there's at least one usable link (wifi/mobile/etc).
  Stream<bool> get changes;

  /// One-shot current state.
  Future<bool> isOnline();
}

/// A `ConnectivityProbe` that always reports "online". Used when the host
/// platform doesn't surface connectivity info — degrades gracefully to "just
/// rely on the socket + heartbeat".
class AlwaysOnlineProbe implements ConnectivityProbe {
  @override
  Stream<bool> get changes => const Stream.empty();
  @override
  Future<bool> isOnline() async => true;
}

/// Tunables for the always-on transport layer. Defaults are the values
/// production has shipped with since v0; tests inject a fast variant to
/// avoid 15 s waits in the queue-budget path.
@immutable
class BackendClientTiming {
  /// Heartbeat ping cadence. 25 s detects a silently dropped NAT entry
  /// well before the typical 60–120 s carrier idle timeout, while staying
  /// cheap enough that always-on is acceptable.
  final Duration heartbeatInterval;

  /// How long we wait for the pong before force-closing.
  final Duration heartbeatGrace;

  /// How long a queued call sits hoping for a reconnect before failing
  /// with "connection unavailable".
  final Duration queueBudget;

  /// Reconnect backoff schedule, capped at the last entry.
  final List<Duration> backoff;

  const BackendClientTiming({
    this.heartbeatInterval = const Duration(seconds: 25),
    this.heartbeatGrace = const Duration(seconds: 10),
    this.queueBudget = const Duration(seconds: 15),
    this.backoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ],
  });
}

const BackendClientTiming _kDefaultTiming = BackendClientTiming();

class BackendClient {
  BackendClient({ConnectivityProbe? probe, BackendClientTiming? timing})
    : _probe = probe ?? AlwaysOnlineProbe(),
      _timing = timing ?? _kDefaultTiming;

  final ConnectivityProbe _probe;
  final BackendClientTiming _timing;
  StreamSubscription<bool>? _connectivitySub;

  /// Current connection state. Listenable for UI.
  final ValueNotifier<BackendConnectionState> state = ValueNotifier(
    BackendConnectionState.disconnected,
  );

  /// Last failure message; cleared on successful handshake.
  final ValueNotifier<String?> lastError = ValueNotifier(null);

  /// Server-provided default cwd from handshake. Empty until first connect.
  String defaultCwd = '';

  // --- Configured settings (set by configure()) ---
  String? _host;
  int? _port;
  String? _token;
  String? _deviceId;
  BackendTransport _transport = BackendTransport.websocket;
  String? _irohTicket;
  String? _irohAlpn;

  // --- Socket / RPC plumbing ---
  _RpcSocket? _channel;
  StreamSubscription<dynamic>? _sub;
  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  final StreamController<BackendNotification> _notifs =
      StreamController.broadcast();

  // --- Reconnect state ---
  bool _userStop = true; // true until start() is called
  int _backoffStep = 0;
  Timer? _reconnectTimer;
  bool _online = true;

  // --- Heartbeat state ---
  Timer? _heartbeatTimer;
  Timer? _heartbeatTimeout;

  // --- Outbound queue ---
  final List<_QueuedCall> _queue = [];

  Stream<BackendNotification> get notifications => _notifs.stream;
  bool get isConnected => state.value == BackendConnectionState.connected;

  /// Set the target endpoint. Does not initiate a connection — call
  /// [start] when ready.
  void configure({
    required String host,
    required int port,
    required String token,
    BackendTransport transport = BackendTransport.websocket,
    String? irohTicket,
    String? irohAlpn,
    String? deviceId,
  }) {
    _host = host;
    _port = port;
    _token = token;
    _transport = transport;
    _irohTicket = irohTicket;
    _irohAlpn = irohAlpn;
    _deviceId = deviceId;
  }

  /// Update the device id passed in `auth.handshake.client.deviceId`.
  /// Safe to call before [start]; if called after a successful handshake the
  /// new id only takes effect on the next reconnect (the backend reads
  /// deviceId once per connection — see notifications design §4.5).
  // ignore: avoid_setters_without_getters
  set deviceId(String? id) {
    _deviceId = id;
  }

  /// Begin (or restart) the auto-reconnect loop. Idempotent.
  Future<void> start() async {
    _userStop = false;
    _backoffStep = 0;
    // Subscribe to connectivity once.
    _connectivitySub ??= _probe.changes.listen(_onConnectivity);
    try {
      _online = await _probe.isOnline();
    } catch (_) {
      _online = true; // fail open
    }
    if (!_online) {
      state.value = BackendConnectionState.waitingForNetwork;
      return;
    }
    await _attemptConnect(reset: true);
  }

  /// Permanent stop. Cancels timers, drops queued calls, closes the socket.
  /// The caller is expected to call [configure] + [start] again to come back.
  Future<void> userDisconnect() async {
    _userStop = true;
    _cancelReconnect();
    _stopHeartbeat();
    _drainQueue('user disconnected');
    await _closeSocket();
    state.value = BackendConnectionState.disconnected;
    lastError.value = null;
  }

  /// Force an immediate reconnect attempt. Used by the app-lifecycle observer
  /// on `resumed` to short-circuit the backoff timer.
  void requestReconnectNow() {
    if (_userStop) return;
    if (state.value == BackendConnectionState.connected) {
      _probeConnectedSocket();
      return;
    }
    if (state.value == BackendConnectionState.connecting) {
      return;
    }
    if (!_online) {
      // Pointless — we'll reconnect when connectivity returns.
      return;
    }
    _cancelReconnect();
    _backoffStep = 0;
    unawaited(_attemptConnect(reset: true));
  }

  void _probeConnectedSocket() {
    _rawCall('system.ping', const {})
        .timeout(_resumeProbeTimeout())
        .then((_) {
          // The connection is alive; stay connected.
        })
        .catchError((Object e) {
          lastError.value = 'resume ping failed: $e';
          _dropSocketAndReconnect();
        });
  }

  Duration _resumeProbeTimeout() {
    const cap = Duration(seconds: 2);
    return _timing.heartbeatGrace < cap ? _timing.heartbeatGrace : cap;
  }

  void _onConnectivity(bool online) {
    _online = online;
    if (_userStop) return;
    if (!online) {
      // Lose link → park in waitingForNetwork until it comes back.
      _cancelReconnect();
      _stopHeartbeat();
      // Don't fail pending calls yet — within their budget they may survive
      // a quick blip.
      if (state.value != BackendConnectionState.failed) {
        state.value = BackendConnectionState.waitingForNetwork;
      }
      return;
    }
    // Online again. If we're not already connected/connecting, reconnect ASAP.
    if (state.value == BackendConnectionState.waitingForNetwork ||
        state.value == BackendConnectionState.reconnecting) {
      _backoffStep = 0;
      _cancelReconnect();
      unawaited(_attemptConnect(reset: true));
    }
  }

  Future<void> _attemptConnect({required bool reset}) async {
    if (_userStop) return;
    final host = _host, port = _port, token = _token;
    if (token == null) {
      state.value = BackendConnectionState.failed;
      lastError.value = 'no settings configured';
      return;
    }
    if (reset) {
      // First attempt in a (re)start sequence.
      state.value =
          state.value == BackendConnectionState.disconnected ||
              state.value == BackendConnectionState.waitingForNetwork
          ? BackendConnectionState.connecting
          : (state.value == BackendConnectionState.connected
                ? BackendConnectionState.reconnecting
                : state.value);
    }

    _RpcSocket ch;
    try {
      ch = await _openSocket(host: host, port: port);
      await ch.ready;
    } catch (e) {
      lastError.value = 'connect failed: $e';
      _scheduleReconnect();
      return;
    }

    _channel = ch;
    _sub = ch.stream.listen(
      _onMessage,
      onError: (Object e) {
        lastError.value = 'socket error: $e';
        _onSocketGone();
      },
      onDone: () {
        _onSocketGone();
      },
      cancelOnError: true,
    );

    try {
      final clientInfo = <String, dynamic>{
        'name': 'openvsmobile-flutter',
        // `version` mirrors the kBackendVersion constant so it stays in
        // lockstep with the release tag; no second source of truth.
        'version': kBackendVersion,
      };
      // `deviceId` is a stable per-install UUID used by the notification
      // system to sync read state across reconnects and across devices. The
      // backend reads it from `client.deviceId` on the handshake. See
      // design §4.5 "Multi-device semantics".
      final did = _deviceId;
      if (did != null && did.isNotEmpty) {
        clientInfo['deviceId'] = did;
      }
      final hsResult =
          await _rawCall('auth.handshake', {
                'token': token,
                'protocolVersion': '1.0',
                'client': clientInfo,
              })
              as Map<String, dynamic>;
      final cwd = hsResult['defaultCwd'];
      defaultCwd = cwd is String ? cwd : '/';
    } on BackendRpcException catch (e) {
      // Auth failure is permanent — user has to fix settings.
      if (e.code == kRpcUnauthorized) {
        lastError.value = 'auth failed: ${e.message}';
        await _closeSocket();
        state.value = BackendConnectionState.failed;
        return;
      }
      lastError.value = 'handshake error: ${e.message}';
      await _closeSocket();
      _scheduleReconnect();
      return;
    } catch (e) {
      lastError.value = 'handshake failed: $e';
      await _closeSocket();
      _scheduleReconnect();
      return;
    }

    // Success.
    _backoffStep = 0;
    lastError.value = null;
    state.value = BackendConnectionState.connected;
    _startHeartbeat();
    _flushQueue();
  }

  Future<_RpcSocket> _openSocket({String? host, int? port}) async {
    switch (_transport) {
      case BackendTransport.websocket:
        if (host == null || port == null) {
          throw StateError('missing WebSocket host/port');
        }
        final uri = Uri.parse('ws://$host:$port/rpc');
        return _WebSocketRpcSocket(WebSocketChannel.connect(uri));
      case BackendTransport.iroh:
        final ticket = _irohTicket;
        if (ticket == null || ticket.trim().isEmpty) {
          throw StateError('missing Iroh ticket');
        }
        return _IrohRpcSocket.connect(
          ticket: ticket.trim(),
          alpn: (_irohAlpn == null || _irohAlpn!.trim().isEmpty)
              ? 'openvsmobile.rpc.v1'
              : _irohAlpn!.trim(),
        );
    }
  }

  void _onSocketGone() {
    _stopHeartbeat();
    final hadChannel = _channel != null;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    // Fail pending requests that aren't in the resumable queue.
    _failPending('connection dropped');
    if (_userStop) {
      state.value = BackendConnectionState.disconnected;
      return;
    }
    if (state.value == BackendConnectionState.failed) {
      return;
    }
    if (!hadChannel) return;
    if (!_online) {
      state.value = BackendConnectionState.waitingForNetwork;
      return;
    }
    state.value = BackendConnectionState.reconnecting;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_userStop) return;
    if (!_online) {
      state.value = BackendConnectionState.waitingForNetwork;
      return;
    }
    _cancelReconnect();
    final backoff = _timing.backoff;
    final delay = backoff[_backoffStep.clamp(0, backoff.length - 1)];
    _backoffStep++;
    state.value = BackendConnectionState.reconnecting;
    _reconnectTimer = Timer(delay, () {
      unawaited(_attemptConnect(reset: false));
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  // ---- Heartbeat ----

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatTimer = Timer.periodic(_timing.heartbeatInterval, (_) {
      if (state.value != BackendConnectionState.connected) return;
      _heartbeatTimeout = Timer(_timing.heartbeatGrace, () {
        // No pong → force-close. _onSocketGone runs and starts backoff.
        lastError.value = 'heartbeat timeout';
        _dropSocketAndReconnect();
      });
      _rawCall('system.ping', const {})
          .then((_) {
            _heartbeatTimeout?.cancel();
            _heartbeatTimeout = null;
          })
          .catchError((Object _) {
            _heartbeatTimeout?.cancel();
            _heartbeatTimeout = null;
            // A send-side failure may happen before the stream's onDone/onError
            // callback runs. Drive the reconnect path directly so we never get
            // stuck in connected-with-no-channel.
            _dropSocketAndReconnect();
          });
    });
  }

  void _dropSocketAndReconnect() {
    final ch = _channel;
    if (ch == null) {
      _stopHeartbeat();
      _failPending('connection dropped');
      if (_userStop) {
        state.value = BackendConnectionState.disconnected;
        return;
      }
      if (state.value == BackendConnectionState.failed) return;
      if (!_online) {
        state.value = BackendConnectionState.waitingForNetwork;
        return;
      }
      _scheduleReconnect();
      return;
    }
    _onSocketGone();
    unawaited(ch.sink.close(ws_status.normalClosure).catchError((_) {}));
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatTimeout?.cancel();
    _heartbeatTimeout = null;
  }

  // ---- Outbound queue ----

  /// JSON-RPC call. Behaviour by state:
  ///   connected             — sent immediately.
  ///   connecting/reconnecting/waitingForNetwork — queued up to 15 s.
  ///   disconnected/failed   — rejected synchronously.
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) {
    final s = state.value;
    if (s == BackendConnectionState.connected) {
      return _rawCall(method, params);
    }
    if (s == BackendConnectionState.disconnected ||
        s == BackendConnectionState.failed) {
      return Future.error(BackendRpcException(-1, 'not connected'));
    }
    // In a transitional state — queue.
    final completer = Completer<dynamic>();
    final entry = _QueuedCall(
      method: method,
      params: params,
      completer: completer,
    );
    entry.timer = Timer(_timing.queueBudget, () {
      if (_queue.remove(entry) && !completer.isCompleted) {
        completer.completeError(
          BackendRpcException(-1, 'connection unavailable'),
        );
      }
    });
    _queue.add(entry);
    return completer.future;
  }

  void _flushQueue() {
    final drained = List<_QueuedCall>.from(_queue);
    _queue.clear();
    for (final q in drained) {
      q.timer?.cancel();
      if (q.completer.isCompleted) continue;
      _rawCall(
        q.method,
        q.params,
      ).then(q.completer.complete, onError: q.completer.completeError);
    }
  }

  void _drainQueue(String reason) {
    final drained = List<_QueuedCall>.from(_queue);
    _queue.clear();
    for (final q in drained) {
      q.timer?.cancel();
      if (!q.completer.isCompleted) {
        q.completer.completeError(BackendRpcException(-1, reason));
      }
    }
  }

  // ---- Wire send/recv ----

  Future<dynamic> _rawCall(String method, [Map<String, dynamic>? params]) {
    final ch = _channel;
    if (ch == null) {
      return Future.error(BackendRpcException(-1, 'not connected'));
    }
    final id = _nextId++;
    final completer = Completer<dynamic>();
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
      return Future.error(BackendRpcException(-1, 'send failed: $e'));
    }
    return completer.future;
  }

  Future<void> _closeSocket() async {
    try {
      await _sub?.cancel();
    } catch (_) {
      // Already closed — cancel() on a finished subscription is a no-op
      // but the underlying transport may still throw on a torn socket.
    }
    _sub = null;
    try {
      await _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {
      // Already closed (peer dropped, error path, race with _onSocketGone).
    }
    _channel = null;
    _failPending('socket closed');
  }

  void _failPending(String reason) {
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(BackendRpcException(-1, reason));
      }
    }
    _pending.clear();
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
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final id = decoded['id'];
    if (id != null) {
      final completer = _pending.remove(id is int ? id : (id as num).toInt());
      if (completer == null) return;
      if (decoded.containsKey('error')) {
        final err = decoded['error'] as Map<String, dynamic>;
        completer.completeError(
          BackendRpcException(
            (err['code'] as num).toInt(),
            err['message'] as String? ?? 'error',
            err['data'],
          ),
        );
      } else {
        completer.complete(decoded['result']);
      }
      return;
    }
    final method = decoded['method'];
    if (method is String) {
      _notifs.add(BackendNotification(method, decoded['params']));
    }
  }

  Future<void> dispose() async {
    await userDisconnect();
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    await _notifs.close();
    state.dispose();
    lastError.dispose();
  }
}

class _QueuedCall {
  final String method;
  final Map<String, dynamic>? params;
  final Completer<dynamic> completer;
  Timer? timer;
  _QueuedCall({
    required this.method,
    required this.params,
    required this.completer,
  });
}

abstract class _RpcSocket {
  Future<void> get ready;
  Stream<dynamic> get stream;
  _RpcSink get sink;
}

abstract class _RpcSink {
  void add(Object? data);
  Future<void> close([int? closeCode, String? closeReason]);
}

class _WebSocketRpcSocket implements _RpcSocket {
  final WebSocketChannel _channel;
  _WebSocketRpcSocket(this._channel);

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  _RpcSink get sink => _WebSocketRpcSink(_channel.sink);
}

class _WebSocketRpcSink implements _RpcSink {
  final WebSocketSink _sink;
  _WebSocketRpcSink(this._sink);

  @override
  void add(Object? data) => _sink.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    await _sink.close(closeCode, closeReason);
  }
}

class _IrohRpcSocket implements _RpcSocket {
  static const MethodChannel _methods = MethodChannel(
    'dev.lincyaw.mobilecode/iroh_rpc',
  );
  static const EventChannel _events = EventChannel(
    'dev.lincyaw.mobilecode/iroh_rpc_events',
  );
  static Stream<dynamic>? _sharedEvents;

  final int _id;
  final StreamController<dynamic> _controller = StreamController.broadcast();
  late final StreamSubscription<dynamic> _sub;
  bool _closed = false;

  _IrohRpcSocket._(this._id) {
    _sharedEvents ??= _events.receiveBroadcastStream().asBroadcastStream();
    _sub = _sharedEvents!.listen(
      _onEvent,
      onError: _controller.addError,
      cancelOnError: false,
    );
  }

  static Future<_IrohRpcSocket> connect({
    required String ticket,
    required String alpn,
  }) async {
    final id = await _methods.invokeMethod<int>('connect', {
      'ticket': ticket,
      'alpn': alpn,
    });
    if (id == null) {
      throw StateError('Iroh connect returned no connection id');
    }
    return _IrohRpcSocket._(id);
  }

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  _RpcSink get sink => _IrohRpcSink(this);

  void _onEvent(dynamic raw) {
    if (_closed || raw is! Map) return;
    final id = raw['id'];
    if (id is! int || id != _id) return;
    final type = raw['type'];
    switch (type) {
      case 'message':
        final text = raw['text'];
        if (text is String) _controller.add(text);
      case 'closed':
        unawaited(_finishClosed());
      case 'error':
        _controller.addError(
          PlatformException(
            code: 'IROH_ERROR',
            message: raw['message'] as String? ?? 'Iroh transport error',
          ),
        );
        unawaited(_finishClosed());
    }
  }

  Future<void> send(String text) async {
    await _methods.invokeMethod<void>('send', {'id': _id, 'text': text});
  }

  Future<void> close([int? closeCode, String? closeReason]) async {
    if (_closed) return;
    try {
      await _methods.invokeMethod<void>('close', {
        'id': _id,
        'code': ?closeCode,
        'reason': ?closeReason,
      });
    } finally {
      await _finishClosed();
    }
  }

  Future<void> _finishClosed() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    await _controller.close();
  }
}

class _IrohRpcSink implements _RpcSink {
  final _IrohRpcSocket _socket;
  _IrohRpcSink(this._socket);

  @override
  void add(Object? data) {
    unawaited(
      _socket.send(data.toString()).catchError((Object e) {
        _socket._controller.addError(e);
      }),
    );
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _socket.close(closeCode, closeReason);
}
