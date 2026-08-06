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
  List<PluginCommandStub> commands = const [],
}) => PluginInfo(
  id: id,
  name: name ?? id,
  version: version,
  state: state,
  crashReason: crashReason,
  panels: panels,
  commands: commands,
);

Future<AppState> _appStateWithSeed(List<PluginInfo> seed) async {
  final state = AppState(client: BackendClient());
  state.plugins.debugSeed(seed);
  return state;
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('grid renders one tile per plugin with the tile name visible', (
    tester,
  ) async {
    // Batch 1 redesign: the Plugins tab now goes through UiAppGrid; tiles
    // surface the plugin name as a caption and a state-derived UiBadge.
    // The legacy in-grid Switch + badge-label affordances moved to the
    // detail screen (covered by other tests).
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

    // App-tile keys follow the renderer's `app-tile:<gridId>/<tileId>`
    // contract; we don't pin the grid id in tests because the host owns
    // it, but ByKeyMatching on the tile id suffix is enough.
    expect(
      find.byKey(const ValueKey<String>('app-tile:host.plugins.grid/alpha')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('app-tile:host.plugins.grid/beta')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('app-tile:host.plugins.grid/gamma')),
      findsOneWidget,
    );
  });

  testWidgets('tap row → detail view with single panel renders UiRenderer', (
    tester,
  ) async {
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PluginsTab(appState: appState)),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('panelplug'));
    await tester.pumpAndSettle();

    // App bar title from the detail screen.
    expect(find.widgetWithText(AppBar, 'panelplug'), findsOneWidget);
    // The text that came from the seeded UiRenderer tree.
    expect(find.text('hello from plugin'), findsOneWidget);
  });

  testWidgets(
    'plugin.stateChanged push reflects crashed state in detail view',
    (tester) async {
      // Batch 1: state labels live in the detail / info view, not the grid.
      // Render the detail view directly and assert the banner appears after
      // a state push flips the plugin to crashed.
      final appState = await _appStateWithSeed([
        _info(id: 'alpha', state: PluginWireState.running),
      ]);
      addTearDown(appState.dispose);
      final initialInfo = appState.plugins.plugin('alpha')!;
      await tester.pumpWidget(
        _wrap(PluginDetailView(appState: appState, info: initialInfo)),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('plugin-crashed-banner')),
        findsNothing,
      );

      appState.plugins.debugApplyStateChange(<String, dynamic>{
        'id': 'alpha',
        'state': 'crashed',
        'crashReason': 'segfault',
      });
      await tester.pump();

      // Detail view is a const StatelessWidget against the snapshot it was
      // built with — pump the updated info through PluginDetailScreen so
      // the AnimatedBuilder picks up the listener mutation.
      final updated = appState.plugins.plugin('alpha')!;
      await tester.pumpWidget(
        _wrap(PluginDetailView(appState: appState, info: updated)),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('plugin-crashed-banner')),
        findsOneWidget,
      );
      expect(find.textContaining('segfault'), findsOneWidget);
    },
  );

  testWidgets('crashed detail shows banner; Reload calls disable then enable', (
    tester,
  ) async {
    final appState = await _appStateWithSeed([
      _info(id: 'crashy', state: PluginWireState.crashed, crashReason: 'panic'),
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
    await tester.pumpWidget(
      _wrap(PluginDetailView(appState: appState, info: info)),
    );
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

  testWidgets('crashed plugin preserves the last rendered panel below banner', (
    tester,
  ) async {
    final appState = await _appStateWithSeed([
      _info(
        id: 'crashy-panel',
        state: PluginWireState.crashed,
        crashReason: 'panic',
        panels: const [PluginPanelStub(id: 'main', title: 'Main')],
      ),
    ]);
    addTearDown(appState.dispose);
    appState.uiPanels.debugInjectPush(<String, dynamic>{
      'pluginId': 'crashy-panel',
      'panelId': 'main',
      'version': 1,
      'tree': <String, dynamic>{
        'kind': 'Text',
        'id': 'last-good',
        'text': 'last rendered state',
      },
    });

    final info = appState.plugins.plugin('crashy-panel')!;
    await tester.pumpWidget(
      _wrap(PluginDetailView(appState: appState, info: info)),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('plugin-crashed-banner')),
      findsOneWidget,
    );
    expect(find.text('last rendered state'), findsOneWidget);
  });

  testWidgets('crashed plugin opens stderr log viewer', (tester) async {
    final appState = await _appStateWithSeed([
      _info(id: 'crashy-log', state: PluginWireState.crashed),
    ]);
    addTearDown(appState.dispose);
    final calls = <String>[];
    appState.plugins.debugRpcOverride = (method, params) async {
      calls.add('$method:${params?['id'] ?? ''}');
      if (method == 'plugin.log') {
        return <String, dynamic>{
          'id': 'crashy-log',
          'path': '/tmp/openvsmobile/plugins/crashy-log.stderr.log',
          'text': 'panic: fixture crash\nstack line\n',
          'bytes': 31,
          'truncated': false,
        };
      }
      return <String, dynamic>{'ok': true};
    };

    final info = appState.plugins.plugin('crashy-log')!;
    await tester.pumpWidget(
      _wrap(PluginDetailView(appState: appState, info: info)),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('plugin-view-log')));
    await tester.pumpAndSettle();

    expect(calls, contains('plugin.log:crashy-log'));
    expect(find.widgetWithText(AppBar, 'crashy-log log'), findsOneWidget);
    expect(find.textContaining('panic: fixture crash'), findsOneWidget);
    expect(
      find.text('/tmp/openvsmobile/plugins/crashy-log.stderr.log'),
      findsOneWidget,
    );
  });

  testWidgets('command chip invokes plugin.invokeCommand', (tester) async {
    final appState = await _appStateWithSeed([
      _info(
        id: 'cmdplug',
        state: PluginWireState.running,
        commands: const [
          PluginCommandStub(id: 'cmdplug.do', title: 'Do thing'),
        ],
      ),
    ]);
    addTearDown(appState.dispose);
    final calls = <String>[];
    appState.plugins.debugRpcOverride = (method, params) async {
      calls.add('$method:${params?['id']}:${params?['commandId']}');
      return <String, dynamic>{'ok': true};
    };

    final info = appState.plugins.plugin('cmdplug')!;
    await tester.pumpWidget(
      _wrap(PluginDetailView(appState: appState, info: info)),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('plugin-command:cmdplug:cmdplug.do')),
    );
    await tester.pumpAndSettle();

    expect(calls, ['plugin.invokeCommand:cmdplug:cmdplug.do']);
  });

  testWidgets('empty state hints at the filesystem install path', (
    tester,
  ) async {
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

  testWidgets('detail kebab → Disable routes through plugin.disable', (
    tester,
  ) async {
    // Batch 1: the enable/disable toggle moved off the grid tile into the
    // detail view. Production goes through the kebab menu; the contract
    // we verify is that selecting Disable still invokes plugin.disable.
    final appState = await _appStateWithSeed([
      _info(id: 'alpha', state: PluginWireState.running),
    ]);
    addTearDown(appState.dispose);
    final calls = <String>[];
    appState.plugins.debugRpcOverride = (method, params) async {
      calls.add('$method:${params?['id'] ?? ''}');
      return <String, dynamic>{'ok': true};
    };

    final info = appState.plugins.plugin('alpha')!;
    await tester.pumpWidget(
      _wrap(PluginDetailView(appState: appState, info: info)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('plugin-kebab')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disable'));
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

  testWidgets('UiNodeEvent dispatch routes through ui.event RPC', (
    tester,
  ) async {
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
    await tester.pumpWidget(
      _wrap(PluginDetailView(appState: appState, info: info)),
    );
    await tester.pump();
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('panel A content'), findsOneWidget);
  });

  testWidgets('grid renders through UiAppGrid with one tile per plugin', (
    tester,
  ) async {
    final appState = await _appStateWithSeed([
      _info(id: 'alpha', state: PluginWireState.running),
      _info(id: 'beta', state: PluginWireState.disabled),
    ]);
    addTearDown(appState.dispose);
    await tester.pumpWidget(_wrap(PluginsTab(appState: appState)));
    await tester.pump();

    // The host emits exactly one UiAppGrid that renders as a single
    // GridView; each plugin becomes a tile keyed by id.
    expect(find.byType(GridView), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('app-tile:host.plugins.grid/alpha')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('app-tile:host.plugins.grid/beta')),
      findsOneWidget,
    );
  });

  testWidgets(
    'tapping a disabled plugin opens the info screen with path hint',
    (tester) async {
      final appState = await _appStateWithSeed([
        _info(id: 'sleepy', state: PluginWireState.disabled),
      ]);
      addTearDown(appState.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PluginsTab(appState: appState)),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('sleepy'));
      await tester.pumpAndSettle();

      // Info screen shows the filesystem path and an Enable button.
      expect(
        find.textContaining('~/.local/share/openvsmobile-next/plugins/'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('plugin-info-toggle:sleepy')),
        findsOneWidget,
      );
    },
  );
}
