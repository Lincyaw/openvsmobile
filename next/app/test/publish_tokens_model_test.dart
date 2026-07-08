import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/state/publish_tokens_model.dart';

class _FakePublishTokenClient extends BackendClient {
  final List<({String method, Map<String, dynamic>? params})> calls = [];
  final List<Map<String, dynamic>> items = [
    {
      'id': 'aaa111bbb222',
      'label': 'ci',
      'sourcePrefix': 'ci',
      'rateLimitPerMin': 60,
      'rateLimitPerHour': 600,
      'createdAt': 1000,
      'lastUsedAt': null,
      'revokedAt': null,
    },
  ];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add((method: method, params: params));
    switch (method) {
      case 'auth.publishTokens.list':
        return {'items': items};
      case 'auth.publishTokens.create':
        final id = 'ccc333ddd444';
        final record = {
          'id': id,
          'label': params!['label'],
          'sourcePrefix': params['sourcePrefix'],
          'rateLimitPerMin': params['rateLimitPerMin'],
          'rateLimitPerHour': params['rateLimitPerHour'],
          'createdAt': 2000,
          'lastUsedAt': null,
          'revokedAt': null,
        };
        items.add(record);
        return {'record': record, 'secret': '$id.${'a' * 64}'};
      case 'auth.publishTokens.relabel':
        for (final item in items) {
          if (item['id'] == params!['id']) item['label'] = params['label'];
        }
        return {'ok': true};
      case 'auth.publishTokens.revoke':
        items.removeWhere((item) => item['id'] == params!['id']);
        return {'revoked': true};
      default:
        throw StateError('unexpected method $method');
    }
  }
}

void main() {
  test(
    'refresh, create, relabel, and revoke keep AppState-side token list',
    () async {
      final client = _FakePublishTokenClient();
      final errors = <String>[];
      final model = PublishTokensModel(client: client, reportError: errors.add);
      addTearDown(model.dispose);

      await model.refresh();
      expect(model.loaded, isTrue);
      expect(model.items.single.label, 'ci');

      final created = await model.create(
        label: 'claude-code',
        sourcePrefix: 'claude-code',
        rateLimitPerMin: 30,
        rateLimitPerHour: 300,
      );
      expect(created.record.label, 'claude-code');
      expect(created.secret, startsWith('ccc333ddd444.'));
      expect(model.items.map((t) => t.label), contains('claude-code'));

      await model.relabel('ccc333ddd444', 'claude-hooks');
      expect(model.items.last.label, 'claude-hooks');

      await model.revoke('ccc333ddd444');
      expect(model.items.map((t) => t.id), isNot(contains('ccc333ddd444')));
      expect(errors, isEmpty);
      expect(
        client.calls.map((c) => c.method),
        containsAllInOrder([
          'auth.publishTokens.list',
          'auth.publishTokens.create',
          'auth.publishTokens.relabel',
          'auth.publishTokens.revoke',
        ]),
      );
    },
  );
}
