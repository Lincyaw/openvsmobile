// Unit tests for the client-side NotificationsModel — push handler shape,
// optimistic markRead behavior, supersede projection, source filter.
//
// We don't mock the WebSocket. BackendClient.call() returns a failed future
// in tests without a server; subscribe/refresh/markRead/etc. all swallow
// the RPC failure (debugPrint or reportError), which is fine — we're
// exercising the *local* state-machine, not the wire layer.

import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/notification.dart';
import 'package:mobilecode/state/notifications_model.dart';

class _RecordingBackendClient extends BackendClient {
  final Map<String, dynamic> responses;
  final List<({String method, Map<String, dynamic>? params})> calls = [];

  _RecordingBackendClient(this.responses);

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add((method: method, params: params));
    return responses[method] ?? <String, dynamic>{'ok': true};
  }
}

AppNotification _make({
  required String id,
  String source = 'demo',
  NotificationLevel level = NotificationLevel.info,
  String title = 'hi',
  String? body,
  int? timestamp,
  String? groupKey,
  String? supersededBy,
  bool important = false,
  List<String> readBy = const [],
}) => AppNotification(
  id: id,
  source: source,
  level: level,
  title: title,
  body: body,
  timestamp: timestamp ?? DateTime.now().millisecondsSinceEpoch,
  groupKey: groupKey,
  supersededBy: supersededBy,
  important: important,
  readBy: readBy,
);

NotificationsModel _model({String deviceId = 'this-device'}) {
  final errors = <String>[];
  return NotificationsModel(
    client: BackendClient(),
    deviceId: () => deviceId,
    reportError: errors.add,
  );
}

void main() {
  group('onShow / sort', () {
    test('adds notifications and sorts by timestamp DESC', () {
      final m = _model();
      m.onShow(_make(id: 'a', timestamp: 100));
      m.onShow(_make(id: 'b', timestamp: 300));
      m.onShow(_make(id: 'c', timestamp: 200));
      expect(m.items.map((n) => n.id).toList(), ['b', 'c', 'a']);
    });

    test('replaces an existing id', () {
      final m = _model();
      m.onShow(_make(id: 'a', title: 'first', timestamp: 100));
      m.onShow(_make(id: 'a', title: 'updated', timestamp: 100));
      expect(m.items, hasLength(1));
      expect(m.items.first.title, 'updated');
    });
  });

  group('onSuperseded', () {
    test('hides the old entry; new entry arrives via onShow', () {
      final m = _model();
      m.onShow(_make(id: 'old', timestamp: 100));
      // Backend sequencing: superseded fires *before* the new show. The old
      // entry drops out of the main feed; the new entry comes in next.
      m.onSuperseded('old', 'new');
      m.onShow(_make(id: 'new', title: 'progress final', timestamp: 200));
      expect(m.items, hasLength(1));
      expect(m.items.first.id, 'new');
    });
  });

  group('onDeleted', () {
    test('removes ids and updates unread count', () {
      final m = _model();
      m.onShow(_make(id: 'a', timestamp: 100));
      m.onShow(_make(id: 'b', timestamp: 200));
      expect(m.unreadCount, 2);
      m.onDeleted(['a']);
      expect(m.items.map((n) => n.id).toList(), ['b']);
      expect(m.unreadCount, 1);
    });
  });

  group('attentionCount', () {
    test('counts only unread important, warning, and error rows', () {
      final m = _model(deviceId: 'me');
      m.onShow(_make(id: 'info', level: NotificationLevel.info));
      m.onShow(_make(id: 'success', level: NotificationLevel.success));
      m.onShow(_make(id: 'important', important: true));
      m.onShow(_make(id: 'warning', level: NotificationLevel.warning));
      m.onShow(_make(id: 'error', level: NotificationLevel.error));
      m.onShow(
        _make(
          id: 'read-warning',
          level: NotificationLevel.warning,
          readBy: const ['me'],
        ),
      );
      m.onShow(
        _make(
          id: 'old-error',
          level: NotificationLevel.error,
          supersededBy: 'new-error',
        ),
      );

      expect(m.unreadCount, 5);
      expect(m.attentionCount, 3);
    });
  });

  group('markRead optimistic', () {
    test('flips local read state immediately', () async {
      final m = _model(deviceId: 'me');
      m.onShow(_make(id: 'a'));
      expect(m.isRead('a'), isFalse);
      expect(m.unreadCount, 1);
      // markRead's RPC will fail (no server) — we don't await it; the
      // optimistic patch happens before the await.
      // ignore: unawaited_futures
      m.markRead(['a']);
      expect(m.isRead('a'), isTrue);
      expect(m.unreadCount, 0);
    });

    test('onReadChanged from another device populates readBy', () {
      final m = _model(deviceId: 'me');
      m.onShow(_make(id: 'a'));
      m.onReadChanged(['a'], 'phone-2', DateTime.now().millisecondsSinceEpoch);
      // Read by phone-2, not by me → still unread for *this* device.
      expect(m.isRead('a'), isFalse);
      expect(m.byId('a')!.readBy, contains('phone-2'));
    });
  });

  group('source filter', () {
    test('filteredItems narrows to a single source', () {
      final m = _model();
      m.onShow(_make(id: '1', source: 'ci', timestamp: 100));
      m.onShow(_make(id: '2', source: 'claude', timestamp: 200));
      m.onShow(_make(id: '3', source: 'ci', timestamp: 300));
      m.setSourceFilter('ci');
      expect(m.filteredItems.map((n) => n.id).toList(), ['3', '1']);
      m.setSourceFilter(null);
      expect(m.filteredItems, hasLength(3));
    });

    test('knownSources is alphabetically sorted and de-duped', () {
      final m = _model();
      m.onShow(_make(id: '1', source: 'zeta'));
      m.onShow(_make(id: '2', source: 'alpha'));
      m.onShow(_make(id: '3', source: 'alpha'));
      expect(m.knownSources, ['alpha', 'zeta']);
    });
  });

  group('subscribeAndBackfillIfEmpty', () {
    test(
      'subscribes and pulls an initial snapshot for an empty model',
      () async {
        final client = _RecordingBackendClient({
          'notification.list': {
            'items': [
              {
                'id': 'from-server',
                'source': 'claude-code',
                'level': 'info',
                'title': 'Claude finished',
                'timestamp': 100,
              },
            ],
          },
        });
        final m = NotificationsModel(
          client: client,
          deviceId: () => 'phone',
          reportError: (_) {},
        );

        await m.subscribeAndBackfillIfEmpty();

        expect(client.calls.map((c) => c.method).toList(), [
          'notification.subscribe',
          'notification.list',
        ]);
        expect(client.calls.first.params, isEmpty);
        expect(m.subscribed, isTrue);
        expect(m.items.map((n) => n.id).toList(), ['from-server']);
      },
    );

    test('keeps cached reconnect state and skips a full snapshot', () async {
      final client = _RecordingBackendClient({
        'notification.list': {
          'items': [
            {
              'id': 'from-server',
              'source': 'claude-code',
              'level': 'info',
              'title': 'Claude finished',
              'timestamp': 200,
            },
          ],
        },
      });
      final m = NotificationsModel(
        client: client,
        deviceId: () => 'phone',
        reportError: (_) {},
      );
      m.onShow(_make(id: 'cached', timestamp: 1000));

      await m.subscribeAndBackfillIfEmpty();

      expect(client.calls.map((c) => c.method).toList(), [
        'notification.subscribe',
      ]);
      expect(client.calls.single.params, {'sinceTs': 1000});
      expect(m.items.map((n) => n.id).toList(), ['cached']);
    });
  });
}
