import 'dart:convert';

import 'package:flutter/services.dart';

import '../settings_store.dart';

const String kBackendBackupFormat = 'openvsmobile.backends';
const int kBackendBackupSchemaVersion = 1;

const MethodChannel _backendBackupChannel = MethodChannel(
  'dev.lincyaw.mobilecode/backend_backup',
);

class BackendBackupService {
  const BackendBackupService();

  Future<bool> exportBackends(AppPersistedState state) async {
    final now = DateTime.now().toUtc();
    final saved = await _backendBackupChannel.invokeMethod<bool>('exportText', {
      'fileName': backendBackupFileName(now),
      'mimeType': 'application/json',
      'content': encodeBackendBackup(state, exportedAt: now),
    });
    return saved ?? false;
  }

  Future<AppPersistedState?> importBackends() async {
    final raw = await _backendBackupChannel.invokeMethod<String?>(
      'importText',
      {'mimeType': 'application/json'},
    );
    if (raw == null || raw.isEmpty) return null;
    return decodeBackendBackup(raw);
  }
}

String backendBackupFileName(DateTime exportedAtUtc) {
  final stamp = exportedAtUtc
      .toIso8601String()
      .replaceAll(RegExp(r'[-:]'), '')
      .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
  return 'openvsmobile-backends-$stamp.json';
}

String encodeBackendBackup(AppPersistedState state, {DateTime? exportedAt}) {
  final payload = <String, dynamic>{
    'format': kBackendBackupFormat,
    'schemaVersion': kBackendBackupSchemaVersion,
    'exportedAt': (exportedAt ?? DateTime.now().toUtc()).toIso8601String(),
    'state': normalizeBackendBackupState(state).toJson(),
  };
  return const JsonEncoder.withIndent('  ').convert(payload);
}

AppPersistedState decodeBackendBackup(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Backend backup must be a JSON object.');
  }
  final format = decoded['format'];
  if (format != null && format != kBackendBackupFormat) {
    throw FormatException('Unsupported backend backup format: $format');
  }

  final stateJson = decoded.containsKey('state') ? decoded['state'] : decoded;
  if (stateJson is! Map<String, dynamic>) {
    throw const FormatException('Backend backup is missing a state object.');
  }
  return normalizeBackendBackupState(AppPersistedState.fromJson(stateJson));
}

AppPersistedState normalizeBackendBackupState(AppPersistedState state) {
  final backends = state.backends.toList(growable: false);
  if (backends.isEmpty) {
    return state.copyWith(backends: backends, clearActiveBackendId: true);
  }
  final activeId = state.activeBackendId;
  final hasActive =
      activeId != null && backends.any((backend) => backend.id == activeId);
  return state.copyWith(
    backends: backends,
    activeBackendId: hasActive ? activeId : backends.first.id,
  );
}
