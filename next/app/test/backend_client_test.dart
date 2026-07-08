import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/backend_client.dart';

void main() {
  test('heartbeat timeout reconnects instead of wedging connected', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var handshakes = 0;
    final serverSub = server.listen((request) async {
      if (request.uri.path != '/rpc') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
        final id = decoded['id'];
        final method = decoded['method'];
        if (method == 'auth.handshake') {
          handshakes++;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'ok': true,
                'serverVersion': 'test',
                'protocolVersion': '1.0',
                'defaultCwd': '/',
              },
            }),
          );
        }
        // Deliberately ignore system.ping so the client's heartbeat timer
        // has to tear down the socket and schedule a reconnect.
      });
    });
    final client = BackendClient(
      timing: const BackendClientTiming(
        heartbeatInterval: Duration(milliseconds: 20),
        heartbeatGrace: Duration(milliseconds: 20),
        queueBudget: Duration(milliseconds: 100),
        backoff: [Duration(milliseconds: 20)],
      ),
    );
    addTearDown(() async {
      await client.dispose();
      await serverSub.cancel();
      await server.close(force: true);
    });

    client.configure(host: '127.0.0.1', port: server.port, token: 'token');
    await client.start();

    expect(client.state.value, BackendConnectionState.connected);
    expect(client.serverVersion, 'test');
    await _waitUntil(
      () => handshakes >= 2,
      timeout: const Duration(seconds: 1),
    );
    expect(handshakes, greaterThanOrEqualTo(2));
  });

  test('resume probes a stale connected socket and reconnects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var handshakes = 0;
    final serverSub = server.listen((request) async {
      if (request.uri.path != '/rpc') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
        final id = decoded['id'];
        final method = decoded['method'];
        if (method == 'auth.handshake') {
          handshakes++;
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'ok': true,
                'serverVersion': 'test',
                'protocolVersion': '1.0',
                'defaultCwd': '/',
              },
            }),
          );
        }
        // Ignore system.ping. This simulates the app resuming with a socket
        // object that still looks connected locally but no longer has a
        // responsive backend behind it.
      });
    });
    final client = BackendClient(
      timing: const BackendClientTiming(
        heartbeatInterval: Duration(hours: 1),
        heartbeatGrace: Duration(milliseconds: 20),
        queueBudget: Duration(milliseconds: 100),
        backoff: [Duration(milliseconds: 20)],
      ),
    );
    addTearDown(() async {
      await client.dispose();
      await serverSub.cancel();
      await server.close(force: true);
    });

    client.configure(host: '127.0.0.1', port: server.port, token: 'token');
    await client.start();
    expect(client.state.value, BackendConnectionState.connected);

    client.requestReconnectNow();

    await _waitUntil(
      () => handshakes >= 2,
      timeout: const Duration(seconds: 1),
    );
    expect(handshakes, greaterThanOrEqualTo(2));
  });
}

Future<void> _waitUntil(
  bool Function() predicate, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not met within $timeout');
}
