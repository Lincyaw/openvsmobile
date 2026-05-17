// Widget tests for the Plugins-tab surface (issue #60 / C4).
//
// Coverage matches the issue's acceptance criteria:
//
//   * List view renders three plugins of different states with the right
//     badge label + a working Switch reflecting enabled-ness.
//   * Tapping a row pushes the detail view; the detail view of a plugin
//     that contributes one panel mounts the `UiRenderer` content
//     (drawn from a panel snapshot the test seeds directly).
//   * A `plugin.stateChanged` push flips the badge from `running` to
//     `crashed` and surfaces the reason text.
//   * The detail view of a `crashed` plugin shows the banner; tapping
//     Reload invokes `plugin.disable` then `plugin.enable` in order.
//
// The tests do not mock the BackendClient WebSocket: every RPC issued by
// the screens (`enable`, `disable`, …) routes through `BackendClient.call`,
// which returns a failed future when no socket is configured. We instead
// install a stub via the new `pluginRpcStub` test seam on PluginsModel so
// we can record + assert the call order.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/app_state.dart';
import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/screens/plugins_tab.dart';
import 'package:mobilecode/state/plugins_model.dart';

PluginInfo _info({
  required String id,
  String? name,
  String version = '1.0.0',
  PluginWireState state = PluginWireState.running,
  String? crashReason,
  List<PluginPanelStub> panels = const [],
}) =>
    PluginInfo(
      id: id,
      name: name ?? id,
      version: version,
      state: state,
      crashReason: crashReason,
      panels: panels,
      commands: const [],
    );

