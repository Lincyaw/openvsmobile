// UiPanelsModel tests — focused on the version-drop + tree:null cache
// drop logic. We don't run a real backend; the test seam
// `debugInjectPush` feeds synthetic `ui.tree` payloads into the model.

import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/ui/ui_node.dart';
import 'package:mobilecode/ui/ui_panels_model.dart';

Map<String, dynamic> _push({
  required String pluginId,
  required String panelId,
  required int version,
  Map<String, dynamic>? tree,
}) {
  return <String, dynamic>{
    'pluginId': pluginId,
    'panelId': panelId,
    'version': version,
    'tree': tree,
  };
}

Map<String, dynamic> _textTree(String id, String text) => {
      'kind': 'Text',
      'id': id,
      'text': text,
    };

void main() {
  test('keeps only the latest tree for repeated in-order pushes', () {
    final model = UiPanelsModel(client: BackendClient());
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 1,
      tree: _textTree('t', 'first'),
    ));
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 2,
      tree: _textTree('t', 'second'),
    ));
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 3,
      tree: _textTree('t', 'third'),
    ));
    final snap = model.snapshotFor('p', 'home');
    expect(snap, isNotNull);
    expect(snap!.version, 3);
    expect((snap.tree as UiText).text, 'third');
    model.dispose();
  });

  test('drops out-of-order pushes (version <= lastVersion)', () {
    final model = UiPanelsModel(client: BackendClient());
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 5,
      tree: _textTree('t', 'live'),
    ));
    // Late push from before — must NOT overwrite.
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 3,
      tree: _textTree('t', 'stale'),
    ));
    // Equal version — also dropped (duplicates from a flaky transport).
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 5,
      tree: _textTree('t', 'replay'),
    ));
    final snap = model.snapshotFor('p', 'home')!;
    expect(snap.version, 5);
    expect((snap.tree as UiText).text, 'live');
    model.dispose();
  });

  test('tree:null retires the panel snapshot', () {
    final model = UiPanelsModel(client: BackendClient());
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 1,
      tree: _textTree('t', 'alive'),
    ));
    expect(model.snapshotFor('p', 'home')?.tree, isNotNull);
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 2,
      // tree omitted => null in the wire payload
    ));
    expect(model.snapshotFor('p', 'home')?.tree, isNull);
    expect(model.snapshotFor('p', 'home')?.version, 2);
    model.dispose();
  });

  test('tracks versions independently per panel', () {
    final model = UiPanelsModel(client: BackendClient());
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 7,
      tree: _textTree('t', 'home'),
    ));
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'settings',
      version: 1,
      tree: _textTree('t2', 'settings'),
    ));
    // A version-1 push to settings is NOT dropped just because home is
    // at version 7 — counters are per-panel.
    expect(model.snapshotFor('p', 'home')?.version, 7);
    expect(model.snapshotFor('p', 'settings')?.version, 1);
    model.dispose();
  });

  test('notifies listeners only when a push is accepted', () {
    final model = UiPanelsModel(client: BackendClient());
    var notifications = 0;
    model.addListener(() => notifications++);
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 1,
      tree: _textTree('t', 'a'),
    ));
    expect(notifications, 1);
    // Stale push — dropped silently.
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 1,
      tree: _textTree('t', 'b'),
    ));
    expect(notifications, 1);
    model.debugInjectPush(_push(
      pluginId: 'p',
      panelId: 'home',
      version: 2,
      tree: _textTree('t', 'c'),
    ));
    expect(notifications, 2);
    model.dispose();
  });
}
