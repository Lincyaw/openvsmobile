// Notification surface (design §4.5) — client mirror.
//
// Composed under AppState; AppState forwards `notifyListeners`. Backend is
// the source of truth (CLAUDE.md first principle #1): we subscribe once on
// connect and let push events drive every mutation. Multi-device read state
// uses a stable `deviceId` carried in the auth handshake and persisted under
// the `device-id` SharedPreferences key — see AppState wiring.
//
// Mutability discipline (conventions §2 + PR-B review N3): the internal
// `Map<String, AppNotification>` and `Set<String>` never leak out; getters
// return `UnmodifiableMapView` / `UnmodifiableListView` so widgets can't
// silently desync the sorted projection cache by mutating in place.
//
// Optimistic ops: `markRead` / `deleteIds` / `markImportant` flip local
// state immediately so the UI stays responsive even on a marginal link,
// then the matching `notification.readChanged` / `notification.deleted`
// push confirms (and brings other devices' edits along for the ride).
// A failed RPC reverts the optimistic patch and surfaces via `reportError`.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../backend_client.dart';
import '../notification.dart';

// Push method-name constants live in `BackendNotifications` (see
// backend_client.dart). The previous in-file `NotificationPushMethods` class
// duplicated those strings and was unreferenced — removed to keep one source
// of truth for wire identifiers.

class NotificationsModel extends ChangeNotifier {
  final BackendClient _client;
  final String Function() _deviceId;
  final void Function(String message) _reportError;

  /// Notification id → full payload. Insertion order is irrelevant; the
  /// sorted projection ([items]) is recomputed lazily.
  final Map<String, AppNotification> _items = {};

  /// Tombstones for ids the user has just asked to delete, kept until the
  /// matching `notification.deleted` push lands. Without this, an optimistic
  /// delete would briefly re-appear if a stale `notification.show` for the
  /// same id raced past us (won't happen with the current backend, but cheap
  /// insurance against future flap).
  final Set<String> _deletedIds = {};

  /// Source filter; `null` means "show all".
  String? _filterSource;

  /// Cached sorted-by-timestamp-desc projection. Invalidated on every
  /// mutation so we don't pay the sort cost per notifyListeners.
  List<AppNotification>? _sortedCache;

  bool _subscribed = false;

  NotificationsModel({
    required BackendClient client,
    required String Function() deviceId,
    required void Function(String message) reportError,
  }) : this._(client, deviceId, reportError);

  NotificationsModel._(this._client, this._deviceId, this._reportError);

  // ---- Read API ----

  /// All notifications sorted by `timestamp DESC`. Superseded entries are
  /// filtered out of the main feed per §4.5 ("Clients hide superseded
  /// entries from the main feed").
  UnmodifiableListView<AppNotification> get items {
    final cache = _sortedCache ??= _computeSorted();
    return UnmodifiableListView(cache);
  }

  /// Filtered by [_filterSource] when set; same sort order as [items].
  UnmodifiableListView<AppNotification> get filteredItems {
    final all = _sortedCache ??= _computeSorted();
    if (_filterSource == null) return UnmodifiableListView(all);
    return UnmodifiableListView(
      all.where((n) => n.source == _filterSource).toList(growable: false),
    );
  }

  /// Distinct sources seen across all (non-superseded) notifications, sorted
  /// alphabetically for stable pill order.
  UnmodifiableListView<String> get knownSources {
    final s = <String>{};
    for (final n in _items.values) {
      if (n.supersededBy != null) continue;
      if (n.source.isNotEmpty) s.add(n.source);
    }
    final l = s.toList()..sort();
    return UnmodifiableListView(l);
  }

  /// Count of notifications NOT yet read by this device. Superseded entries
  /// don't count — they're hidden from the feed.
  int get unreadCount {
    final me = _deviceId();
    var c = 0;
    for (final n in _items.values) {
      if (n.supersededBy != null) continue;
      if (!n.readByDevice(me)) c++;
    }
    return c;
  }

  /// Count of unread rows that should interrupt the user at chrome level.
  /// Routine info/success messages still show a subtle dot on the bell, but
  /// only important / warning / error rows earn a numeric badge.
  int get attentionCount {
    final me = _deviceId();
    var c = 0;
    for (final n in _items.values) {
      if (n.supersededBy != null) continue;
      if (n.readByDevice(me)) continue;
      if (_needsAttention(n)) c++;
    }
    return c;
  }

  String? get filterSource => _filterSource;
  bool get subscribed => _subscribed;

  AppNotification? byId(String id) => _items[id];

  /// True if [id] is read by this device. False on unknown id (defensive).
  bool isRead(String id) {
    final n = _items[id];
    if (n == null) return false;
    return n.readByDevice(_deviceId());
  }

