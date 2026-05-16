// Terminal tab. Header chip strip = sessions belonging to the current
// workspace. Body = xterm.dart TerminalView for the focused session.

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';
import '../models.dart';

class TerminalTab extends StatefulWidget {
  final AppState appState;
  const TerminalTab({super.key, required this.appState});

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> {
  String? _autoCreatedFor;

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onChanged);
    _maybeAutoCreate();
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    _maybeAutoCreate();
  }

  Future<void> _maybeAutoCreate() async {
    final w = widget.appState.currentWorkspace;
    if (w == null) return;
    if (_autoCreatedFor == w.id) return;
    final existing = widget.appState.currentTerminals;
    if (existing.isNotEmpty) {
      _autoCreatedFor = w.id;
      return;
    }
    _autoCreatedFor = w.id;
    await widget.appState.createTerminal(
      workspaceId: w.id,
      cols: 80,
      rows: 24,
    );
  }

  Future<void> _confirmDispose(TerminalSession s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close terminal?'),
        content: Text(
          'Session ${s.id.substring(0, 8)}… will be killed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.appState.disposeTerminal(s.id);
    }
  }

  Future<void> _createNew() async {
    final w = widget.appState.currentWorkspace;
    if (w == null) return;
    await widget.appState.createTerminal(
      workspaceId: w.id,
      cols: 80,
      rows: 24,
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.appState.currentWorkspace;
    if (w == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No workspace open.\n'
            'Tap the title bar to choose one.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final sessions = widget.appState.currentTerminals;
    final focusedId = widget.appState.focusedTerminalId;
    return Column(
      children: [
        _ChipStrip(
          sessions: sessions,
          focusedId: focusedId,
          onTap: widget.appState.focusTerminal,
          onLongPress: _confirmDispose,
          onAdd: _createNew,
        ),
        const Divider(height: 1),
        Expanded(
          child: focusedId == null
              ? const Center(child: Text('Creating terminal…'))
              : _TerminalView(
                  // Generation bumps when the underlying Terminal is
                  // replaced (e.g. after a reconnect history replay), so
                  // including it in the key forces a fresh TerminalView.
                  key: ValueKey(
                      '$focusedId#${widget.appState.terminalGenerationFor(focusedId)}'),
                  terminal: widget.appState.terminalFor(focusedId),
                ),
        ),
      ],
    );
  }
}

class _ChipStrip extends StatelessWidget {
  final List<TerminalSession> sessions;
  final String? focusedId;
  final void Function(String id) onTap;
  final Future<void> Function(TerminalSession s) onLongPress;
  final VoidCallback onAdd;
  const _ChipStrip({
    required this.sessions,
    required this.focusedId,
    required this.onTap,
    required this.onLongPress,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: [
          for (var i = 0; i < sessions.length; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onLongPress: () => onLongPress(sessions[i]),
                child: ChoiceChip(
                  label: Text('sh ${i + 1}'),
                  selected: sessions[i].id == focusedId,
                  onSelected: (_) => onTap(sessions[i].id),
                ),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ActionChip(
              avatar: const Icon(Icons.add, size: 18),
              label: const Text('New'),
              onPressed: onAdd,
            ),
          ),
        ],
      ),
    );
  }
}

class _TerminalView extends StatefulWidget {
  final Terminal terminal;
  const _TerminalView({super.key, required this.terminal});

