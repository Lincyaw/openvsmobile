// Renderer for plugin-provided UI descriptors. Consumes a typed
// `UiNode` tree and renders Material widgets; emits `UiNodeEvent`s
// through an `onEvent` callback for the model layer to forward to the
// backend.
//
// Reconciliation contract (issue #59, design §4.3):
//   * Every widget is keyed by `ValueKey('ui:<id>')`. When the plugin
//     re-renders the same tree shape with mutated leaf values, Flutter
//     matches the new widgets to the existing Elements by Key, so focus,
//     scroll position, and animation state survive.
//   * Updates are full re-renders in v0; incremental `ui.update` patches
//     are reserved for v1 (CLAUDE.md §"Plugin model").

import 'package:flutter/material.dart';

import 'ui_node.dart';

/// Recursively renders a `UiNode` tree using Material widgets.
///
/// The callback is invoked from leaf widgets that produce events:
///   * `UiButton`    → `type: "tap"`
///   * `UiTextField` → `type: "changed"`, payload `{ "value": String }`
///
/// Container nodes never emit events themselves.
class UiRenderer extends StatelessWidget {
  final UiNode tree;
  final void Function(UiNodeEvent event) onEvent;

  const UiRenderer({super.key, required this.tree, required this.onEvent});

  @override
  Widget build(BuildContext context) => _render(context, tree);

  Widget _render(BuildContext context, UiNode node) {
    final key = ValueKey<String>('ui:${node.id}');
    switch (node) {
      case UiColumn(:final children, :final gap):
        return Column(
          key: key,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: _withGap(
            children.map((c) => _render(context, c)).toList(),
            gap,
            axis: Axis.vertical,
          ),
        );
      case UiRow(:final children, :final gap):
        return Row(
          key: key,
          mainAxisSize: MainAxisSize.min,
          children: _withGap(
            children.map((c) => _render(context, c)).toList(),
            gap,
            axis: Axis.horizontal,
          ),
        );
      case UiSection(:final title, :final children):
        return Padding(
          key: key,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title != null && title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ...children.map((c) => _render(context, c)),
            ],
          ),
        );
      case UiCard(:final children):
        return Card(
          key: key,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: children.map((c) => _render(context, c)).toList(),
            ),
          ),
        );
      case UiList(:final items):
        // Non-scrollable: a `UiList` typically sits inside a Column whose
        // own scroll parent (or the panel host) provides the viewport.
        // shrinkWrap + NeverScrollableScrollPhysics matches the issue
        // brief and avoids nested-scroll surprises.
        return ListView.builder(
          key: key,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          itemBuilder: (_, i) => _render(context, items[i]),
        );
      case UiText(:final text, :final style):
        return Text(text, key: key, style: _textStyleFor(context, style));
      case UiSpacer(:final size):
        final s = size ?? 0.0;
        return SizedBox(key: key, height: s, width: s);
      case UiTextField(:final label, :final value, :final placeholder):
        return _UiTextFieldRenderer(
          key: key,
          nodeId: node.id,
          label: label,
          initialValue: value,
          placeholder: placeholder,
          onChanged: (v) => onEvent(UiNodeEvent(
            nodeId: node.id,
            type: 'changed',
            payload: {'value': v},
          )),
        );
      case UiButton(:final label, :final style):
        return _buildButton(key, node.id, label, style);
    }
  }

  Widget _buildButton(
    Key key,
    String nodeId,
    String label,
    UiButtonStyleKind? style,
  ) {
    void emit() => onEvent(UiNodeEvent(nodeId: nodeId, type: 'tap'));
    switch (style ?? UiButtonStyleKind.primary) {
      case UiButtonStyleKind.primary:
        return ElevatedButton(
          key: key,
          onPressed: emit,
          child: Text(label),
        );
      case UiButtonStyleKind.secondary:
        return OutlinedButton(
          key: key,
          onPressed: emit,
          child: Text(label),
        );
      case UiButtonStyleKind.danger:
        // FilledButton.tonal per the issue spec — keeps the v0 vocabulary
        // small while still differentiating from primary/secondary.
        return FilledButton.tonal(
          key: key,
          onPressed: emit,
          child: Text(label),
        );
    }
  }

  TextStyle? _textStyleFor(BuildContext c, UiTextStyleKind? style) {
    final theme = Theme.of(c).textTheme;
    switch (style ?? UiTextStyleKind.body) {
      case UiTextStyleKind.body:
        return theme.bodyMedium;
      case UiTextStyleKind.title:
        return theme.titleLarge;
      case UiTextStyleKind.caption:
        return theme.bodySmall;
      case UiTextStyleKind.mono:
        // 'monospace' is the canonical family used by the file viewer,
        // diff viewer, and settings screen. Match it so plugin-rendered
        // code blocks visually align with the rest of the app.
        return (theme.bodyMedium ?? const TextStyle())
            .copyWith(fontFamily: 'monospace');
    }
  }

  List<Widget> _withGap(List<Widget> children, double? gap,
      {required Axis axis}) {
    if (gap == null || gap <= 0 || children.length < 2) return children;
    final spacer = SizedBox(
      width: axis == Axis.horizontal ? gap : 0,
      height: axis == Axis.vertical ? gap : 0,
    );
    final out = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) out.add(spacer);
      out.add(children[i]);
    }
    return out;
  }
}

/// Stateful inner renderer for `UiTextField`. Holds its own
/// `TextEditingController` so user keystrokes don't get clobbered by
/// re-renders, and so the caret survives a tree replacement that
/// happens to keep this node identity-stable. When the server-pushed
/// `value` actually changes between two pushes (i.e. the plugin chose
/// to overwrite the field), we sync the controller — but only when the
/// new value differs from what the user is currently typing, to avoid
/// gratuitous caret jumps.
class _UiTextFieldRenderer extends StatefulWidget {
  final String nodeId;
  final String? label;
  final String? initialValue;
  final String? placeholder;
  final void Function(String) onChanged;
  const _UiTextFieldRenderer({
    super.key,
    required this.nodeId,
    required this.label,
    required this.initialValue,
    required this.placeholder,
    required this.onChanged,
  });

  @override
  State<_UiTextFieldRenderer> createState() => _UiTextFieldRendererState();
}

class _UiTextFieldRendererState extends State<_UiTextFieldRenderer> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void didUpdateWidget(_UiTextFieldRenderer old) {
    super.didUpdateWidget(old);
    final next = widget.initialValue ?? '';
    if (widget.initialValue != old.initialValue && _controller.text != next) {
      _controller.text = next;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.placeholder,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: widget.onChanged,
    );
  }
}
