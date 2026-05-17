// Full-screen terminal detail view. Pushed as a root-level MaterialPageRoute
// from the Terminal-tab session list, so the home shell's bottom nav and
// workspace chooser are not in the widget tree — both naturally disappear.
// System back pops this route and returns the user to the session list.
//
// PTY lifecycle is unchanged — popping the detail view does NOT call
// terminal.dispose; the live `Terminal` instance comes from
// `AppState.terminalFor`, which keeps it across rebuilds so scrollback
// survives.

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';

class TerminalDetailScreen extends StatelessWidget {
  final AppState appState;
  final String sessionId;
  final String title;

  const TerminalDetailScreen({
    super.key,
    required this.appState,
    required this.sessionId,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    // Listenable.merge so the screen rebuilds both when AppState fires
    // (focus or session list change) and when the session's underlying
    // Terminal generation bumps (reconnect history replay). The TerminalView
    // itself listens to the Terminal directly.
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final terminal = appState.terminalFor(sessionId);
        final generation = appState.terminalGenerationFor(sessionId);
        return Scaffold(
          appBar: AppBar(
            // Default leading is the system back button — that's the
            // "slim back affordance" the brief calls for.
            title: Text(
              title,
              style: const TextStyle(fontSize: 16),
            ),
            titleSpacing: 0,
          ),
          body: TerminalSessionView(
            // ValueKey forces a fresh state when the underlying Terminal is
            // swapped (e.g. after a reconnect-replay).
            key: ValueKey('$sessionId#$generation'),
            terminal: terminal,
          ),
        );
      },
    );
  }
}

/// xterm.dart TerminalView + the soft-keyboard companion key strip. Kept
/// outside TerminalDetailScreen so the underlying state (sticky Ctrl flag,
/// output interceptor wiring) survives focus changes that only rebuild the
/// outer Scaffold.
class TerminalSessionView extends StatefulWidget {
  final Terminal terminal;
  const TerminalSessionView({super.key, required this.terminal});

  @override
  State<TerminalSessionView> createState() => _TerminalSessionViewState();
}

class _TerminalSessionViewState extends State<TerminalSessionView> {
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
    const padding = EdgeInsets.symmetric(horizontal: 12);
    const minSize = Size(40, 36);
    const density = VisualDensity.compact;
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
