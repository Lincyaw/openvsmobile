import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/state/agent_hooks_model.dart';

class _LegacyAgentHookClient extends BackendClient {
  final List<String> calls = [];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? params]) async {
    calls.add(method);
    if (method == 'notification.installAgentHooks') {
      throw BackendRpcException(-32601, 'unknown method');
    }
    throw StateError('unexpected method $method');
  }
}

void main() {
  test('install marks legacy backends as status-unsupported', () async {
    final client = _LegacyAgentHookClient();
    final errors = <String>[];
    final model = AgentHooksModel(client: client, reportError: errors.add);
    addTearDown(model.dispose);

    await expectLater(
      model.install(),
      throwsA(isA<BackendRpcException>().having((e) => e.code, 'code', -32601)),
    );

    expect(client.calls, ['notification.installAgentHooks']);
    expect(model.installing, isFalse);
    expect(model.statusUnsupported, isTrue);
    expect(model.error, isNull);
    expect(errors, isEmpty);
  });
}
