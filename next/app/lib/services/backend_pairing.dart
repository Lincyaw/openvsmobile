import 'dart:convert';
import 'dart:io';

import '../settings_store.dart';

const String kBackendPairingKind = 'ovsm.backend';
const String kBackendPairingCompressedPrefix = 'ovsm1.';
const String kDefaultIrohAlpn = 'openvsmobile.rpc.v1';

class BackendPairing {
  static BackendTarget parseTarget(String raw, {String? id, int? addedAt}) {
    final decoded = _decodePayload(raw.trim());
    final parsed = jsonDecode(decoded);
    if (parsed is! Map<String, dynamic>) {
      throw const FormatException('Backend QR payload must be a JSON object.');
    }

    final kind = _string(parsed, const ['kind', 'k']);
    if (kind != null &&
        kind != kBackendPairingKind &&
        kind != 'openvsmobile.backend') {
      throw const FormatException('QR code is not a MobileCode backend.');
    }

    final token = _requiredString(parsed, const ['token'], 'token');
    final iroh = _map(parsed, const ['iroh']);
    final ticket =
        _string(iroh, const ['ticket']) ??
        _string(parsed, const ['irohTicket', 'ticket']);
    final transportRaw = _string(parsed, const ['transport', 'tr']);
    final isIroh =
        transportRaw == 'iroh' ||
        (transportRaw == null && ticket != null && ticket.isNotEmpty);

    final targetId = id ?? generateUuidV4();
    final now = addedAt ?? DateTime.now().millisecondsSinceEpoch;
    final name = _targetName(parsed, isIroh: isIroh);

    if (isIroh) {
      if (ticket == null || ticket.trim().isEmpty) {
        throw const FormatException('Iroh pairing QR is missing ticket.');
      }
      return BackendTarget(
        id: targetId,
        name: name,
        host: '',
        port: 0,
        token: token,
        transport: BackendTransport.iroh,
        irohTicket: ticket.trim(),
        irohEndpointId:
            _string(iroh, const ['endpointId']) ??
            _string(parsed, const ['irohEndpointId', 'endpointId', 'eid']),
        irohAlpn:
            _string(iroh, const ['alpn']) ??
            _string(parsed, const ['irohAlpn', 'alpn']) ??
            kDefaultIrohAlpn,
        origin: BackendOrigin.pairingQr,
        originRef: 'pairing-qr',
        addedAt: now,
      );
    }

    final ws = _map(parsed, const ['ws', 'websocket']);
    final host = _string(ws, const ['host']) ?? _string(parsed, const ['host']);
    final port = _int(ws, const ['port']) ?? _int(parsed, const ['port']);
    if (host == null || host.trim().isEmpty) {
      throw const FormatException('WebSocket pairing QR is missing host.');
    }
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('WebSocket pairing QR has invalid port.');
    }
    return BackendTarget(
      id: targetId,
      name: name,
      host: host.trim(),
      port: port,
      token: token,
      origin: BackendOrigin.pairingQr,
      originRef: 'pairing-qr',
      addedAt: now,
    );
  }

  static String _decodePayload(String raw) {
    if (raw.isEmpty) {
      throw const FormatException('QR code is empty.');
    }
    if (!raw.startsWith(kBackendPairingCompressedPrefix)) {
      return raw;
    }
    final encoded = raw.substring(kBackendPairingCompressedPrefix.length);
    final padded = encoded.padRight(
      encoded.length + ((4 - encoded.length % 4) % 4),
      '=',
    );
    final bytes = base64Url.decode(padded);
    return utf8.decode(ZLibDecoder(raw: true).convert(bytes));
  }

  static String _targetName(
    Map<String, dynamic> parsed, {
    required bool isIroh,
  }) {
    final explicit = _string(parsed, const ['name', 'n']);
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    if (isIroh) {
      final endpoint = _string(parsed, const ['irohEndpointId', 'endpointId']);
      if (endpoint != null && endpoint.isNotEmpty) {
        return 'Iroh ${_short(endpoint)}';
      }
      return 'Iroh backend';
    }
    final ws = _map(parsed, const ['ws', 'websocket']);
    final host = _string(ws, const ['host']) ?? _string(parsed, const ['host']);
    final port = _int(ws, const ['port']) ?? _int(parsed, const ['port']);
    if (host != null && host.isNotEmpty && port != null) {
      return '$host:$port';
    }
    return 'Backend';
  }

  static String _short(String value) =>
      value.substring(0, value.length < 12 ? value.length : 12);
}

Map<String, dynamic>? _map(Map<String, dynamic>? source, List<String> keys) {
  if (source == null) return null;
  for (final key in keys) {
    final value = source[key];
    if (value is Map<String, dynamic>) return value;
  }
  return null;
}

String? _string(Map<String, dynamic>? source, List<String> keys) {
  if (source == null) return null;
  for (final key in keys) {
    final value = source[key];
    if (value is String) return value.trim();
  }
  return null;
}

String _requiredString(
  Map<String, dynamic> source,
  List<String> keys,
  String label,
) {
  final value = _string(source, keys);
  if (value == null || value.isEmpty) {
    throw FormatException('Backend QR payload is missing $label.');
  }
  return value;
}

int? _int(Map<String, dynamic>? source, List<String> keys) {
  if (source == null) return null;
  for (final key in keys) {
    final value = source[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
  }
  return null;
}
