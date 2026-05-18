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

import 'package:mobilecode/ui/app_tokens.dart';
import 'package:mobilecode/ui/icon_catalog.dart';
import 'package:mobilecode/ui/ui_node.dart';
import 'package:mobilecode/ui/ui_renderer.dart';

Widget _host(UiNode tree, {void Function(UiNodeEvent)? onEvent}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: UiRenderer(
          tree: tree,
          onEvent: onEvent ?? (_) {},
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