  @override
  State<_TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<_TerminalView> {
  final TerminalController _ctrl = TerminalController();

  /// Sticky-modifier state. When armed, the next keystroke routed through
  /// the Terminal's onOutput (soft keyboard or toolbar) has Ctrl applied,
  /// then auto-disarms. Termux-style.
  bool _ctrlArmed = false;
  void Function(String)? _origOnOutput;

  @override
  void initState() {
    super.initState();
    _origOnOutput = widget.terminal.onOutput;
    widget.terminal.onOutput = _onOutputProxy;
  }

  @override
  void dispose() {
    // Be defensive: only restore if we're still the installed proxy. If
    // some other layer rewired onOutput between init and now, leave it
    // alone — touching it would clobber their handler.
    if (widget.terminal.onOutput == _onOutputProxy) {
      widget.terminal.onOutput = _origOnOutput;
    }
    _ctrl.dispose();
    super.dispose();
  }

  /// Intercepts every byte heading to the PTY. When Ctrl is armed, swap
  /// a single ASCII letter / [\]^_ / ? for its control byte and disarm.
  /// Multi-byte sequences (escape codes from arrow toolbar buttons, etc.)
  /// pass through — the toolbar path already applied ctrl via keyInput.
  void _onOutputProxy(String data) {
    if (_ctrlArmed) {
      final transformed = _ctrlMaybeTransform(data);
      _origOnOutput?.call(transformed);
      if (mounted) setState(() => _ctrlArmed = false);
      return;
    }
    _origOnOutput?.call(data);
  }

  String _ctrlMaybeTransform(String data) {
    if (data.length != 1) return data;
    final c = data.codeUnitAt(0);
    // A-Z / a-z → 0x01-0x1a
    if (c >= 0x41 && c <= 0x5a) return String.fromCharCode(c - 0x40);
    if (c >= 0x61 && c <= 0x7a) return String.fromCharCode(c - 0x60);
    // [ \ ] ^ _ → 0x1b-0x1f
    if (c >= 0x5b && c <= 0x5f) return String.fromCharCode(c - 0x40);
    // ? → 0x7f (DEL), matches Termux / typical xterm behavior.
    if (c == 0x3f) return String.fromCharCode(0x7f);
    return data;
  }

  void _toggleCtrl() {
    setState(() => _ctrlArmed = !_ctrlArmed);
  }

  void _sendKey(TerminalKey key) {
    widget.terminal.keyInput(key, ctrl: _ctrlArmed);
    if (_ctrlArmed && mounted) {
      setState(() => _ctrlArmed = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: TerminalView(
            widget.terminal,
            controller: _ctrl,
            autofocus: true,
            backgroundOpacity: 1.0,
          ),
        ),
        _KeyToolbar(
          ctrlArmed: _ctrlArmed,
          onCtrl: _toggleCtrl,
          onKey: _sendKey,
        ),
      ],
    );
  }
}

/// Soft-keyboard companion: a horizontally scrollable strip of keys the
/// Android soft keyboard doesn't surface easily — Esc, Tab, arrows, Home,
/// End. Ctrl is a sticky modifier; tap once to arm, the next key
/// (toolbar or soft keyboard) applies Ctrl and auto-disarms.
class _KeyToolbar extends StatelessWidget {
  final bool ctrlArmed;
  final VoidCallback onCtrl;
  final void Function(TerminalKey) onKey;
  const _KeyToolbar({
    required this.ctrlArmed,
    required this.onCtrl,
    required this.onKey,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            children: [
              _KeyBtn(label: 'Esc', onTap: () => onKey(TerminalKey.escape)),
              _KeyBtn(label: 'Tab', onTap: () => onKey(TerminalKey.tab)),
              _KeyBtn(
                label: 'Ctrl',
                onTap: onCtrl,
                highlighted: ctrlArmed,
              ),
              _KeyBtn(label: '←', onTap: () => onKey(TerminalKey.arrowLeft)),
              _KeyBtn(label: '→', onTap: () => onKey(TerminalKey.arrowRight)),
              _KeyBtn(label: '↑', onTap: () => onKey(TerminalKey.arrowUp)),
              _KeyBtn(label: '↓', onTap: () => onKey(TerminalKey.arrowDown)),
              _KeyBtn(label: 'Home', onTap: () => onKey(TerminalKey.home)),
              _KeyBtn(label: 'End', onTap: () => onKey(TerminalKey.end)),
              _KeyBtn(label: 'PgUp', onTap: () => onKey(TerminalKey.pageUp)),
              _KeyBtn(label: 'PgDn', onTap: () => onKey(TerminalKey.pageDown)),
              _KeyBtn(label: 'Del', onTap: () => onKey(TerminalKey.delete)),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool highlighted;
  const _KeyBtn({
    required this.label,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final padding = const EdgeInsets.symmetric(horizontal: 12);
    final minSize = const Size(40, 36);
    final density = VisualDensity.compact;
    final text = Text(label, style: const TextStyle(fontSize: 13));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: highlighted
          ? FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                padding: padding,
                visualDensity: density,
                minimumSize: minSize,
              ),
              child: text,
            )
          : OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                padding: padding,
                visualDensity: density,
                minimumSize: minSize,
              ),
              child: text,
            ),
    );
  }
}
