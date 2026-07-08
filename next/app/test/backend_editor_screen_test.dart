import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/screens/backend_editor_screen.dart';
import 'package:mobilecode/settings_store.dart';

BackendTarget _target({
  BackendTransport transport = BackendTransport.websocket,
  String host = '192.168.1.10',
  int port = 7860,
  String token = 'openvsmobile-dev',
  String? irohTicket,
  String? irohEndpointId,
  String? irohAlpn,
}) {
  return BackendTarget(
    id: 'backend-1',
    name: '',
    host: host,
    port: port,
    token: token,
    transport: transport,
    irohTicket: irohTicket,
    irohEndpointId: irohEndpointId,
    irohAlpn: irohAlpn,
    origin: BackendOrigin.manual,
    addedAt: 0,
  );
}

Future<void> _pumpEditor(
  WidgetTester tester,
  BackendTarget target, {
  Future<void> Function(BackendTarget)? onSave,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: BackendEditorScreen(
        initial: target,
        isFirstRun: true,
        onSave: onSave ?? (_) async {},
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('Iroh editor renders as a transport-specific form', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      _target(
        transport: BackendTransport.iroh,
        host: '',
        port: 0,
        irohTicket: 'endpointticket',
        irohEndpointId: 'endpoint-id',
        irohAlpn: 'openvsmobile.rpc.v1',
      ),
    );

    expect(find.text('New Iroh backend'), findsOneWidget);
    expect(find.text('Iroh ticket'), findsNWidgets(2));
    expect(find.text('Bearer token (not ticket)'), findsOneWidget);
    expect(find.text('Host'), findsNothing);
    expect(find.text('Port'), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is SegmentedButton<BackendTransport>),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('WebSocket editor does not show Iroh connection fields', (
    tester,
  ) async {
    await _pumpEditor(tester, _target());

    expect(find.text('New WebSocket backend'), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Port'), findsOneWidget);
    expect(find.text('Iroh ticket'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact Iroh editor scrolls instead of overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpEditor(
      tester,
      _target(
        transport: BackendTransport.iroh,
        host: '',
        port: 0,
        irohTicket:
            'endpointacnt6jwgvhjirnprqpxpei2ty4vb3kpisdiu5lg4zxdulzvv6dy',
        irohEndpointId:
            '9b3f26c6a9d288b5f183eef22353c72a1da9e890d14eacdccdc745e6b5f0f0c7',
        irohAlpn: 'openvsmobile.rpc.v1',
      ),
    );

    expect(find.text('New Iroh backend'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Iroh token validator rejects a ticket pasted as token', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      _target(
        transport: BackendTransport.iroh,
        host: '',
        port: 0,
        token: '',
        irohTicket: 'endpointticket',
        irohEndpointId: 'endpoint-id',
        irohAlpn: 'openvsmobile.rpc.v1',
      ),
    );

    await tester.enterText(
      find.byType(TextFormField).at(4),
      'endpoint-not-a-token',
    );
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(
      find.text('this is an Iroh ticket; paste the bearer token'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('save failure keeps editor usable and shows an error', (
    tester,
  ) async {
    final save = Completer<void>();
    await _pumpEditor(
      tester,
      _target(host: '', token: ''),
      onSave: (_) => save.future,
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Host'),
      'new.local',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Bearer token'),
      'new-token',
    );
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Saving...'), findsOneWidget);

    save.completeError(Exception('disk full'));
    await tester.pumpAndSettle();

    expect(find.text('New WebSocket backend'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Saving...'), findsNothing);
    expect(find.text('Save failed: Exception: disk full'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