  bool _needsAttention(AppNotification n) {
    if (n.important) return true;
    return switch (n.level) {
      NotificationLevel.warning || NotificationLevel.error => true,
      NotificationLevel.info || NotificationLevel.success => false,
    };
  }

  // ---- Filter ----

  void setSourceFilter(String? source) {
    if (_filterSource == source) return;
    _filterSource = source;
    notifyListeners();
  }

  // ---- Push handlers (called from AppState._onNotification) ----

  void onShow(AppNotification n) {
    if (_deletedIds.contains(n.id)) {
      // We optimistically deleted this id; ignore late re-arrivals. Real
      // life: backend doesn't re-show deleted ids, but if a `notification.show`
      // was already in flight when we deleted, this is the cheap guard.
      return;
    }
    _items[n.id] = n;
    _invalidateSort();
    notifyListeners();
  }

  /// `notification.superseded { oldId, newId }` — the new row's `show` push
  /// fires separately. We just stamp the old row's `supersededBy` so it
  /// drops out of the feed projection.
  void onSuperseded(String oldId, String newId) {
    final old = _items[oldId];
    if (old == null) return;
    _items[oldId] = AppNotification(
      id: old.id,
      source: old.source,
      level: old.level,
      title: old.title,
      body: old.body,
      fields: old.fields,
      links: old.links,
      action: old.action,
      spoken: old.spoken,
      reply: old.reply,
      groupKey: old.groupKey,
      supersedes: old.supersedes,
      supersededBy: newId,
      important: old.important,
      ttl: old.ttl,
      ttlUntil: old.ttlUntil,
      timestamp: old.timestamp,
      widget: old.widget,
      readBy: old.readBy,
    );
    _invalidateSort();
    notifyListeners();
  }

  /// `notification.readChanged { ids, readByDevice, ts }` — multi-device
  /// sync. Append `readByDevice` to each row's `readBy` if not already there.
  void onReadChanged(List<String> ids, String readByDevice, int ts) {
    var any = false;
    for (final id in ids) {
      final n = _items[id];
      if (n == null) continue;
      if (n.readByDevice(readByDevice)) continue;
      final nextReaders = List<String>.from(n.readBy)..add(readByDevice);
      _items[id] = n.withReadBy(nextReaders);
      any = true;
    }
    if (any) notifyListeners();
  }

  /// `notification.deleted { ids }` — also fires on GC sweeps. Drops the
  /// matching ids from the local map and clears any tombstone we held.
  void onDeleted(List<String> ids) {
    var any = false;
    for (final id in ids) {
      if (_items.remove(id) != null) any = true;
      _deletedIds.remove(id);
    }
    if (any) {
      _invalidateSort();
      notifyListeners();
    }
  }

  // ---- RPC actions ----

  /// Highest timestamp (ms since epoch) we've ingested via push or refresh.
  /// Used as `sinceTs` on reconnect so the backend can deliver the
  /// incremental tail without resending the whole feed. Returns 0 when the
  /// local map is empty (first connect).
  int get lastSeenTs {
    var max = 0;
    for (final n in _items.values) {
      if (n.timestamp > max) max = n.timestamp;
    }
    return max;
  }

  /// Subscribe to push fan-out. [sinceTs], when non-zero, asks the backend to
  /// deliver only rows newer than the given timestamp on the subscribe ack
  /// — forward-compatible: backend support for `sinceTs` on
  /// `notification.subscribe` is pending.
  Future<void> subscribe({int sinceTs = 0}) async {
    try {
      final params = <String, dynamic>{};
      if (sinceTs > 0) params['sinceTs'] = sinceTs;
      await _client.call('notification.subscribe', params);
      _subscribed = true;
      notifyListeners();
    } catch (e) {
      // A subscribe failure during reconnect is benign — the connection
      // banner already signals the link issue, the next reconnect cycle
      // retries. Log to debug for the dev workflow; don't SnackBar.
      debugPrint('NotificationsModel.subscribe failed: $e');
    }
  }

  /// Subscribe to live pushes and, only when the local model is empty, pull
  /// one initial snapshot. This is the cold-start path: it fixes an empty
  /// notification center after app restart without introducing polling or
  /// wiping last-known reconnect state.
  Future<void> subscribeAndBackfillIfEmpty() async {
    await subscribe(sinceTs: lastSeenTs);
    if (_items.isNotEmpty) return;
    await refresh();
  }

  Future<void> unsubscribe() async {
    try {
      await _client.call('notification.unsubscribe');
      _subscribed = false;
      notifyListeners();
    } catch (e) {
      debugPrint('NotificationsModel.unsubscribe failed: $e');
    }
  }

