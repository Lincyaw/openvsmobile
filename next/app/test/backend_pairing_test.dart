import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecode/services/backend_pairing.dart';
import 'package:mobilecode/settings_store.dart';

String _compressed(String json) {
  final bytes = ZLibEncoder(raw: true).convert(utf8.encode(json));
  return '$kBackendPairingCompressedPrefix${base64Url.encode(bytes).replaceAll('=', '')}';
}

void main() {
  test('parses compact Iroh pairing payload', () {
    final target = BackendPairing.parseTarget(
      jsonEncode({
        'v': 1,
        'k': kBackendPairingKind,
        'n': 'home-server',
        'tr': 'iroh',
        'token': 'tok',
        'iroh': {
          'ticket': 'ticket',
          'endpointId': 'endpoint-id',
          'alpn': 'openvsmobile.rpc.v1',
        },
      }),
      id: 'fixed',
      addedAt: 42,
    );

    expect(target.id, 'fixed');
    expect(target.name, 'home-server');
    expect(target.transport, BackendTransport.iroh);
    expect(target.token, 'tok');
    expect(target.irohTicket, 'ticket');
    expect(target.irohEndpointId, 'endpoint-id');
    expect(target.irohAlpn, 'openvsmobile.rpc.v1');
    expect(target.origin, BackendOrigin.pairingQr);
    expect(target.addedAt, 42);
    expect(target.isComplete, isTrue);
  });

  test('parses compressed WebSocket pairing payload', () {
    final raw = jsonEncode({
      'v': 1,
      'k': kBackendPairingKind,
      'n': 'lan',
      'tr': 'websocket',
      'token': 'tok',
      'ws': {'host': '10.0.0.12', 'port': 39811},
    });

    final target = BackendPairing.parseTarget(
      _compressed(raw),
      id: 'fixed',
      addedAt: 42,
    );

    expect(target.name, 'lan');
    expect(target.transport, BackendTransport.websocket);
    expect(target.host, '10.0.0.12');
    expect(target.port, 39811);
    expect(target.token, 'tok');
    expect(target.origin, BackendOrigin.pairingQr);
    expect(target.isComplete, isTrue);
  });

  test('accepts install.sh success JSON with Iroh info', () {
    final target = BackendPairing.parseTarget(
      jsonEncode({
        'port': 39811,
        'token': 'tok',
        'version': '0.4.7',
        'linger': true,
        'iroh': {
          'ticket': 'ticket',
          'endpointId': 'endpoint-id',
          'alpn': 'openvsmobile.rpc.v1',
        },
      }),
      id: 'fixed',
      addedAt: 42,
    );

    expect(target.transport, BackendTransport.iroh);
    expect(target.name, 'Iroh backend');
    expect(target.irohTicket, 'ticket');
  });

  test('rejects non-MobileCode QR payloads', () {
    expect(
      () => BackendPairing.parseTarget(
        jsonEncode({'k': 'other', 'token': 'tok'}),
        id: 'fixed',
        addedAt: 42,
      ),
      throwsFormatException,
    );
  });
}
