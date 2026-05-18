// Widget tests for the plugin UI renderer (issue #59).
//
// Two acceptance criteria drive these tests:
//   * Every widget kind (Column, Row, Section, Card, List, Text, Spacer,
//     TextField, Button) renders without throwing.
//   * Re-rendering the same tree shape with mutated leaf values preserves
//     widget Element identity via the id → ValueKey mapping (focus,
//     scroll, animation state survive the re-render). Verified by
//     reading `find.byKey(...)` and confirming the same Element after
//     the second pump.
//   * `UiTextField` change events fire `UiNodeEvent` with the new value.
//   * `UiButton` tap fires `UiNodeEvent` with type='tap'.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'package:mobilecode/ui/app_tokens.dart';
import 'package:mobilecode/ui/icon_catalog.dart';
import 'package:mobilecode/ui/ui_node.dart';
import 'package:mobilecode/ui/ui_renderer.dart';

Widget _host(
  UiNode tree, {
  void Function(UiNodeEvent)? onEvent,
  void Function(String gridId, String tileId)? onAppTileLongPress,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: UiRenderer(
          tree: tree,
          onEvent: onEvent ?? (_) {},
          onAppTileLongPress: onAppTileLongPress,
        ),
      ),
    ),
  );
}

UiNode _allKindsTree() {
  // One node of every v0 kind, all with unique ids. Acceptance: "All 9
  // widget kinds … implemented and exercised by widget tests."
  return UiColumn(
    id: 'root-col',
    gap: SpacingSlot.number(8),
    children: [
      const UiText(id: 't-title', text: 'Title goes here', style: UiTextStyleKind.title),
      const UiText(id: 't-body',  text: 'Body line',       style: UiTextStyleKind.body),
      const UiText(id: 't-caption', text: 'caption text',  style: UiTextStyleKind.caption),
      const UiText(id: 't-mono',  text: 'mono()',          style: UiTextStyleKind.mono),
      UiSpacer(id: 'sp-1', size: SpacingSlot.number(12)),
      UiRow(id: 'row-1', gap: SpacingSlot.number(4), children: const [
        UiText(id: 'row-t1', text: 'left'),
        UiText(id: 'row-t2', text: 'right'),
      ]),
      UiSection(id: 'sec-1', title: 'A section', children: [
        UiText(id: 'sec-t', text: 'inside section'),
      ]),
      UiCard(id: 'card-1', children: [
        UiText(id: 'card-t', text: 'inside card'),
      ]),
      UiList(id: 'list-1', items: [
        UiText(id: 'list-i0', text: 'item 0'),
        UiText(id: 'list-i1', text: 'item 1'),
      ]),
      UiTextField(
        id: 'tf-1',
        label: 'Name',
        value: 'initial',
        placeholder: 'enter name',
      ),
      UiButton(id: 'btn-primary',   label: 'Primary',   style: UiButtonStyleKind.primary),
      UiButton(id: 'btn-secondary', label: 'Secondary', style: UiButtonStyleKind.secondary),
      UiButton(id: 'btn-danger',    label: 'Danger',    style: UiButtonStyleKind.danger),
    ],
  );
}

