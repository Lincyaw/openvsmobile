// Deep-link service — catches `mobilecode://notifications/<id>` URIs from
// the ntfy Android app's tray-notification `Click` action and surfaces the
// notification id to main.dart.
//
// Two delivery paths, both mapped to the same exposed surface so main.dart
// has one consumption point:
//   1. Cold start: app was dead, OS launched us with the URI in the launch
//      intent. `appLinks.getInitialLink()` returns it once.
//   2. Warm: app already running. `appLinks.uriLinkStream` emits each tap.
//
// API mirrors `consumePendingTapNotificationId()` in
// notification_foreground_service.dart — a static slot that the consumer
// reads-and-clears, plus a listener so the consumer can react to taps
// arriving while the app is running. We intentionally keep both patterns
// rather than picking one, because the FGS path is consume-on-resume and
// the ntfy/uriLinkStream path is push-driven.

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Bridges the app_links plugin to main.dart. Construct once during
/// bootstrap. Disposal stops the stream subscription.
class DeepLinkService {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  bool _initialized = false;

  /// Set by `init()` from `getInitialLink()`. Consumed by main.dart on the
  /// first frame the same way `consumePendingTapNotificationId()` is. Null
  /// once consumed.
  String? _pendingId;

  /// Listeners fire each time a URI arrives while the app is running.
  /// main.dart attaches one that pushes the notification center route.
  /// Cold-start IDs go through `consumePendingId()` instead (they're
  /// available before any listener could be attached).
  final List<void Function(String id)> _listeners = [];

  /// Wire up the plugin. Safe to call multiple times — guarded.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        final id = _extractNotificationId(initial);
        if (id != null) _pendingId = id;
      }
    } catch (err) {
      // The plugin throws on a few platforms when no launch intent exists.
      // That's a normal cold start without a deep link — log and move on.
      debugPrint('DeepLinkService: getInitialLink failed: $err');
    }
    _sub = _appLinks.uriLinkStream.listen(
      (uri) {
        final id = _extractNotificationId(uri);
        if (id == null) return;
        for (final fn in List<void Function(String)>.from(_listeners)) {
          fn(id);
        }
      },
      onError: (Object err) {
        debugPrint('DeepLinkService: uri stream error: $err');
      },
    );
  }

  /// Returns the pending cold-start id once, then clears it. Same contract
  /// as `consumePendingTapNotificationId()` so main.dart can use the
  /// identical guard pattern.
  String? consumePendingId() {
    final v = _pendingId;
    _pendingId = null;
    return v;
  }

  /// Register a callback for live (warm-path) deep links. Returns a
  /// remover that the caller invokes on dispose.
  VoidCallback addListener(void Function(String id) fn) {
    _listeners.add(fn);
    return () => _listeners.remove(fn);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _listeners.clear();
  }

  /// Pull the notification id out of `mobilecode://notifications/<id>`.
  /// Returns null on anything else — we deliberately don't try to route
  /// other deep-link shapes from this service.
  static String? _extractNotificationId(Uri uri) {
    if (uri.scheme != 'mobilecode') return null;
    if (uri.host != 'notifications') return null;
    final segments = uri.pathSegments;
    if (segments.isEmpty) return null;
    final id = segments.first;
    if (id.isEmpty) return null;
    return id;
  }
}
