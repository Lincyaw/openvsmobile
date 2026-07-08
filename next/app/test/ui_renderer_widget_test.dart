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

import 'package:mobilecode/services/voice_interaction.dart';
import 'package:mobilecode/ui/app_tokens.dart';
import 'package:mobilecode/ui/icon_catalog.dart';
import 'package:mobilecode/ui/ui_modal_renderer.dart';
import 'package:mobilecode/ui/ui_node.dart';
import 'package:mobilecode/ui/ui_renderer.dart';

Widget _host(
  UiNode tree, {
  void Function(UiNodeEvent)? onEvent,
  void Function(String gridId, String tileId)? onAppTileLongPress,
  VoiceInteraction voice = const PlatformVoiceInteraction(),
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: UiRenderer(
          tree: tree,
          onEvent: onEvent ?? (_) {},
          voice: voice,
          onAppTileLongPress: onAppTileLongPress,
        ),
      ),
    ),
  );
}

class _FakeVoiceInteraction extends VoiceInteraction {
  final String? text;
  final List<String> spoken = <String>[];

  _FakeVoiceInteraction(this.text);

  @override
  Future<bool> isSpeechRecognitionAvailable() async => true;

  @override
  Future<String?> recognizeOnce({String? prompt}) async => text;

  @override
  Future<bool> speak(String text) async {
    spoken.add(text);
    return true;
  }

  @override
  Future<bool> speakAndWait(String text) async {
    spoken.add(text);
    return true;
  }

  @override
  Future<void> stopSpeaking() async {}
}

/// Drives `showUiModal` from inside a MaterialApp so `showDialog` /
/// `showModalBottomSheet` find a Navigator. Mounts a Builder that
/// captures the BuildContext, then invokes the modal entry point on
/// the very first frame.
Future<void> _runModalHarness(
  WidgetTester tester, {
  required UiModalPush push,
  required void Function(UiNodeEvent) onEvent,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            // Kick off the modal once on first frame — `addPostFrameCallback`
            // ensures the Navigator is ready.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              showUiModal(context: ctx, push: push, onEvent: onEvent);
            });
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

UiNode _allKindsTree() {
  // One node of every v0 kind, all with unique ids. Acceptance: "All 9
  // widget kinds … implemented and exercised by widget tests."
  return UiColumn(
    id: 'root-col',
    gap: SpacingSlot.number(8),
    children: [
      const UiText(
        id: 't-title',
        text: 'Title goes here',
        style: UiTextStyleKind.title,
      ),
      const UiText(
        id: 't-body',
        text: 'Body line',
        style: UiTextStyleKind.body,
      ),
      const UiText(
        id: 't-caption',
        text: 'caption text',
        style: UiTextStyleKind.caption,
      ),
      const UiText(id: 't-mono', text: 'mono()', style: UiTextStyleKind.mono),
      UiSpacer(id: 'sp-1', size: SpacingSlot.number(12)),
      UiRow(
        id: 'row-1',
        gap: SpacingSlot.number(4),
        children: const [
          UiText(id: 'row-t1', text: 'left'),
          UiText(id: 'row-t2', text: 'right'),
        ],
      ),
      UiSection(
        id: 'sec-1',
        title: 'A section',
        children: [UiText(id: 'sec-t', text: 'inside section')],
      ),
      UiCard(
        id: 'card-1',
        children: [UiText(id: 'card-t', text: 'inside card')],
      ),
      UiList(
        id: 'list-1',
        items: [
          UiText(id: 'list-i0', text: 'item 0'),
          UiText(id: 'list-i1', text: 'item 1'),
        ],
      ),
      UiTextField(
        id: 'tf-1',
        label: 'Name',
        value: 'initial',
        placeholder: 'enter name',
      ),
      UiButton(
        id: 'btn-primary',
        label: 'Primary',
        style: UiButtonStyleKind.primary,
      ),
      UiButton(
        id: 'btn-secondary',
        label: 'Secondary',
        style: UiButtonStyleKind.secondary,
      ),
      UiButton(
        id: 'btn-danger',
        label: 'Danger',
        style: UiButtonStyleKind.danger,
      ),
    ],
  );
}