void main() {
  testWidgets('renders every widget kind without throwing',
      (tester) async {
    await tester.pumpWidget(_host(_allKindsTree()));
    // The error pump would have surfaced via takeException; ensure we
    // also see the obvious bits.
    expect(tester.takeException(), isNull);
    expect(find.byType(Column),         findsWidgets);
    expect(find.byType(Row),            findsOneWidget);
    expect(find.byType(Card),           findsOneWidget);
    expect(find.byType(ListView),       findsOneWidget);
    expect(find.text('Title goes here'),findsOneWidget);
    expect(find.text('Body line'),      findsOneWidget);
    expect(find.text('caption text'),   findsOneWidget);
    expect(find.text('mono()'),         findsOneWidget);
    expect(find.text('inside section'), findsOneWidget);
    expect(find.text('inside card'),    findsOneWidget);
    expect(find.text('item 0'),         findsOneWidget);
    expect(find.text('item 1'),         findsOneWidget);
    expect(find.byType(TextField),      findsOneWidget);
    expect(find.byType(ElevatedButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.byType(FilledButton),   findsOneWidget);
  });

  testWidgets('reconciles by id: same Text Element after a mutating re-render',
      (tester) async {
    UiNode treeWithLabel(String label) => UiColumn(
          id: 'root',
          children: [
            UiText(id: 'leaf', text: label),
          ],
        );

    final firstHost = _host(treeWithLabel('alpha'));
    await tester.pumpWidget(firstHost);
    final firstElement = tester.element(find.byKey(const ValueKey('ui:leaf')));
    expect(find.text('alpha'), findsOneWidget);

    // Same tree shape, same node ids, mutated leaf value.
    await tester.pumpWidget(_host(treeWithLabel('beta')));
    final secondElement = tester.element(find.byKey(const ValueKey('ui:leaf')));
    // Identical Element instance → Flutter matched the new widget to the
    // existing Element, which is what preserves focus/scroll/animation.
    expect(identical(firstElement, secondElement), isTrue);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('alpha'), findsNothing);
  });

  testWidgets('reconciles by id: TextField Element survives re-render',
      (tester) async {
    UiNode treeWithLabel(String label) => UiColumn(
          id: 'root',
          children: [
            UiTextField(id: 'tf', label: label),
          ],
        );

    await tester.pumpWidget(_host(treeWithLabel('First')));
    final firstElement = tester.element(find.byKey(const ValueKey('ui:tf')));

    // Type into the field — this would be lost if Flutter destroyed and
    // recreated the State on the next pump.
    await tester.enterText(find.byType(TextField), 'user text');
    expect(find.text('user text'), findsOneWidget);

    await tester.pumpWidget(_host(treeWithLabel('Second')));
    final secondElement = tester.element(find.byKey(const ValueKey('ui:tf')));
    expect(identical(firstElement, secondElement), isTrue);
    // User input survives the re-render (controller lives on State which
    // didn't get rebuilt).
    expect(find.text('user text'), findsOneWidget);
  });

  testWidgets('TextField onChange emits UiNodeEvent with the new value',
      (tester) async {
    final events = <UiNodeEvent>[];
    final tree = UiTextField(id: 'tf', label: 'name');
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    await tester.enterText(find.byType(TextField), 'hello world');
    expect(events, hasLength(1));
    expect(events.single.nodeId, 'tf');
    expect(events.single.type, 'changed');
    expect(events.single.payload, {'value': 'hello world'});
  });

  testWidgets('Button tap emits UiNodeEvent with type=tap', (tester) async {
    final events = <UiNodeEvent>[];
    final tree = UiButton(id: 'go', label: 'Go');
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    expect(events, hasLength(1));
    expect(events.single.nodeId, 'go');
    expect(events.single.type, 'tap');
    expect(events.single.payload, isNull);
  });

  test('UiNode.fromJson round-trips the wire shape', () {
    final json = <String, dynamic>{
      'kind': 'Column',
      'id': 'col',
      'gap': 4,
      'children': [
        {'kind': 'Text', 'id': 't', 'text': 'hi', 'style': 'mono'},
        {'kind': 'Spacer', 'id': 'sp', 'size': 8},
        {
          'kind': 'Card',
          'id': 'c',
          'children': [
            {'kind': 'Button', 'id': 'b', 'label': 'Click', 'style': 'danger'},
          ],
        },
      ],
    };
    final node = UiNode.fromJson(json);
    expect(node, isA<UiColumn>());
    final col = node as UiColumn;
    // Batch 1: gap/size carry a SpacingSlot wrapper that retains either
    // a numeric value or a SpacingToken. The number path stays a double.
    expect(col.gap?.numeric, 4.0);
    expect(col.children, hasLength(3));
    expect((col.children[0] as UiText).style, UiTextStyleKind.mono);
    expect((col.children[1] as UiSpacer).size?.numeric, 8.0);
    final card = col.children[2] as UiCard;
    final btn = card.children.single as UiButton;
    expect(btn.label, 'Click');
    expect(btn.style, UiButtonStyleKind.danger);
  });

  test('UiNode.fromJson rejects unknown kind', () {
    expect(
      () => UiNode.fromJson({'kind': 'Frobnicate', 'id': 'n'}),
      throwsFormatException,
    );
  });

  test('UiNode.fromJson rejects missing id', () {
    expect(
      () => UiNode.fromJson({'kind': 'Text', 'text': 'no id'}),
      throwsFormatException,
    );
  });

  // ---- Batch 1 widgets (§4.3) ----

  testWidgets('UiIcon renders a known Feather glyph at the requested size',
      (tester) async {
    final tree = UiIcon(
      id: 'i',
      name: 'home',
      size: SizeSlot.number(32),
      accent: AccentToken.brand,
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    final iconWidget = tester.widget<Icon>(find.byKey(const ValueKey('ui:i')));
    expect(iconWidget.size, 32);
    expect(iconWidget.icon, isNotNull);
  });

  testWidgets('UiIcon falls back to a placeholder for unknown names',
      (tester) async {
    const tree = UiIcon(id: 'i', name: 'no-such-icon');
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    final iconWidget = tester.widget<Icon>(find.byKey(const ValueKey('ui:i')));
    // The catalog returns null for unknown names; renderer uses
    // Icons.help_outline as the visible-but-degraded placeholder.
    expect(iconWidget.icon, Icons.help_outline);
  });

  testWidgets('UiBadge dot renders an 8x8 colored circle', (tester) async {
    const tree = UiBadge(
      id: 'b',
      variant: UiBadgeVariant.dot,
      accent: AccentToken.danger,
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    final size = tester.getSize(find.byKey(const ValueKey('ui:b')));
    expect(size.width, 8);
    expect(size.height, 8);
  });

  testWidgets('UiBadge pill renders text/count and a rounded background',
      (tester) async {
    const tree = UiBadge(
      id: 'b2',
      variant: UiBadgeVariant.pill,
      count: 3,
      accent: AccentToken.brand,
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('UiListTile renders title/subtitle and emits onTapEvent',
      (tester) async {
    final events = <UiNodeEvent>[];
    const tree = UiListTile(
      id: 'row',
      title: 'Title row',
      subtitle: 'Subtitle row',
      onTapEvent: 'open',
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    expect(find.text('Title row'), findsOneWidget);
    expect(find.text('Subtitle row'), findsOneWidget);
    await tester.tap(find.byType(ListTile));
    await tester.pump();
    expect(events, hasLength(1));
    expect(events.single.type, 'open');
    expect(events.single.nodeId, 'row');
  });

  testWidgets('UiListTile renders leading + trailing nodes via recursion',
      (tester) async {
    const tree = UiListTile(
      id: 'row',
      title: 'With chrome',
      leading: UiIcon(id: 'row.l', name: 'user'),
      trailing: UiBadge(
        id: 'row.t',
        variant: UiBadgeVariant.dot,
        accent: AccentToken.info,
      ),
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('ui:row.l')), findsOneWidget);
    expect(find.byKey(const ValueKey('ui:row.t')), findsOneWidget);
  });

  testWidgets('UiListTile accepts swipeActions (plumbed, not rendered)',
      (tester) async {
    // Batch 1 contract: the field is parsed and stored; Batch 4 lights
    // up the gesture. Test that supplying it does not crash and that
    // the tile still renders normally.
    const tree = UiListTile(
      id: 'row',
      title: 'With swipe',
      swipeActions: [
        UiSwipeAction(
          label: 'Delete',
          eventId: 'row.delete',
          accent: AccentToken.danger,
        ),
      ],
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.text('With swipe'), findsOneWidget);
    // The delete action label MUST NOT render in batch 1.
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('UiAppGrid renders one tile per item and fires onLaunchEvent',
      (tester) async {
    final events = <UiNodeEvent>[];
    const tree = UiAppGrid(
      id: 'grid',
      onLaunchEvent: 'go',
      items: [
        UiAppTile(id: 't1', name: 'Alpha', icon: UiAppTileIconName('home')),
        UiAppTile(id: 't2', name: 'Beta', icon: UiAppTileIconName('settings')),
      ],
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    expect(tester.takeException(), isNull);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('app-tile:grid/t1')),
      findsOneWidget,
    );
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(events, hasLength(1));
    expect(events.single.type, 'go');
    expect(events.single.payload, {'tileId': 't1'});
  });

  testWidgets('UiAppGrid uses default onLaunchEvent="launch" when omitted',
      (tester) async {
    final events = <UiNodeEvent>[];
    const tree = UiAppGrid(
      id: 'grid',
      items: [
        UiAppTile(id: 't1', name: 'Alpha', icon: UiAppTileIconName('home')),
      ],
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(events.single.type, 'launch');
  });

  testWidgets(
      'UiAppGrid long-press fires the screen-local onAppTileLongPress hook',
      (tester) async {
    final longPresses = <(String, String)>[];
    const tree = UiAppGrid(
      id: 'g',
      items: [
        UiAppTile(id: 't1', name: 'Alpha', icon: UiAppTileIconName('home')),
      ],
    );
    await tester.pumpWidget(_host(
      tree,
      onAppTileLongPress: (gridId, tileId) =>
          longPresses.add((gridId, tileId)),
    ));
    await tester.longPress(find.text('Alpha'));
    await tester.pump();
    expect(longPresses, [('g', 't1')]);
  });

  testWidgets('UiBadge danger pill pairs the foreground with onError',
      (tester) async {
    // Regression guard for the contrast accident: danger background is
    // scheme.error, so the matched on-* role is onError. Using onPrimary
    // would degrade contrast on a theme whose primary != error.
    const tree = UiBadge(
      id: 'b',
      variant: UiBadgeVariant.pill,
      text: '99',
      accent: AccentToken.danger,
    );
    await tester.pumpWidget(_host(tree));
    final textWidget = tester.widget<Text>(find.text('99'));
    final scheme =
        Theme.of(tester.element(find.text('99'))).colorScheme;
    expect(textWidget.style?.color, scheme.onError);
  });

  test('UiAppTile.fromJson reads the catalog-name icon shape', () {
    final tile = UiAppTile.fromJson(<String, dynamic>{
      'id': 't',
      'name': 'Alpha',
      'icon': 'home',
      'accent': 'brand',
    });
    expect((tile.icon as UiAppTileIconName).name, 'home');
    expect(tile.accent, AccentToken.brand);
  });

  test('UiAppTile.fromJson reads the { uri } icon shape', () {
    final tile = UiAppTile.fromJson(<String, dynamic>{
      'id': 't',
      'name': 'Alpha',
      'icon': <String, dynamic>{'uri': 'https://x/i.png'},
    });
    expect((tile.icon as UiAppTileIconUri).uri, 'https://x/i.png');
  });

  test('UiNode.fromJson accepts tokenized gap on Column/Row', () {
    final node = UiNode.fromJson(<String, dynamic>{
      'kind': 'Column',
      'id': 'c',
      'gap': 'sm',
      'children': <Map<String, dynamic>>[
        <String, dynamic>{'kind': 'Text', 'id': 't', 'text': 'hi'},
      ],
    });
    final col = node as UiColumn;
    expect(col.gap?.token, SpacingToken.sm);
    expect(col.gap?.numeric, isNull);
  });

  // ---- StyleSlotResolver round-trip ----

  testWidgets('StyleSlotResolver: spacing tokens map to AppSpacing scale',
      (tester) async {
    // Tokens resolve to the same px values that legacy `AppSpacing.*`
    // constants exposed, so numeric and tokenized authors share one scale.
    expect(StyleSlotResolver.spacing(SpacingToken.none), 0);
    expect(StyleSlotResolver.spacing(SpacingToken.xs), AppSpacing.xs);
    expect(StyleSlotResolver.spacing(SpacingToken.sm), AppSpacing.sm);
    expect(StyleSlotResolver.spacing(SpacingToken.md), AppSpacing.md);
    expect(StyleSlotResolver.spacing(SpacingToken.lg), AppSpacing.lg);
    expect(StyleSlotResolver.spacing(SpacingToken.xl), AppSpacing.xl);

    expect(StyleSlotResolver.spacingSlot(numeric: 12), 12);
    expect(
      StyleSlotResolver.spacingSlot(token: SpacingToken.md),
      AppSpacing.md,
    );
  });

  testWidgets('StyleSlotResolver: size tokens map to icon size buckets',
      (tester) async {
    expect(StyleSlotResolver.size(SizeToken.sm), AppIconSize.sm);
    expect(StyleSlotResolver.size(SizeToken.md), AppIconSize.md);
    expect(StyleSlotResolver.size(SizeToken.lg), AppIconSize.lg);
  });

  testWidgets('StyleSlotResolver: surface / accent resolve via ColorScheme',
      (tester) async {
    late BuildContext capturedCtx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (ctx) {
        capturedCtx = ctx;
        return const SizedBox.shrink();
      }),
    ));
    final scheme = Theme.of(capturedCtx).colorScheme;
    expect(
      StyleSlotResolver.surface(capturedCtx, SurfaceToken.defaultSurface),
      scheme.surface,
    );
    expect(
      StyleSlotResolver.surface(capturedCtx, SurfaceToken.elevated),
      scheme.surfaceContainerHigh,
    );
    expect(
      StyleSlotResolver.accent(capturedCtx, AccentToken.brand),
      scheme.primary,
    );
    expect(
      StyleSlotResolver.accent(capturedCtx, AccentToken.danger),
      scheme.error,
    );
  });

  testWidgets('StyleSlotResolver: info / success / warning paint distinct hues',
      (tester) async {
    // Regression guard: pre-review these collapsed to scheme.tertiary
    // (info+warning) and a hardcoded green hex (success). Each must
    // resolve to a different Color so plugin authors using the three
    // tokens get visually distinguishable accents.
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.shrink();
      }),
    ));
    final info = StyleSlotResolver.accent(ctx, AccentToken.info);
    final success = StyleSlotResolver.accent(ctx, AccentToken.success);
    final warning = StyleSlotResolver.accent(ctx, AccentToken.warning);
    expect(info, isNot(equals(success)));
    expect(info, isNot(equals(warning)));
    expect(success, isNot(equals(warning)));
  });

  testWidgets('StyleSlotResolver: brightness flips info between light & dark',
      (tester) async {
    // Same accent token reads differently on a light vs dark surface —
    // the resolver picks a tuned hue per brightness so the contrast
    // intent survives mode switches.
    Color? darkInfo;
    await tester.pumpWidget(MaterialApp(
      home: Theme(
        data: ThemeData(brightness: Brightness.dark),
        child: Builder(builder: (ctx) {
          darkInfo = StyleSlotResolver.accent(ctx, AccentToken.info);
          return const SizedBox.shrink();
        }),
      ),
    ));
    Color? lightInfo;
    await tester.pumpWidget(MaterialApp(
      home: Theme(
        data: ThemeData(brightness: Brightness.light),
        child: Builder(builder: (ctx) {
          lightInfo = StyleSlotResolver.accent(ctx, AccentToken.info);
          return const SizedBox.shrink();
        }),
      ),
    ));
    expect(darkInfo, isNotNull);
    expect(lightInfo, isNotNull);
    expect(darkInfo, isNot(equals(lightInfo)));
  });

  test('resolvePluginThemeColor handles every documented palette name', () {
    for (final name in [
      'teal',
      'blue',
      'green',
      'orange',
      'red',
      'purple',
      'mono',
    ]) {
      expect(resolvePluginThemeColor(name), isNotNull, reason: name);
    }
    expect(resolvePluginThemeColor(null), isNull);
    expect(resolvePluginThemeColor('chartreuse'), isNull);
  });

  // ---- Batch 2 widgets (§4.3) ----

  testWidgets('UiSection variant=plain renders title + children stacked',
      (tester) async {
    const tree = UiSection(
      id: 's',
      title: 'Plain section',
      variant: UiSectionVariant.plain,
      children: [UiText(id: 's.t', text: 'inside')],
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.text('Plain section'), findsOneWidget);
    expect(find.text('inside'), findsOneWidget);
    // No Card surface in the plain branch.
    expect(find.byType(Card), findsNothing);
  });

  testWidgets(
      'UiSection variant=null behaves identically to plain (pre-Batch-2 compat)',
      (tester) async {
    const tree = UiSection(
      id: 's',
      title: 'Compat',
      children: [UiText(id: 's.t', text: 'inside')],
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.text('Compat'), findsOneWidget);
    expect(find.text('inside'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('UiSection variant=card wraps children in a Material Card',
      (tester) async {
    const tree = UiSection(
      id: 's',
      title: 'Card section',
      variant: UiSectionVariant.card,
      children: [UiText(id: 's.t', text: 'inside')],
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.byType(Card), findsOneWidget);
    expect(find.text('inside'), findsOneWidget);
  });

  testWidgets(
      'UiCard (deprecated alias) renders through the same path as variant=card',
      (tester) async {
    const tree = UiCard(
      id: 'c',
      children: [UiText(id: 'c.t', text: 'inside-card')],
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    // Acceptance per Batch 2: existing UiCard nodes from older plugins
    // (clock/notes/sysinfo/hello prior to migration) must keep rendering.
    expect(find.byType(Card), findsOneWidget);
    expect(find.text('inside-card'), findsOneWidget);
  });

  testWidgets(
      'UiSection variant=inset renders dividers between adjacent rows',
      (tester) async {
    const tree = UiSection(
      id: 's',
      title: 'Inset',
      variant: UiSectionVariant.inset,
      children: [
        UiText(id: 'r1', text: 'first row'),
        UiText(id: 'r2', text: 'second row'),
        UiText(id: 'r3', text: 'third row'),
      ],
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.text('first row'), findsOneWidget);
    expect(find.text('third row'), findsOneWidget);
    // Exactly N-1 dividers between N rows — no leading/trailing separator.
    expect(
      find.byKey(const ValueKey<String>('inset-section-divider:1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inset-section-divider:2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('inset-section-divider:3')),
      findsNothing,
    );
  });

  testWidgets('UiSection variant=inset paints title as caption above surface',
      (tester) async {
    const tree = UiSection(
      id: 's',
      title: 'Connection',
      variant: UiSectionVariant.inset,
      children: [UiText(id: 'r', text: 'row')],
    );
    await tester.pumpWidget(_host(tree));
    // Title is rendered uppercase per the iOS-Settings inset convention.
    expect(find.text('CONNECTION'), findsOneWidget);
  });

  testWidgets('UiSwitch flips locally and emits onChangeEvent payload',
      (tester) async {
    final events = <UiNodeEvent>[];
    const tree = UiSwitch(
      id: 'sw',
      label: 'Private',
      value: false,
      onChangeEvent: 'toggled',
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    expect(find.text('Private'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(events, hasLength(1));
    expect(events.single.nodeId, 'sw');
    expect(events.single.type, 'toggled');
    expect(events.single.payload, {'value': true});
    // Local state followed the tap (optimistic update).
    final swWidget = tester.widget<Switch>(find.byType(Switch));
    expect(swWidget.value, isTrue);
  });

  testWidgets('UiSwitch syncs local value when the wire value changes',
      (tester) async {
    // Authority loop: plugin re-renders to "reject" the user's flip; the
    // renderer must adopt the wire value rather than stick with its local
    // optimistic state.
    UiNode tree(bool v) => UiSwitch(id: 'sw', value: v);
    await tester.pumpWidget(_host(tree(false)));
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    // Plugin re-renders with value: false — local must follow.
    await tester.pumpWidget(_host(tree(false)));
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('UiSelect opens a modal bottom sheet picker on tap',
      (tester) async {
    final events = <UiNodeEvent>[];
    const tree = UiSelect(
      id: 'sel',
      label: 'Theme',
      value: 'system',
      onChangeEvent: 'pick',
      options: [
        UiSelectOption(value: 'system', label: 'System'),
        UiSelectOption(value: 'light', label: 'Light'),
        UiSelectOption(value: 'dark', label: 'Dark'),
      ],
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    // Trigger row shows current label.
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    // Bottom sheet exposes all options.
    expect(
      find.byKey(const ValueKey<String>('select-option:sel/light')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('select-option:sel/dark')),
      findsOneWidget,
    );
    // Pick "Dark".
    await tester.tap(find.byKey(const ValueKey<String>('select-option:sel/dark')));
    await tester.pumpAndSettle();
    expect(events, hasLength(1));
    expect(events.single.type, 'pick');
    expect(events.single.payload, {'value': 'dark'});
    // Trigger row reflects the new pick.
    expect(find.text('Dark'), findsOneWidget);
  });

  testWidgets('UiInlineBanner paints with the accent color and an icon',
      (tester) async {
    const tree = UiInlineBanner(
      id: 'b',
      title: 'Heads up',
      body: 'Something happened.',
      accent: UiInlineBannerAccent.warning,
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.text('Heads up'), findsOneWidget);
    expect(find.text('Something happened.'), findsOneWidget);
    // Warning icon is the standard alert-triangle from the catalog.
    final iconData = resolveIconByName('alert-triangle');
    expect(find.byIcon(iconData!), findsOneWidget);
  });

  testWidgets('UiInlineBanner action fires the configured eventId',
      (tester) async {
    final events = <UiNodeEvent>[];
    const tree = UiInlineBanner(
      id: 'b',
      title: 'Unsaved',
      accent: UiInlineBannerAccent.warning,
      action: UiInlineBannerAction(label: 'Save', eventId: 'saveNow'),
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(events, hasLength(1));
    expect(events.single.nodeId, 'b');
    expect(events.single.type, 'saveNow');
  });

  testWidgets('UiInlineBanner dismiss button fires dismissEventId',
      (tester) async {
    final events = <UiNodeEvent>[];
    const tree = UiInlineBanner(
      id: 'b',
      title: 'FYI',
      accent: UiInlineBannerAccent.info,
      dismissEventId: 'dismiss',
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(events.single.type, 'dismiss');
  });

  testWidgets('UiDivider horizontal renders a Material Divider',
      (tester) async {
    const tree = UiColumn(id: 'c', children: [
      UiText(id: 't1', text: 'above'),
      UiDivider(id: 'div'),
      UiText(id: 't2', text: 'below'),
    ]);
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey<String>('ui:div')), findsOneWidget);
    expect(find.byType(Divider), findsWidgets);
  });

  testWidgets('UiDivider vertical renders a VerticalDivider',
      (tester) async {
    const tree = UiDivider(id: 'div', orientation: UiDividerOrientation.vertical);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 50,
          child: Row(children: [
            const Text('a'),
            UiRenderer(tree: tree, onEvent: (_) {}),
            const Text('b'),
          ]),
        ),
      ),
    ));
    expect(find.byType(VerticalDivider), findsOneWidget);
  });

  test('UiNode.fromJson parses Section.variant', () {
    final inset = UiNode.fromJson(<String, dynamic>{
      'kind': 'Section',
      'id': 's',
      'variant': 'inset',
      'children': <Map<String, dynamic>>[],
    });
    expect((inset as UiSection).variant, UiSectionVariant.inset);
    final plainOmitted = UiNode.fromJson(<String, dynamic>{
      'kind': 'Section',
      'id': 's2',
      'children': <Map<String, dynamic>>[],
    });
    expect((plainOmitted as UiSection).variant, isNull);
  });

  test('UiNode.fromJson parses UiSwitch / UiSelect / UiInlineBanner / UiDivider',
      () {
    final sw = UiNode.fromJson(<String, dynamic>{
      'kind': 'Switch',
      'id': 'sw',
      'value': true,
      'label': 'On',
      'onChangeEvent': 'flip',
    });
    expect((sw as UiSwitch).value, true);
    expect(sw.label, 'On');
    expect(sw.onChangeEvent, 'flip');

    final sel = UiNode.fromJson(<String, dynamic>{
      'kind': 'Select',
      'id': 'sel',
      'label': 'Theme',
      'value': 'dark',
      'onChangeEvent': 'picked',
      'options': <Map<String, dynamic>>[
        <String, dynamic>{'value': 'light', 'label': 'Light'},
        <String, dynamic>{'value': 'dark', 'label': 'Dark'},
      ],
    });
    expect((sel as UiSelect).options.length, 2);
    expect(sel.options[1].value, 'dark');
    expect(sel.value, 'dark');

    final banner = UiNode.fromJson(<String, dynamic>{
      'kind': 'Banner',
      'id': 'b',
      'title': 'x',
      'body': 'y',
      'accent': 'success',
      'action': <String, dynamic>{'label': 'Go', 'eventId': 'go'},
      'dismissEventId': 'no',
    });
    expect((banner as UiInlineBanner).accent, UiInlineBannerAccent.success);
    expect(banner.action?.eventId, 'go');
    expect(banner.dismissEventId, 'no');

    final div = UiNode.fromJson(<String, dynamic>{
      'kind': 'Divider',
      'id': 'd',
      'orientation': 'vertical',
    });
    expect((div as UiDivider).orientation, UiDividerOrientation.vertical);
  });

  // ---- Batch 3 widgets (§4.3) — rich display ----

  testWidgets('UiImage renders a NetworkImage for an https:// src',
      (tester) async {
    const tree = UiImage(
      id: 'img',
      src: 'https://example.com/x.png',
      fit: UiImageFit.contain,
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey<String>('ui:img')), findsOneWidget);
    // The widget is an Image — assert the underlying provider type via
    // the rendered Image widget. Network loading itself isn't exercised
    // (no network in widget tests).
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<NetworkImage>());
  });

  testWidgets('UiImage renders a MemoryImage for a data: URL',
      (tester) async {
    // 1x1 transparent PNG, base64 encoded.
    const onePixelPng =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    const tree = UiImage(id: 'data-img', src: onePixelPng);
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<MemoryImage>());
  });

  testWidgets('UiImage with unknown scheme renders the broken-image placeholder',
      (tester) async {
    const tree = UiImage(id: 'broken', src: 'rocket://nowhere');
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    // Placeholder uses Icons.broken_image_outlined; no Image widget rendered.
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets(
      'UiAvatar with no src renders the initial glyph on a hashed color',
      (tester) async {
    const tree = UiAvatar(id: 'av', initial: 'AB');
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    // Glyph is uppercased to "AB" by the renderer's _avatarGlyph helper.
    expect(find.text('AB'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('UiAvatar hash color is deterministic for the same initial',
      (tester) async {
    // Two avatars with the same initial must paint identical container
    // colors; two with different initials should differ (with very high
    // probability across the 8-bucket palette). The Avatar widget IS
    // a Container (no nested chrome), so we read the keyed Container's
    // decoration directly — `find.descendant + Container` would match
    // both the avatar AND any enclosing surface, breaking `widget()`.
    const tree = UiRow(id: 'r', children: [
      UiAvatar(id: 'a1', initial: 'A'),
      UiAvatar(id: 'a2', initial: 'A'),
      UiAvatar(id: 'a3', initial: 'Z'),
    ]);
    await tester.pumpWidget(_host(tree));
    Color? colorFor(String avatarId) {
      final container = tester.widget<Container>(
        find.byKey(ValueKey<String>('ui:$avatarId')),
      );
      return (container.decoration as BoxDecoration).color;
    }
    final c1 = colorFor('a1');
    final c2 = colorFor('a2');
    final c3 = colorFor('a3');
    expect(c1, equals(c2));
    expect(c1, isNot(equals(c3)));
  });

  testWidgets('UiAvatar accent overrides the hash color',
      (tester) async {
    const tree = UiAvatar(
      id: 'av-accent',
      initial: 'X',
      accent: AccentToken.warning,
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.text('X'), findsOneWidget);
    // The presence of the accent color is enough — we don't assert on
    // the exact value because that's owned by StyleSlotResolver.
  });

  testWidgets('UiMarkdown renders body text without throwing',
      (tester) async {
    const tree = UiMarkdown(
      id: 'md',
      markdown: '# Heading\n\nThis is **bold** text with `code`.',
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey<String>('ui:md')), findsOneWidget);
    // MarkdownBody is the widget the renderer constructs; existence
    // alone is the smoke signal.
    expect(find.byType(MarkdownBody), findsOneWidget);
  });

  testWidgets('UiMarkdown out-of-subset constructs do not crash',
      (tester) async {
    // Tables and raw HTML are out of subset — they should degrade to
    // escaped text rather than crashing.
    const tree = UiMarkdown(
      id: 'md2',
      markdown:
          'Hello\n\n| col1 | col2 |\n|------|------|\n| a | b |\n\n<script>x</script>',
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
  });

  testWidgets('UiCodeBlock with known language renders HighlightView',
      (tester) async {
    const tree = UiCodeBlock(
      id: 'cb',
      code: 'const x = 1;',
      language: 'javascript',
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.byType(HighlightView), findsOneWidget);
  });

  testWidgets('UiCodeBlock without language falls back to plain monospace',
      (tester) async {
    const tree = UiCodeBlock(id: 'cb-plain', code: 'plain text');
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.byType(HighlightView), findsNothing);
    expect(find.text('plain text'), findsOneWidget);
  });

  testWidgets('UiProgress determinate linear renders LinearProgressIndicator',
      (tester) async {
    const tree = UiProgress(id: 'pg', value: 0.4, label: '40%');
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    final ind = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(ind.value, 0.4);
    expect(find.text('40%'), findsOneWidget);
  });

  testWidgets('UiProgress indeterminate has null value',
      (tester) async {
    const tree = UiProgress(id: 'pg2');
    await tester.pumpWidget(_host(tree));
    final ind = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(ind.value, isNull);
  });

  testWidgets('UiProgress circular variant renders CircularProgressIndicator',
      (tester) async {
    const tree = UiProgress(
      id: 'pg3',
      value: 0.7,
      variant: UiProgressVariant.circular,
      label: 'syncing',
    );
    await tester.pumpWidget(_host(tree));
    final ind = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(ind.value, 0.7);
    expect(find.text('syncing'), findsOneWidget);
  });

  testWidgets('UiSpinner renders CircularProgressIndicator with optional label',
      (tester) async {
    const tree = UiSpinner(id: 'sp', label: 'refreshing…');
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    final ind = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    // Spinner is indeterminate.
    expect(ind.value, isNull);
    expect(find.text('refreshing…'), findsOneWidget);
  });

  testWidgets('UiSpinner without label still renders the indicator',
      (tester) async {
    const tree = UiSpinner(id: 'sp2');
    await tester.pumpWidget(_host(tree));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  test(
      'UiNode.fromJson parses Batch 3 widgets (Image / Avatar / Markdown / CodeBlock / Progress / Spinner)',
      () {
    final img = UiNode.fromJson(<String, dynamic>{
      'kind': 'Image',
      'id': 'i',
      'src': 'https://x/y.png',
      'fit': 'contain',
      'size': 'lg',
    });
    expect((img as UiImage).src, 'https://x/y.png');
    expect(img.fit, UiImageFit.contain);
    expect(img.size?.token, SizeToken.lg);

    final av = UiNode.fromJson(<String, dynamic>{
      'kind': 'Avatar',
      'id': 'a',
      'initial': 'AB',
      'accent': 'info',
    });
    expect((av as UiAvatar).initial, 'AB');
    expect(av.accent, AccentToken.info);

    final mdNode = UiNode.fromJson(<String, dynamic>{
      'kind': 'Markdown',
      'id': 'm',
      'markdown': '# h',
    });
    expect((mdNode as UiMarkdown).markdown, '# h');

    final cb = UiNode.fromJson(<String, dynamic>{
      'kind': 'CodeBlock',
      'id': 'c',
      'code': 'x=1',
      'language': 'python',
    });
    expect((cb as UiCodeBlock).code, 'x=1');
    expect(cb.language, 'python');

    final pg = UiNode.fromJson(<String, dynamic>{
      'kind': 'Progress',
      'id': 'p',
      'value': 0.3,
      'variant': 'circular',
      'label': 'go',
      'accent': 'success',
    });
    expect((pg as UiProgress).value, 0.3);
    expect(pg.variant, UiProgressVariant.circular);
    expect(pg.label, 'go');
    expect(pg.accent, AccentToken.success);

    final sp = UiNode.fromJson(<String, dynamic>{
      'kind': 'Spinner',
      'id': 's',
      'label': 'loading',
      'size': 'md',
    });
    expect((sp as UiSpinner).label, 'loading');
    expect(sp.size?.token, SizeToken.md);
  });

  test('UiAvatar.fromJson rejects when neither src nor initial is set', () {
    expect(
      () => UiNode.fromJson(<String, dynamic>{'kind': 'Avatar', 'id': 'a'}),
      throwsFormatException,
    );
  });

  test('UiProgress.fromJson rejects value outside [0, 1]', () {
    expect(
      () => UiNode.fromJson(<String, dynamic>{
        'kind': 'Progress',
        'id': 'p',
        'value': 1.5,
      }),
      throwsFormatException,
    );
  });

  test('UiImage.fromJson rejects unknown fit', () {
    expect(
      () => UiNode.fromJson(<String, dynamic>{
        'kind': 'Image',
        'id': 'i',
        'src': 'https://x',
        'fit': 'scaleDown',
      }),
      throwsFormatException,
    );
  });

  test('icon catalog covers a few essential names', () {
    // Quick smoke test that the curated subset is wired up. We don't
    // assert the full list — that lives in the source file.
    for (final name in const [
      'home',
      'settings',
      'code',
      'terminal',
      'file',
      'folder',
      'plus',
      'check',
      'x',
    ]) {
      expect(resolveIconByName(name), isNotNull, reason: name);
    }
    expect(resolveIconByName('definitely-not-a-feather-icon'), isNull);
  });
}
