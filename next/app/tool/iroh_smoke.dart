import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/settings_store.dart';

const _ticket = String.fromEnvironment('IROH_TICKET');
const _token = String.fromEnvironment('IROH_TOKEN');
const _alpn = String.fromEnvironment(
  'IROH_ALPN',
  defaultValue: 'openvsmobile.rpc.v1',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_ticket.isEmpty || _token.isEmpty) {
    debugPrint('IROH_SMOKE_FAIL missing IROH_TICKET or IROH_TOKEN');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(2);
  }

  final client = BackendClient(
    timing: const BackendClientTiming(
      heartbeatInterval: Duration(seconds: 5),
      heartbeatGrace: Duration(seconds: 2),
      queueBudget: Duration(seconds: 5),
      backoff: [Duration(seconds: 1)],
    ),
  );

  try {
    client.configure(
      host: '',
      port: 0,
      token: _token,
      transport: BackendTransport.iroh,
      irohTicket: _ticket,
      irohAlpn: _alpn,
      deviceId: 'android-smoke',
    );
    await client.start().timeout(const Duration(seconds: 20));
    if (client.state.value != BackendConnectionState.connected) {
      throw StateError(
        'state=${client.state.value.name} error=${client.lastError.value}',
      );
    }
    final ping = await client
        .call('system.ping', const {})
        .timeout(const Duration(seconds: 5));
    debugPrint(
      'IROH_SMOKE_OK ${jsonEncode({'defaultCwd': client.defaultCwd, 'ping': ping})}',
    );
    await client.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  } catch (e, st) {
    debugPrint('IROH_SMOKE_FAIL $e');
    debugPrint(st.toString());
    await client.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(1);
  }
}
