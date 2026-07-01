import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilecode/services/backend_backup_service.dart';
import 'package:mobilecode/settings_store.dart';

BackendTarget _target({
  String id = 'b1',
  String name = 'home',
  String host = 'h.local',
  int port = 7860,
  String token = 'token',
}) => BackendTarget(
  id: id,
  name: name,
  host: host,
  port: port,
  token: token,
  origin: BackendOrigin.manual,
  addedAt: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('encodes and decodes backend backups with active selection', () {
    final state = AppPersistedState(
      backends: [_target()],
      activeBackendId: 'b1',
    );

    final raw = encodeBackendBackup(
      state,
      exportedAt: DateTime.utc(2026, 6, 28, 12),
    );
    final decodedJson = jsonDecode(raw) as Map<String, dynamic>;
    expect(decodedJson['format'], kBackendBackupFormat);
    expect(decodedJson['schemaVersion'], kBackendBackupSchemaVersion);
    expect(decodedJson['exportedAt'], '2026-06-28T12:00:00.000Z');

    final decoded = decodeBackendBackup(raw);
    expect(decoded.backends.single.host, 'h.local');
    expect(decoded.backends.single.token, 'token');
    expect(decoded.activeBackendId, 'b1');
  });

  test('normalizes missing active backend to the first backend', () {
    final state = AppPersistedState(
      backends: [
        _target(id: 'b1'),
        _target(id: 'b2'),
      ],
      activeBackendId: 'missing',
    );

    final normalized = normalizeBackendBackupState(state);

    expect(normalized.activeBackendId, 'b1');
  });

  test('normalizes empty backup by clearing active backend', () {
    final normalized = normalizeBackendBackupState(
      const AppPersistedState(activeBackendId: 'missing'),
    );

    expect(normalized.backends, isEmpty);
    expect(normalized.activeBackendId, isNull);
  });

  test('rejects unsupported backup format', () {
    expect(
      () => decodeBackendBackup(
        jsonEncode({
          'format': 'other',
          'state': const AppPersistedState().toJson(),
        }),
      ),
      throwsFormatException,
    );
  });

  test(
    'service delegates export and import through platform channel',
    () async {
      const channel = MethodChannel('dev.lincyaw.mobilecode/backend_backup');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'exportText') return true;
            if (call.method == 'importText') {
              return encodeBackendBackup(
                AppPersistedState(backends: [_target()], activeBackendId: 'b1'),
              );
            }
            fail('unexpected method ${call.method}');
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      const service = BackendBackupService();
      expect(
        await service.exportBackends(
          AppPersistedState(backends: [_target()], activeBackendId: 'b1'),
        ),
        isTrue,
      );
      final imported = await service.importBackends();

      expect(imported?.backends.single.host, 'h.local');
      expect(calls.map((call) => call.method), ['exportText', 'importText']);
      final exportArgs = calls.first.arguments as Map<Object?, Object?>;
      expect(exportArgs['fileName'], startsWith('openvsmobile-backends-'));
      expect(exportArgs['content'], contains('"token": "token"'));
    },
  );
}