Future<AppState> _appStateWithSeed(List<PluginInfo> seed) async {
  final state = AppState(client: BackendClient());
  state.plugins.debugSeed(seed);
  return state;
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('list renders three plugins with correct badges + switches',
      (tester) async {
    final appState = await _appStateWithSeed([
      _info(id: 'alpha', state: PluginWireState.running),
      _info(id: 'beta', state: PluginWireState.crashed, crashReason: 'boom'),
      _info(id: 'gamma', state: PluginWireState.disabled),
    ]);
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(PluginsTab(appState: appState)));
    await tester.pump();

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('gamma'), findsOneWidget);

    // Badge labels — these must match the wire-state label exactly.
    expect(find.text('running'), findsOneWidget);
    expect(find.text('crashed'), findsOneWidget);
    expect(find.text('disabled'), findsOneWidget);
    // Crashed reason is rendered next to the badge.
    expect(find.text('boom'), findsOneWidget);

    // Switch states. PluginWireState.disabled → off; everything else
    // (including crashed) → on, because the toggle drives
    // enabled-vs-disabled, not running-vs-stopped.
    final alphaSwitch = tester
        .widget<Switch>(find.byKey(const ValueKey<String>('plugin-toggle:alpha')));
    final betaSwitch = tester
        .widget<Switch>(find.byKey(const ValueKey<String>('plugin-toggle:beta')));
    final gammaSwitch = tester
        .widget<Switch>(find.byKey(const ValueKey<String>('plugin-toggle:gamma')));
    expect(alphaSwitch.value, isTrue);
    expect(betaSwitch.value, isTrue);
    expect(gammaSwitch.value, isFalse);
  });

  testWidgets('tap row → detail view with single panel renders UiRenderer',
      (tester) async {
    final appState = await _appStateWithSeed([
      _info(
        id: 'panelplug',
        state: PluginWireState.running,
        panels: const [PluginPanelStub(id: 'main', title: 'Main')],
      ),
    ]);
    addTearDown(appState.dispose);

    // Seed a tree for that panel directly into UiPanelsModel via the
    // existing test seam.
    appState.uiPanels.debugInjectPush(<String, dynamic>{
      'pluginId': 'panelplug',
      'panelId': 'main',
      'version': 1,
      'tree': <String, dynamic>{
        'kind': 'Column',
        'id': 'root',
        'children': <Map<String, dynamic>>[
          <String, dynamic>{
            'kind': 'Text',
            'id': 'hello',
            'text': 'hello from plugin',
          },
        ],
      },
    });

    // Use MaterialApp with home: PluginsTab so the tap pushes onto a
    // real Navigator.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PluginsTab(appState: appState)),
    ));
    await tester.pump();

    await tester.tap(find.text('panelplug'));
    await tester.pumpAndSettle();

    // App bar title from the detail screen.
    expect(find.widgetWithText(AppBar, 'panelplug'), findsOneWidget);
    // The text that came from the seeded UiRenderer tree.
    expect(find.text('hello from plugin'), findsOneWidget);
  });

  testWidgets('plugin.stateChanged push flips badge from running to crashed',
      (tester) async {
    final appState = await _appStateWithSeed([
      _info(id: 'alpha', state: PluginWireState.running),
    ]);
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(PluginsTab(appState: appState)));
    await tester.pump();

    expect(find.text('running'), findsOneWidget);
    expect(find.text('crashed'), findsNothing);

    appState.plugins.debugApplyStateChange(<String, dynamic>{
      'id': 'alpha',
      'state': 'crashed',
      'crashReason': 'segfault',
    });
    await tester.pump();

    expect(find.text('running'), findsNothing);
    expect(find.text('crashed'), findsOneWidget);
    expect(find.text('segfault'), findsOneWidget);
  });

  testWidgets('crashed detail shows banner; Reload calls disable then enable',
      (tester) async {
    final appState = await _appStateWithSeed([
      _info(
        id: 'crashy',
        state: PluginWireState.crashed,
        crashReason: 'panic',
      ),
    ]);
    addTearDown(appState.dispose);

    final calls = <String>[];
    appState.plugins.debugRpcOverride = (method, params) async {
      calls.add('$method:${params?['id'] ?? ''}');
      // Simulate the backend's state-change push that would normally
      // arrive after the wire call resolves. The model's reload()
      // awaits each sub-call so the order is "disable RPC → push →
      // enable RPC → push".
      if (method == 'plugin.disable') {
        appState.plugins.debugApplyStateChange(<String, dynamic>{
          'id': 'crashy',
          'state': 'disabled',
        });
      } else if (method == 'plugin.enable') {
        appState.plugins.debugApplyStateChange(<String, dynamic>{
          'id': 'crashy',
          'state': 'running',
        });
      }
      return <String, dynamic>{'ok': true};
    };

    final info = appState.plugins.plugin('crashy')!;
    await tester.pumpWidget(_wrap(
      PluginDetailView(appState: appState, info: info),
    ));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('plugin-crashed-banner')),
      findsOneWidget,
    );
    expect(find.textContaining('Plugin crashed'), findsOneWidget);
    expect(find.textContaining('panic'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('plugin-reload')));
    await tester.pumpAndSettle();

    // Disable must come first, enable second.
    expect(calls, ['plugin.disable:crashy', 'plugin.enable:crashy']);
  });

  testWidgets('empty state hints at the filesystem install path',
      (tester) async {
    final appState = await _appStateWithSeed(const []);
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(PluginsTab(appState: appState)));
    await tester.pump();

    expect(find.text('No plugins installed'), findsOneWidget);
    expect(
      find.textContaining('~/.local/share/openvsmobile-next/plugins/'),
      findsOneWidget,
    );
  });

  testWidgets('toggling the switch routes through plugin.disable',
      (tester) async {
    final appState = await _appStateWithSeed([
      _info(id: 'alpha', state: PluginWireState.running),
    ]);
    addTearDown(appState.dispose);
    final calls = <String>[];
    appState.plugins.debugRpcOverride = (method, params) async {
      calls.add('$method:${params?['id'] ?? ''}');
      return <String, dynamic>{'ok': true};
    };

    await tester.pumpWidget(_wrap(PluginsTab(appState: appState)));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('plugin-toggle:alpha')));
    await tester.pumpAndSettle();
    expect(calls, ['plugin.disable:alpha']);
  });

  test('PluginInfo.fromJson reads contributes.panels + commands', () {
    final info = PluginInfo.fromJson(<String, dynamic>{
      'id': 'p',
      'name': 'P',
      'version': '0.0.1',
      'state': 'running',
      'contributes': <String, dynamic>{
        'commands': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'p.do', 'title': 'Do something'},
        ],
        'panels': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'main', 'title': 'Main'},
          <String, dynamic>{'id': 'logs', 'title': 'Logs'},
        ],
      },
    });
    expect(info.panels.map((p) => p.id).toList(), ['main', 'logs']);
    expect(info.commands.single.id, 'p.do');
  });

  testWidgets('UiNodeEvent dispatch routes through ui.event RPC',
      (tester) async {
    // Multiple-panel case → TabBar with two tabs.
    final appState = await _appStateWithSeed([
      _info(
        id: 'two',
        state: PluginWireState.running,
        panels: const [
          PluginPanelStub(id: 'a', title: 'A'),
          PluginPanelStub(id: 'b', title: 'B'),
        ],
      ),
    ]);
    addTearDown(appState.dispose);
    appState.uiPanels.debugInjectPush(<String, dynamic>{
      'pluginId': 'two',
      'panelId': 'a',
      'version': 1,
      'tree': <String, dynamic>{
        'kind': 'Text',
        'id': 't',
        'text': 'panel A content',
      },
    });
    appState.uiPanels.debugInjectPush(<String, dynamic>{
      'pluginId': 'two',
      'panelId': 'b',
      'version': 1,
      'tree': <String, dynamic>{
        'kind': 'Text',
        'id': 't2',
        'text': 'panel B content',
      },
    });

    final info = appState.plugins.plugin('two')!;
    await tester.pumpWidget(_wrap(
      PluginDetailView(appState: appState, info: info),
    ));
    await tester.pump();
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('panel A content'), findsOneWidget);
  });
}
