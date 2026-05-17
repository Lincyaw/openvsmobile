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
    gap: 8,
    children: const [
      UiText(id: 't-title', text: 'Title goes here', style: UiTextStyleKind.title),
      UiText(id: 't-body',  text: 'Body line',       style: UiTextStyleKind.body),
      UiText(id: 't-caption', text: 'caption text',  style: UiTextStyleKind.caption),
      UiText(id: 't-mono',  text: 'mono()',          style: UiTextStyleKind.mono),
      UiSpacer(id: 'sp-1', size: 12),
      UiRow(id: 'row-1', gap: 4, children: [
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
    expect(col.gap, 4.0);
    expect(col.children, hasLength(3));
    expect((col.children[0] as UiText).style, UiTextStyleKind.mono);
    expect((col.children[1] as UiSpacer).size, 8.0);
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
}