  /// Page-fetch from the backend. Replaces the in-memory map when [since]
  /// is null (initial load / forced refresh); merges when [since] is given
  /// for older-page pagination (`notification.list.since` means timestamp
  /// older than the cursor, not "newer than").
  Future<void> refresh({
    DateTime? since,
    int limit = 100,
    String? source,
    bool includeRead = true,
  }) async {
    final params = <String, dynamic>{
      'limit': limit,
      'includeRead': includeRead,
    };
    if (since != null) {
      params['since'] = since.millisecondsSinceEpoch;
    }
    if (source != null) params['source'] = source;
    try {
      final r =
          await _client.call('notification.list', params)
              as Map<String, dynamic>;
      final raw = r['items'];
      if (raw is! List) return;
      final parsed = raw
          .whereType<Map<String, dynamic>>()
          .map(AppNotification.fromJson)
          .toList(growable: false);
      if (since == null) {
        // Full replace — the user did "refresh" or this is the initial load
        // after connect. Tombstones survive because the backend may still
        // include rows we optimistically deleted (the RPC hasn't landed yet);
        // they get cleaned up when the matching `notification.deleted` push
        // arrives.
        _items.clear();
        for (final n in parsed) {
          if (_deletedIds.contains(n.id)) continue;
          _items[n.id] = n;
        }
      } else {
        // Incremental — merge.
        for (final n in parsed) {
          if (_deletedIds.contains(n.id)) continue;
          _items[n.id] = n;
        }
      }
      _invalidateSort();
      notifyListeners();
    } catch (e) {
      _reportError('Could not load notifications: $e');
    }
  }

  /// Optimistically mark each id as read by this device, then send. On
  /// failure, revert. The eventual `notification.readChanged` push will
  /// confirm and bring other devices' deltas along too.
  Future<void> markRead(Iterable<String> ids) async {
    final me = _deviceId();
    final touched = <String>[];
    final previous = <String, List<String>>{};
    for (final id in ids) {
      final n = _items[id];
      if (n == null) continue;
      if (n.readByDevice(me)) continue;
      previous[id] = List<String>.from(n.readBy);
      _items[id] = n.withReadBy([...n.readBy, me]);
      touched.add(id);
    }
    if (touched.isEmpty) return;
    notifyListeners();
    try {
      await _client.call('notification.markRead', {'ids': touched});
    } catch (e) {
      // Revert.
      for (final id in touched) {
        final n = _items[id];
        if (n != null) {
          _items[id] = n.withReadBy(previous[id]!);
        }
      }
      notifyListeners();
      _reportError('Could not mark as read: $e');
    }
  }

  Future<void> deleteIds(Iterable<String> ids) async {
    final removed = <String, AppNotification>{};
    for (final id in ids) {
      final n = _items.remove(id);
      if (n != null) {
        removed[id] = n;
        _deletedIds.add(id);
      }
    }
    if (removed.isEmpty) return;
    _invalidateSort();
    notifyListeners();
    try {
      await _client.call('notification.delete', {'ids': removed.keys.toList()});
    } catch (e) {
      // Revert.
      for (final entry in removed.entries) {
        _items[entry.key] = entry.value;
        _deletedIds.remove(entry.key);
      }
      _invalidateSort();
      notifyListeners();
      _reportError('Could not delete: $e');
    }
  }

  Future<void> markImportant(String id, bool important) async {
    final n = _items[id];
    if (n == null) return;
    if (n.important == important) return;
    _items[id] = n.withImportant(important);
    notifyListeners();
    try {
      await _client.call('notification.markImportant', {
        'id': id,
        'important': important,
      });
    } catch (e) {
      // Revert.
      final cur = _items[id];
      if (cur != null) {
        _items[id] = cur.withImportant(!important);
        notifyListeners();
      }
      _reportError('Could not change pin state: $e');
    }
  }

  Future<void> reply(String id, String text) async {
    if (text.trim().isEmpty) return;
    final n = _items[id];
    if (n == null || n.reply == null) {
      _reportError('Notification is not replyable');
      return;
    }
    try {
      await _client.call('notification.reply', {'id': id, 'text': text});
    } catch (e) {
      _reportError('Could not send notification reply: $e');
    }
  }

  // ---- Internal ----

  List<AppNotification> _computeSorted() {
    final list = _items.values
        .where((n) => n.supersededBy == null)
        .toList(growable: false);
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  void _invalidateSort() {
    _sortedCache = null;
  }

  /// Hard reset for an intentional backend target switch. A transient
  /// reconnect does not reset; first principle #4 keeps the feed visible.
  void resetLocal() {
    _items.clear();
    _deletedIds.clear();
    _filterSource = null;
    _sortedCache = null;
    _subscribed = false;
    notifyListeners();
  }

  /// Test seam kept for existing tests that need a direct model reset.
  @visibleForTesting
  void resetForTesting() => resetLocal();
}
