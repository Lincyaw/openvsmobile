import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecode/screens/backend_editor_screen.dart';
import 'package:mobilecode/services/backend_pairing.dart';
import 'package:mobilecode/settings_store.dart';

void main() {
  group('IrohRelaySettings.fromJson', () {
    test('absent or malformed falls back to null (= n0)', () {
      expect(IrohRelaySettings.fromJson(null), isNull);
      expect(IrohRelaySettings.fromJson('custom'), isNull);
      expect(IrohRelaySettings.fromJson({'mode': 'bogus'}), isNull);
      expect(
        IrohRelaySettings.fromJson({'mode': 'custom', 'relays': []}),
        isNull,
      );
    });

    test('parses custom relays with and without QAD ports', () {
      final relay = IrohRelaySettings.fromJson({
        'mode': 'custom',
        'relays': [
          {'url': 'https://relay.corp/', 'quicPort': 7842},
          {'url': 'http://10.1.2.3:3340/', 'authToken': 'tok'},
          {'quicPort': 1},
        ],
      });
      expect(relay!.mode, 'custom');
      expect(relay.relays, const [
        IrohRelayEntry(url: 'https://relay.corp/', quicPort: 7842),
        IrohRelayEntry(url: 'http://10.1.2.3:3340/', authToken: 'tok'),
      ]);
    });

    test('maps disabled and n0/staging', () {
      expect(
        IrohRelaySettings.fromJson({'mode': 'disabled'}),
        IrohRelaySettings.disabled,
      );
      expect(
        IrohRelaySettings.fromJson({'mode': 'staging'}),
        IrohRelaySettings.n0,
      );
    });
  });

  test('pairing QR carries relay settings onto the target', () {
    final target = BackendPairing.parseTarget(
      jsonEncode({
        'v': 1,
        'k': kBackendPairingKind,
        'tr': 'iroh',
        'token': 'tok',
        'iroh': {
          'ticket': 'ticket',
          'relay': {
            'mode': 'custom',
            'relays': [
              {'url': 'https://relay.corp/', 'quicPort': 7842},
            ],
          },
        },
      }),
      id: 'fixed',
      addedAt: 1,
    );
    expect(
      target.irohRelay,
      IrohRelaySettings.custom(const [
        IrohRelayEntry(url: 'https://relay.corp/', quicPort: 7842),
      ]),
    );
  });

  test('BackendTarget round-trips relay settings and clears them', () {
    final target = BackendTarget(
      id: 'a',
      name: 'n',
      host: '',
      port: 0,
      token: 't',
      transport: BackendTransport.iroh,
      irohTicket: 'ticket',
      irohRelay: IrohRelaySettings.custom(const [
        IrohRelayEntry(url: 'http://10.1.2.3:3340/'),
      ]),
      origin: BackendOrigin.manual,
      addedAt: 0,
    );
    final back = BackendTarget.fromJson(
      jsonDecode(jsonEncode(target.toJson())) as Map<String, dynamic>,
    );
    expect(back.irohRelay, target.irohRelay);
    expect(target.copyWith(clearIroh: true).irohRelay, isNull);
  });

  group('editor relay field', () {
    test('empty means n0, "none" means disabled', () {
      expect(parseRelayField(''), IrohRelaySettings.n0);
      expect(parseRelayField(' NONE '), IrohRelaySettings.disabled);
      expect(relayFieldText(null), '');
      expect(relayFieldText(IrohRelaySettings.disabled), 'none');
    });

    test('new https relays get the default QAD port, http none', () {
      expect(
        parseRelayField('https://relay.corp, http://10.1.2.3:3340'),
        IrohRelaySettings.custom(const [
          IrohRelayEntry(
            url: 'https://relay.corp',
            quicPort: kDefaultRelayQuicPort,
          ),
          IrohRelayEntry(url: 'http://10.1.2.3:3340'),
        ]),
      );
    });

    test('keeps the QUIC port and token learned from pairing', () {
      final paired = IrohRelaySettings.custom(const [
        IrohRelayEntry(
          url: 'https://relay.corp/',
          quicPort: 9000,
          authToken: 'tok',
        ),
      ]);
      expect(parseRelayField(relayFieldText(paired), previous: paired), paired);
    });

    test('validator rejects non-http URLs', () {
      expect(validateRelayField(''), isNull);
      expect(validateRelayField('none'), isNull);
      expect(validateRelayField('https://relay.corp'), isNull);
      expect(validateRelayField('relay.corp'), isNotNull);
      expect(validateRelayField('ftp://relay.corp'), isNotNull);
    });
  });
}