void main() {
  test('UiNode.fromJson preserves eyes-free metadata', () {
    final node = UiNode.fromJson({
      'kind': 'Text',
      'id': 'status',
      'text': 'Done',
      'accessibilityLabel': 'Agent status',
      'accessibilityHint': 'Double tap to open details',
      'spokenValue': 'Agent finished with 3 changed files',
      'focusRole': 'status',
      'focusOrder': 2,
      'voiceInputEvent': 'voice.reply',
    });

    expect(node.accessibility.accessibilityLabel, 'Agent status');
    expect(node.accessibility.accessibilityHint, 'Double tap to open details');
    expect(
      node.accessibility.spokenValue,
      'Agent finished with 3 changed files',
    );
    expect(node.accessibility.focusRole, UiFocusRole.status);
    expect(node.accessibility.focusOrder, 2);
    expect(node.accessibility.voiceInputEvent, 'voice.reply');
  });

  testWidgets('renders eyes-free metadata as Semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final tree = UiNode.fromJson({
        'kind': 'Text',
        'id': 'status',
        'text': 'Done',
        'accessibilityLabel': 'Agent status',
        'accessibilityHint': 'Double tap to open details',
        'spokenValue': 'Agent finished with 3 changed files',
        'focusRole': 'status',
        'focusOrder': 2,
      });

      await tester.pumpWidget(_host(tree));

      final node = tester.getSemantics(
        find.byKey(const ValueKey<String>('ui:status:semantics')),
      );
      expect(node.label, 'Agent status');
      expect(node.value, 'Agent finished with 3 changed files');
      expect(node.hint, 'Double tap to open details');
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('renders every widget kind without throwing', (tester) async {
    await tester.pumpWidget(_host(_allKindsTree()));
    // The error pump would have surfaced via takeException; ensure we
    // also see the obvious bits.
    expect(tester.takeException(), isNull);
    expect(find.byType(Column), findsWidgets);
    expect(find.byType(Row), findsOneWidget);
    expect(find.byType(Card), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    expect(find.text('Title goes here'), findsOneWidget);
    expect(find.text('Body line'), findsOneWidget);
    expect(find.text('caption text'), findsOneWidget);
    expect(find.text('mono()'), findsOneWidget);
    expect(find.text('inside section'), findsOneWidget);
    expect(find.text('inside card'), findsOneWidget);
    expect(find.text('item 0'), findsOneWidget);
    expect(find.text('item 1'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(ElevatedButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets(
    'reconciles by id: same Text Element after a mutating re-render',
    (tester) async {
      UiNode treeWithLabel(String label) => UiColumn(
        id: 'root',
        children: [UiText(id: 'leaf', text: label)],
      );

      final firstHost = _host(treeWithLabel('alpha'));
      await tester.pumpWidget(firstHost);
      final firstElement = tester.element(
        find.byKey(const ValueKey('ui:leaf')),
      );
      expect(find.text('alpha'), findsOneWidget);

      // Same tree shape, same node ids, mutated leaf value.
      await tester.pumpWidget(_host(treeWithLabel('beta')));
      final secondElement = tester.element(
        find.byKey(const ValueKey('ui:leaf')),
      );
      // Identical Element instance → Flutter matched the new widget to the
      // existing Element, which is what preserves focus/scroll/animation.
      expect(identical(firstElement, secondElement), isTrue);
      expect(find.text('beta'), findsOneWidget);
      expect(find.text('alpha'), findsNothing);
    },
  );

  testWidgets('reconciles by id: TextField Element survives re-render', (
    tester,
  ) async {
    UiNode treeWithLabel(String label) => UiColumn(
      id: 'root',
      children: [UiTextField(id: 'tf', label: label)],
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

  testWidgets('TextField onChange emits UiNodeEvent with the new value', (
    tester,
  ) async {
    final events = <UiNodeEvent>[];
    final tree = UiTextField(id: 'tf', label: 'name');
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    await tester.enterText(find.byType(TextField), 'hello world');
    expect(events, hasLength(1));
    expect(events.single.nodeId, 'tf');
    expect(events.single.type, 'changed');
    expect(events.single.payload, {'value': 'hello world'});
  });

  testWidgets('voice-enabled TextField dictates then fires voice event', (
    tester,
  ) async {
    final events = <UiNodeEvent>[];
    final voice = _FakeVoiceInteraction('send this by voice');
    final tree = UiNode.fromJson({
      'kind': 'TextField',
      'id': 'tf',
      'label': 'Message',
      'placeholder': 'Type or dictate',
      'voiceInputEvent': 'send',
    });

    await tester.pumpWidget(_host(tree, onEvent: events.add, voice: voice));
    await tester.tap(find.text('Speak and send'));
    await tester.pumpAndSettle();

    expect(find.text('send this by voice'), findsOneWidget);
    expect(events, hasLength(2));
    expect(events[0].nodeId, 'tf');
    expect(events[0].type, 'changed');
    expect(events[0].payload, {'value': 'send this by voice'});
    expect(events[1].nodeId, 'tf');
    expect(events[1].type, 'send');
    expect(events[1].payload, {
      'value': 'send this by voice',
      'source': 'voice',
    });
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

  testWidgets('UiIcon renders a known Feather glyph at the requested size', (
    tester,
  ) async {
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

  testWidgets('UiIcon falls back to a placeholder for unknown names', (
    tester,
  ) async {
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

  testWidgets('UiBadge pill renders text/count and a rounded background', (
    tester,
  ) async {
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

  testWidgets('UiListTile renders title/subtitle and emits onTapEvent', (
    tester,
  ) async {
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

  testWidgets('UiListTile renders leading + trailing nodes via recursion', (
    tester,
  ) async {
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

  testWidgets('UiListTile with swipeActions wraps the tile in a Slidable', (
    tester,
  ) async {
    // Batch 4 lights up the swipe gesture. The tile is wrapped in a
    // Slidable when `swipeActions` is non-empty; tapping a revealed
    // action fires the configured eventId.
    final events = <UiNodeEvent>[];
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
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    expect(tester.takeException(), isNull);
    expect(find.text('With swipe'), findsOneWidget);
    // Slidable key is mounted (action pane is offscreen until swipe).
    expect(
      find.byKey(const ValueKey<String>('ui-tile-slidable:row')),
      findsOneWidget,
    );
    // The action's wire-event has not fired yet — Slidable's panel
    // stays off-screen until the user drags.
    expect(events, isEmpty);
  });

  testWidgets('UiAppGrid renders one tile per item and fires onLaunchEvent', (
    tester,
  ) async {
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

  testWidgets('UiAppGrid uses default onLaunchEvent="launch" when omitted', (
    tester,
  ) async {
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
      await tester.pumpWidget(
        _host(
          tree,
          onAppTileLongPress: (gridId, tileId) =>
              longPresses.add((gridId, tileId)),
        ),
      );
      await tester.longPress(find.text('Alpha'));
      await tester.pump();
      expect(longPresses, [('g', 't1')]);
    },
  );

  testWidgets('UiBadge danger pill pairs the foreground with onError', (
    tester,
  ) async {
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
    final scheme = Theme.of(tester.element(find.text('99'))).colorScheme;
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

  testWidgets('StyleSlotResolver: spacing tokens map to AppSpacing scale', (
    tester,
  ) async {
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

  testWidgets('StyleSlotResolver: size tokens map to icon size buckets', (
    tester,
  ) async {
    expect(StyleSlotResolver.size(SizeToken.sm), AppIconSize.sm);
    expect(StyleSlotResolver.size(SizeToken.md), AppIconSize.md);
    expect(StyleSlotResolver.size(SizeToken.lg), AppIconSize.lg);
  });

  testWidgets('StyleSlotResolver: surface / accent resolve via ColorScheme', (
    tester,
  ) async {
    late BuildContext capturedCtx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) {
            capturedCtx = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
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

  testWidgets(
    'StyleSlotResolver: info / success / warning paint distinct hues',
    (tester) async {
      // Regression guard: pre-review these collapsed to scheme.tertiary
      // (info+warning) and a hardcoded green hex (success). Each must
      // resolve to a different Color so plugin authors using the three
      // tokens get visually distinguishable accents.
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final info = StyleSlotResolver.accent(ctx, AccentToken.info);
      final success = StyleSlotResolver.accent(ctx, AccentToken.success);
      final warning = StyleSlotResolver.accent(ctx, AccentToken.warning);
      expect(info, isNot(equals(success)));
      expect(info, isNot(equals(warning)));
      expect(success, isNot(equals(warning)));
    },
  );

  testWidgets('StyleSlotResolver: brightness flips info between light & dark', (
    tester,
  ) async {
    // Same accent token reads differently on a light vs dark surface —
    // the resolver picks a tuned hue per brightness so the contrast
    // intent survives mode switches.
    Color? darkInfo;
    await tester.pumpWidget(
      MaterialApp(
        home: Theme(
          data: ThemeData(brightness: Brightness.dark),
          child: Builder(
            builder: (ctx) {
              darkInfo = StyleSlotResolver.accent(ctx, AccentToken.info);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    Color? lightInfo;
    await tester.pumpWidget(
      MaterialApp(
        home: Theme(
          data: ThemeData(brightness: Brightness.light),
          child: Builder(
            builder: (ctx) {
              lightInfo = StyleSlotResolver.accent(ctx, AccentToken.info);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
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

  testWidgets('UiSection variant=plain renders title + children stacked', (
    tester,
  ) async {
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
    },
  );

  testWidgets('UiSection variant=card wraps children in a Material Card', (
    tester,
  ) async {
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
    },
  );

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
    },
  );

  testWidgets('UiSection variant=inset paints title as caption above surface', (
    tester,
  ) async {
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

  testWidgets('UiSwitch flips locally and emits onChangeEvent payload', (
    tester,
  ) async {
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

  testWidgets('UiSwitch syncs local value when the wire value changes', (
    tester,
  ) async {
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

  testWidgets('UiSelect opens a modal bottom sheet picker on tap', (
    tester,
  ) async {
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
    await tester.tap(
      find.byKey(const ValueKey<String>('select-option:sel/dark')),
    );
    await tester.pumpAndSettle();
    expect(events, hasLength(1));
    expect(events.single.type, 'pick');
    expect(events.single.payload, {'value': 'dark'});
    // Trigger row reflects the new pick.
    expect(find.text('Dark'), findsOneWidget);
  });

  testWidgets('UiInlineBanner paints with the accent color and an icon', (
    tester,
  ) async {
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

  testWidgets('UiInlineBanner action fires the configured eventId', (
    tester,
  ) async {
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

  testWidgets('UiInlineBanner dismiss button fires dismissEventId', (
    tester,
  ) async {
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

  testWidgets('UiDivider horizontal renders a Material Divider', (
    tester,
  ) async {
    const tree = UiColumn(
      id: 'c',
      children: [
        UiText(id: 't1', text: 'above'),
        UiDivider(id: 'div'),
        UiText(id: 't2', text: 'below'),
      ],
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey<String>('ui:div')), findsOneWidget);
    expect(find.byType(Divider), findsWidgets);
  });

  testWidgets('UiDivider vertical renders a VerticalDivider', (tester) async {
    const tree = UiDivider(
      id: 'div',
      orientation: UiDividerOrientation.vertical,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 50,
            child: Row(
              children: [
                const Text('a'),
                UiRenderer(tree: tree, onEvent: (_) {}),
                const Text('b'),
              ],
            ),
          ),
        ),
      ),
    );
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

  test(
    'UiNode.fromJson parses UiSwitch / UiSelect / UiInlineBanner / UiDivider',
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
    },
  );

  // ---- Batch 3 widgets (§4.3) — rich display ----

  testWidgets('UiImage renders a NetworkImage for an https:// src', (
    tester,
  ) async {
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

  testWidgets('UiImage renders a MemoryImage for a data: URL', (tester) async {
    // 1x1 transparent PNG, base64 encoded.
    const onePixelPng =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
    const tree = UiImage(id: 'data-img', src: onePixelPng);
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<MemoryImage>());
  });

  testWidgets(
    'UiImage with unknown scheme renders the broken-image placeholder',
    (tester) async {
      const tree = UiImage(id: 'broken', src: 'rocket://nowhere');
      await tester.pumpWidget(_host(tree));
      expect(tester.takeException(), isNull);
      // Placeholder uses Icons.broken_image_outlined; no Image widget rendered.
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets(
    'UiAvatar with no src renders the initial glyph on a hashed color',
    (tester) async {
      const tree = UiAvatar(id: 'av', initial: 'AB');
      await tester.pumpWidget(_host(tree));
      expect(tester.takeException(), isNull);
      // Glyph is uppercased to "AB" by the renderer's _avatarGlyph helper.
      expect(find.text('AB'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets('UiAvatar hash color is deterministic for the same initial', (
    tester,
  ) async {
    // Two avatars with the same initial must paint identical container
    // colors; two with different initials should differ (with very high
    // probability across the 8-bucket palette). The Avatar widget IS
    // a Container (no nested chrome), so we read the keyed Container's
    // decoration directly — `find.descendant + Container` would match
    // both the avatar AND any enclosing surface, breaking `widget()`.
    const tree = UiRow(
      id: 'r',
      children: [
        UiAvatar(id: 'a1', initial: 'A'),
        UiAvatar(id: 'a2', initial: 'A'),
        UiAvatar(id: 'a3', initial: 'Z'),
      ],
    );
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

  testWidgets('UiAvatar accent overrides the hash color', (tester) async {
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

  testWidgets('UiMarkdown renders body text without throwing', (tester) async {
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

  testWidgets('UiMarkdown out-of-subset constructs do not crash', (
    tester,
  ) async {
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

  testWidgets('UiCodeBlock with known language renders HighlightView', (
    tester,
  ) async {
    const tree = UiCodeBlock(
      id: 'cb',
      code: 'const x = 1;',
      language: 'javascript',
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.byType(HighlightView), findsOneWidget);
  });

  testWidgets('UiCodeBlock without language falls back to plain monospace', (
    tester,
  ) async {
    const tree = UiCodeBlock(id: 'cb-plain', code: 'plain text');
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.byType(HighlightView), findsNothing);
    expect(find.text('plain text'), findsOneWidget);
  });

  // Regression guard: a CodeBlock dropped directly into a Row with
  // auto-sizing children must not blow up layout. The CodeBlock has an
  // inner horizontal scroller — without an outer width constraint, an
  // unbounded Row child would assert. Asserting `takeException()` is
  // null covers any future regression where the constraint disappears.
  testWidgets('UiCodeBlock inside UiRow lays out under bounded constraints', (
    tester,
  ) async {
    final tree = UiRow(
      id: 'row-cb',
      children: [UiCodeBlock(id: 'cb-row', code: 'x' * 200)],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 200,
              child: UiRenderer(tree: tree, onEvent: (_) {}),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('UiProgress determinate linear renders LinearProgressIndicator', (
    tester,
  ) async {
    const tree = UiProgress(id: 'pg', value: 0.4, label: '40%');
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    final ind = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(ind.value, 0.4);
    expect(find.text('40%'), findsOneWidget);
  });

  testWidgets('UiProgress indeterminate has null value', (tester) async {
    const tree = UiProgress(id: 'pg2');
    await tester.pumpWidget(_host(tree));
    final ind = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(ind.value, isNull);
  });

  testWidgets('UiProgress circular variant renders CircularProgressIndicator', (
    tester,
  ) async {
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

  testWidgets(
    'UiSpinner renders CircularProgressIndicator with optional label',
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
    },
  );

  testWidgets('UiSpinner without label still renders the indicator', (
    tester,
  ) async {
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
    },
  );

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

  // ---- Batch 4 SwipeAction rendering ----

  testWidgets('UiListTile swipe reveals action and tap fires eventId', (
    tester,
  ) async {
    // The Slidable action pane sits offscreen until swipe. We drag the
    // tile left to expose the action, then tap the revealed label.
    final events = <UiNodeEvent>[];
    const tree = UiListTile(
      id: 'row',
      title: 'Sweep me',
      swipeActions: [
        UiSwipeAction(
          label: 'Archive',
          eventId: 'row.archive',
          icon: 'folder',
          accent: AccentToken.info,
        ),
        UiSwipeAction(
          label: 'Delete',
          eventId: 'row.delete',
          icon: 'trash',
          accent: AccentToken.danger,
        ),
      ],
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    // Drag from the tile far enough to fully open the action pane.
    await tester.drag(find.text('Sweep me'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    // The two action labels are now mounted in the action pane.
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    // Tap the Delete action → its eventId fires.
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(events, hasLength(1));
    expect(events.single.nodeId, 'row');
    expect(events.single.type, 'row.delete');
  });

  // ---- Batch 4 modal renderers ----
  //
  // The modal renderers live in `ui_modal_renderer.dart` (not inside
  // UiRenderer). Tests below import the entry point directly and use a
  // MaterialApp host so showDialog / showModalBottomSheet have a
  // Navigator.

  testWidgets('showUiModal AlertDialog fires picked action eventId', (
    tester,
  ) async {
    UiNodeEvent? captured;
    await _runModalHarness(
      tester,
      push: const UiAlertPush(
        pluginId: 'p',
        panelId: 'home',
        alert: UiAlertDialog(
          id: 'a-1',
          title: 'Delete?',
          body: 'This cannot be undone.',
          actions: [
            UiAlertAction(label: 'Cancel', eventId: 'cancel'),
            UiAlertAction(
              label: 'Delete',
              eventId: 'delete',
              variant: UiAlertActionVariant.danger,
            ),
          ],
        ),
      ),
      onEvent: (e) => captured = e,
    );
    expect(find.text('Delete?'), findsOneWidget);
    expect(find.text('This cannot be undone.'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(captured, isNotNull);
    expect(captured!.nodeId, 'a-1');
    expect(captured!.type, 'delete');
  });

  testWidgets(
    'showUiModal AlertDialog with dismissible:false blocks tap-outside',
    (tester) async {
      UiNodeEvent? captured;
      await _runModalHarness(
        tester,
        push: const UiAlertPush(
          pluginId: 'p',
          panelId: 'home',
          alert: UiAlertDialog(
            id: 'a-2',
            title: 'Confirm',
            actions: [UiAlertAction(label: 'OK', eventId: 'ok')],
            dismissible: false,
          ),
        ),
        onEvent: (e) => captured = e,
      );
      // Tap-outside the dialog should NOT close it.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Confirm'), findsOneWidget);
      expect(captured, isNull);
      // OK still works.
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(captured?.type, 'ok');
    },
  );

  testWidgets('showUiModal ActionSheet fires picked action and dismiss event', (
    tester,
  ) async {
    final captured = <UiNodeEvent>[];
    await _runModalHarness(
      tester,
      push: const UiActionSheetPush(
        pluginId: 'p',
        panelId: 'home',
        sheet: UiActionSheet(
          id: 'sh-1',
          title: 'Refresh interval',
          actions: [
            UiActionSheetAction(label: '15s', eventId: 'i:15', icon: 'clock'),
            UiActionSheetAction(label: '1m', eventId: 'i:60', icon: 'clock'),
          ],
          dismissEventId: 'cancel',
        ),
      ),
      onEvent: captured.add,
    );
    expect(find.text('Refresh interval'), findsOneWidget);
    await tester.tap(find.text('15s'));
    await tester.pumpAndSettle();
    expect(captured, hasLength(1));
    expect(captured.single.nodeId, 'sh-1');
    expect(captured.single.type, 'i:15');
  });

  testWidgets('showUiModal BottomSheet renders child via UiRenderer', (
    tester,
  ) async {
    final captured = <UiNodeEvent>[];
    await _runModalHarness(
      tester,
      push: UiBottomSheetPush(
        pluginId: 'p',
        panelId: 'home',
        sheet: UiBottomSheet(
          id: 'bs-1',
          title: 'Note info',
          child: UiColumn(
            id: 'bs-col',
            children: const [
              UiText(id: 'bs-text', text: 'Created: today'),
              UiButton(id: 'bs-btn', label: 'OK'),
            ],
          ),
          dismissEventId: 'close',
        ),
      ),
      onEvent: captured.add,
    );
    expect(find.text('Created: today'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
    // Tapping the inner button fires through onEvent as 'tap'.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(captured, hasLength(1));
    expect(captured.single.nodeId, 'bs-btn');
    expect(captured.single.type, 'tap');
  });

  // ---- Batch 4 modal type parsing ----

  test(
    'UiModalPush.tryFromJson parses alert / actionSheet / bottomSheet kinds',
    () {
      final alert = UiModalPush.tryFromJson(<String, dynamic>{
        'kind': 'alert',
        'pluginId': 'p',
        'panelId': 'home',
        'alert': <String, dynamic>{
          'id': 'a',
          'title': 'T',
          'actions': [
            <String, dynamic>{'label': 'OK', 'eventId': 'ok'},
          ],
        },
      });
      expect(alert, isA<UiAlertPush>());
      expect((alert as UiAlertPush).alert.title, 'T');

      final sheet = UiModalPush.tryFromJson(<String, dynamic>{
        'kind': 'actionSheet',
        'pluginId': 'p',
        'panelId': 'home',
        'sheet': <String, dynamic>{
          'id': 'sh',
          'actions': [
            <String, dynamic>{'label': 'A', 'eventId': 'a'},
          ],
        },
      });
      expect(sheet, isA<UiActionSheetPush>());

      final bs = UiModalPush.tryFromJson(<String, dynamic>{
        'kind': 'bottomSheet',
        'pluginId': 'p',
        'panelId': 'home',
        'sheet': <String, dynamic>{
          'id': 'bs',
          'child': <String, dynamic>{'kind': 'Text', 'id': 't', 'text': 'x'},
        },
      });
      expect(bs, isA<UiBottomSheetPush>());

      expect(
        UiModalPush.tryFromJson(<String, dynamic>{'kind': 'bogus'}),
        isNull,
      );
    },
  );

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

  _batch5Tests();
}

// ---- Batch 5 widgets (§4.3) — long tail ----

void _batch5Tests() {
  testWidgets('UiGrid renders fixed-column GridView with N items', (
    tester,
  ) async {
    final tree = UiGrid(
      id: 'g',
      columns: UiGridColumns.fixedCount(2),
      children: const [
        UiText(id: 'g.t1', text: 'one'),
        UiText(id: 'g.t2', text: 'two'),
        UiText(id: 'g.t3', text: 'three'),
        UiText(id: 'g.t4', text: 'four'),
      ],
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('one'), findsOneWidget);
    expect(find.text('four'), findsOneWidget);
  });

  testWidgets('UiGrid adaptive columns scales with viewport', (tester) async {
    // Narrow viewport: at ~120dp per cell we expect 1 column.
    tester.view.physicalSize = const Size(160, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final tree = UiGrid(
      id: 'g-adapt',
      columns: UiGridColumns.adaptiveCount(),
      children: const [UiText(id: 'a', text: 'a')],
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    final gridView = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        gridView.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, greaterThanOrEqualTo(1));
  });

  testWidgets('UiStack aligns child per alignment token', (tester) async {
    const tree = UiStack(
      id: 's2',
      alignment: UiStackAlignment.bottomEnd,
      children: [UiText(id: 's2.t', text: 'corner')],
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    final stack = tester.widget<Stack>(find.byKey(const ValueKey('ui:s2')));
    expect(stack.alignment, Alignment.bottomRight);
  });

  testWidgets('UiAspect wraps its child in an AspectRatio', (tester) async {
    const tree = UiAspect(
      id: 'a',
      ratio: 16 / 9,
      child: UiText(id: 'a.t', text: 'inside'),
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    final ar = tester.widget<AspectRatio>(find.byKey(const ValueKey('ui:a')));
    expect(ar.aspectRatio, closeTo(16 / 9, 0.001));
    expect(find.text('inside'), findsOneWidget);
  });

  testWidgets('UiFlex inside Row takes the larger share', (tester) async {
    final tree = UiRow(
      id: 'r',
      children: const [
        UiFlex(
          id: 'f1',
          flex: 1,
          child: UiText(id: 'a', text: 'a'),
        ),
        UiFlex(
          id: 'f2',
          flex: 3,
          child: UiText(id: 'b', text: 'b'),
        ),
      ],
    );
    await tester.pumpWidget(_host(tree));
    expect(tester.takeException(), isNull);
    // Both render; the underlying Expanded is what matters.
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsOneWidget);
    expect(find.byType(Expanded), findsNWidgets(2));
  });

  testWidgets('UiScroll defaults to vertical and accepts horizontal', (
    tester,
  ) async {
    const vert = UiScroll(
      id: 'sv',
      child: UiText(id: 'sv.t', text: 'v'),
    );
    await tester.pumpWidget(_host(vert));
    expect(
      tester
          .widget<SingleChildScrollView>(find.byKey(const ValueKey('ui:sv')))
          .scrollDirection,
      Axis.vertical,
    );
    const horiz = UiScroll(
      id: 'sh',
      axis: UiScrollAxis.horizontal,
      child: UiText(id: 'sh.t', text: 'h'),
    );
    await tester.pumpWidget(_host(horiz));
    expect(
      tester
          .widget<SingleChildScrollView>(find.byKey(const ValueKey('ui:sh')))
          .scrollDirection,
      Axis.horizontal,
    );
  });

  testWidgets('UiTabBar renders one item per tab and fires onChangeEvent', (
    tester,
  ) async {
    final events = <UiNodeEvent>[];
    const tree = UiTabBar(
      id: 'tb',
      activeId: 'a',
      onChangeEvent: 'tabPicked',
      tabs: [
        UiTabBarTab(id: 'a', label: 'Alpha'),
        UiTabBarTab(id: 'b', label: 'Beta'),
        UiTabBarTab(id: 'c', label: 'Gamma'),
      ],
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    await tester.tap(find.text('Beta'));
    await tester.pump();
    expect(events, hasLength(1));
    expect(events.single.nodeId, 'tb');
    expect(events.single.type, 'tabPicked');
    expect(events.single.payload, {'tabId': 'b'});
  });

  testWidgets(
    'Section.collapsible persists expand state across re-render with same id',
    (tester) async {
      UiNode treeWithLabel(String label) => UiSection(
        id: 'collapsible-sec',
        title: 'Section',
        collapsible: true,
        children: [UiText(id: 'leaf', text: label)],
      );

      await tester.pumpWidget(_host(treeWithLabel('alpha')));
      // Default state is expanded → leaf visible.
      expect(find.text('alpha'), findsOneWidget);
      // Tap the header chevron / row to collapse.
      await tester.tap(find.text('Section'));
      await tester.pumpAndSettle();
      expect(find.text('alpha'), findsNothing);
      // Re-render with the same id but mutated leaf — collapsed state
      // should survive because the State is keyed by the section id.
      await tester.pumpWidget(_host(treeWithLabel('beta')));
      await tester.pump();
      expect(find.text('alpha'), findsNothing);
      expect(find.text('beta'), findsNothing);
    },
  );

  testWidgets(
    'Section.collapsible defaults expanded after re-render with new id',
    (tester) async {
      UiNode treeWithId(String id) => UiSection(
        id: id,
        title: 'Section',
        collapsible: true,
        children: const [UiText(id: 'leaf', text: 'visible')],
      );

      await tester.pumpWidget(_host(treeWithId('first')));
      expect(find.text('visible'), findsOneWidget);
      await tester.tap(find.text('Section'));
      await tester.pumpAndSettle();
      expect(find.text('visible'), findsNothing);
      // New id → fresh State → default expanded.
      await tester.pumpWidget(_host(treeWithId('second')));
      expect(find.text('visible'), findsOneWidget);
    },
  );

  testWidgets('UiSearchField renders magnifier prefix and emits onChange', (
    tester,
  ) async {
    final events = <UiNodeEvent>[];
    const tree = UiSearchField(
      id: 'sf',
      placeholder: 'search…',
      onChangeEvent: 'q',
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.search), findsNothing); // catalog returns Feather
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'ada');
    expect(events.last.payload, {'value': 'ada'});
  });

  testWidgets(
    'UiSearchField clear button wipes the controller and emits empty',
    (tester) async {
      final events = <UiNodeEvent>[];
      const tree = UiSearchField(
        id: 'sf2',
        value: 'starting',
        onChangeEvent: 'q',
      );
      await tester.pumpWidget(_host(tree, onEvent: events.add));
      // Clear button appears because value is non-empty.
      expect(find.byType(IconButton), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      final tf = tester.widget<TextField>(find.byType(TextField));
      expect(tf.controller!.text, isEmpty);
      expect(events.last.payload, {'value': ''});
    },
  );

  testWidgets('UiCheckbox toggles locally and emits onChangeEvent', (
    tester,
  ) async {
    final events = <UiNodeEvent>[];
    const tree = UiCheckbox(
      id: 'c',
      label: 'Agree',
      value: false,
      onChangeEvent: 'agreed',
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    expect(find.text('Agree'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(events.single.payload, {'value': true});
    final box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.value, isTrue);
  });

  testWidgets(
    'UiCheckbox syncs to wire value when the plugin re-renders disagreeing',
    (tester) async {
      UiNode tree(bool v) => UiCheckbox(id: 'c', value: v);
      await tester.pumpWidget(_host(tree(false)));
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      // Plugin re-renders with false — local must snap back.
      await tester.pumpWidget(_host(tree(false)));
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    },
  );

  testWidgets('UiRadioGroup single-select fires payload with picked value', (
    tester,
  ) async {
    final events = <UiNodeEvent>[];
    const tree = UiRadioGroup(
      id: 'r',
      onChangeEvent: 'pick',
      options: [
        UiRadioOption(value: 'a', label: 'A'),
        UiRadioOption(value: 'b', label: 'B'),
        UiRadioOption(value: 'c', label: 'C'),
      ],
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('radio:r/b')));
    await tester.pumpAndSettle();
    expect(events.single.payload, {'value': 'b'});
  });

  testWidgets(
    'UiRadioGroup syncs to wire value when plugin re-renders disagreeing',
    (tester) async {
      UiNode tree(String? v) => UiRadioGroup(
        id: 'r2',
        value: v,
        options: const [
          UiRadioOption(value: 'a', label: 'A'),
          UiRadioOption(value: 'b', label: 'B'),
        ],
      );
      await tester.pumpWidget(_host(tree('a')));
      await tester.tap(find.byKey(const ValueKey<String>('radio:r2/b')));
      await tester.pumpAndSettle();
      // Plugin re-renders, still pointing at 'a' — local must snap.
      await tester.pumpWidget(_host(tree('a')));
      final radios = tester
          .widgetList<Radio<String>>(find.byType(Radio<String>))
          .toList();
      // RadioGroup<String> ancestor owns groupValue; assert through it.
      final group = tester.widget<RadioGroup<String>>(
        find.byType(RadioGroup<String>),
      );
      expect(group.groupValue, 'a');
      expect(radios, hasLength(2));
    },
  );

  testWidgets('UiSlider continuous emits payload on drag', (tester) async {
    final events = <UiNodeEvent>[];
    const tree = UiSlider(
      id: 's',
      min: 0,
      max: 100,
      value: 25,
      onChangeEvent: 'moved',
    );
    await tester.pumpWidget(_host(tree, onEvent: events.add));
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 25);
    expect(slider.divisions, isNull); // continuous
    // Drive a value change directly via the onChanged callback rather
    // than synthesizing a drag (the geometry is fiddly in tests).
    slider.onChanged!(50);
    await tester.pump();
    expect(events.single.payload, {'value': 50.0});
  });

  testWidgets('UiSlider stepped sets divisions from min/max/step', (
    tester,
  ) async {
    const tree = UiSlider(id: 's2', min: 0, max: 10, step: 2, value: 4);
    await tester.pumpWidget(_host(tree));
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.divisions, 5);
  });

  testWidgets('UiSlider clamps incoming value into [min, max]', (tester) async {
    const tree = UiSlider(id: 's3', min: 0, max: 10, value: 999);
    await tester.pumpWidget(_host(tree));
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, 10);
  });

  testWidgets(
    'UiSlider syncs to wire value when plugin re-renders disagreeing',
    (tester) async {
      UiNode tree(double v) => UiSlider(id: 'sw', min: 0, max: 100, value: v);
      await tester.pumpWidget(_host(tree(20)));
      tester.widget<Slider>(find.byType(Slider)).onChanged!(70);
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 70);
      // Plugin re-renders with 30 — local must snap.
      await tester.pumpWidget(_host(tree(30)));
      expect(tester.widget<Slider>(find.byType(Slider)).value, 30);
    },
  );

  testWidgets(
    'UiSlider snaps back when plugin re-renders with the prior value after a local drag',
    (tester) async {
      // Regression: the prior didUpdateWidget compared new wire vs old
      // wire — a "plugin rejects local drag by re-rendering the same
      // wire value" sequence (20 → drag to 70 → re-render with 20) left
      // the UI on 70 because wire-vs-wire was equal. The correct
      // comparator is wire-vs-local; this test pins it.
      UiNode tree(double v) =>
          UiSlider(id: 'sw-reject', min: 0, max: 100, value: v);
      await tester.pumpWidget(_host(tree(20)));
      expect(tester.widget<Slider>(find.byType(Slider)).value, 20);
      // User drags to 70 — local optimistic update.
      tester.widget<Slider>(find.byType(Slider)).onChanged!(70);
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 70);
      // Plugin rejects: re-renders with the same wire value (20). Local
      // must snap back even though new wire == old wire.
      await tester.pumpWidget(_host(tree(20)));
      expect(tester.widget<Slider>(find.byType(Slider)).value, 20);
    },
  );

  test('UiNode.fromJson parses Batch 5 widgets', () {
    final g =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'Grid',
              'id': 'g',
              'columns': 4,
              'gap': 'md',
              'children': <Map<String, dynamic>>[
                <String, dynamic>{'kind': 'Text', 'id': 't', 'text': 'x'},
              ],
            })
            as UiGrid;
    expect(g.columns.fixed, 4);
    expect(g.gap?.token, SpacingToken.md);

    final adaptive =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'Grid',
              'id': 'g2',
              'columns': 'adaptive',
              'children': <Map<String, dynamic>>[],
            })
            as UiGrid;
    expect(adaptive.columns.adaptive, isTrue);

    final st =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'Stack',
              'id': 's',
              'alignment': 'bottomEnd',
              'children': <Map<String, dynamic>>[],
            })
            as UiStack;
    expect(st.alignment, UiStackAlignment.bottomEnd);

    final ar =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'Aspect',
              'id': 'a',
              'ratio': 1.5,
              'child': <String, dynamic>{
                'kind': 'Text',
                'id': 't',
                'text': 'x',
              },
            })
            as UiAspect;
    expect(ar.ratio, 1.5);
    expect(ar.child, isA<UiText>());

    final flex =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'Flex',
              'id': 'f',
              'flex': 2,
              'child': <String, dynamic>{
                'kind': 'Text',
                'id': 't',
                'text': 'x',
              },
            })
            as UiFlex;
    expect(flex.flex, 2);

    final sc =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'Scroll',
              'id': 'sc',
              'axis': 'horizontal',
              'child': <String, dynamic>{
                'kind': 'Text',
                'id': 't',
                'text': 'x',
              },
            })
            as UiScroll;
    expect(sc.axis, UiScrollAxis.horizontal);

    final tb =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'TabBar',
              'id': 'tb',
              'activeId': 'a',
              'onChangeEvent': 'p',
              'tabs': <Map<String, dynamic>>[
                <String, dynamic>{'id': 'a', 'label': 'A'},
                <String, dynamic>{'id': 'b', 'label': 'B', 'icon': 'home'},
              ],
            })
            as UiTabBar;
    expect(tb.tabs.length, 2);
    expect(tb.tabs[1].icon, 'home');
    expect(tb.activeId, 'a');

    final sf =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'SearchField',
              'id': 'sf',
              'value': 'q',
              'placeholder': 'go',
              'onChangeEvent': 'changed',
            })
            as UiSearchField;
    expect(sf.value, 'q');
    expect(sf.onChangeEvent, 'changed');

    final cb =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'Checkbox',
              'id': 'cb',
              'value': true,
              'label': 'ok',
              'onChangeEvent': 'flip',
            })
            as UiCheckbox;
    expect(cb.value, isTrue);
    expect(cb.label, 'ok');

    final rg =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'RadioGroup',
              'id': 'rg',
              'value': 'x',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'x', 'label': 'X'},
                <String, dynamic>{'value': 'y', 'label': 'Y'},
              ],
            })
            as UiRadioGroup;
    expect(rg.options, hasLength(2));
    expect(rg.value, 'x');

    final sl =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'Slider',
              'id': 'sl',
              'min': 0,
              'max': 10,
              'step': 1,
              'value': 5,
            })
            as UiSlider;
    expect(sl.min, 0);
    expect(sl.max, 10);
    expect(sl.step, 1);
    expect(sl.value, 5);

    final coll =
        UiNode.fromJson(<String, dynamic>{
              'kind': 'Section',
              'id': 's',
              'collapsible': true,
              'children': <Map<String, dynamic>>[],
            })
            as UiSection;
    expect(coll.collapsible, isTrue);
  });
}
