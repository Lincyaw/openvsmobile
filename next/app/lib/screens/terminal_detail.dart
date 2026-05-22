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
import '../models.dart';
import '../services/terminal_gesture_host.dart';
import '../ui/app_tokens.dart';

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
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final terminal = appState.terminalFor(sessionId);
        final generation = appState.terminalGenerationFor(sessionId);
        TerminalSession? session;
        for (final t in appState.currentTerminals) {
          if (t.id == sessionId) {
            session = t;
            break;
          }
        }
        final externalName = session?.externalSessionId;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (externalName != null)
                  Text(
                    'zellij attach $externalName',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                          fontFamily: 'monospace',
                        ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
            titleSpacing: 0,
          ),
          body: TerminalSessionView(
            key: ValueKey('$sessionId#$generation'),
            terminal: terminal,
          ),
        );
      },
    );
  }
}

/// xterm.dart TerminalView + the soft-keyboard companion key strip + the
/// gesture host that owns pointer interpretation. Kept outside
/// TerminalDetailScreen so the underlying state (sticky Ctrl flag,
/// output interceptor wiring) survives focus changes that only rebuild
/// the outer Scaffold.
class TerminalSessionView extends StatefulWidget {
  final Terminal terminal;
  const TerminalSessionView({super.key, required this.terminal});

  @override
  State<TerminalSessionView> createState() => _TerminalSessionViewState();
}

class _TerminalSessionViewState extends State<TerminalSessionView> {
  final TerminalController _ctrl = TerminalController();
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  final ScrollController _scrollback = ScrollController();
  final TerminalScrollbackModel _scrollbackModel = TerminalScrollbackModel();
  VoidCallback? _forceSelectAtCursor;

  /// Sticky-modifier state. When armed, the next keystroke routed through
  /// the Terminal's onOutput (soft keyboard or toolbar) has Ctrl applied,
  /// then auto-disarms. Termux-style.
  bool _ctrlArmed = false;
  void Function(String)? _origOnOutput;

  AnimationStatusListener? _routeAnimListener;
  Animation<double>? _watchedRouteAnim;

  @override
  void initState() {
    super.initState();
    _origOnOutput = widget.terminal.onOutput;
    widget.terminal.onOutput = _onOutputProxy;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Still needed: even though our RawGestureDetector now wins the arena
    // cleanly, the *first* touch after the route animation also drives
    // soft-keyboard show, and we want the focus already attached when
    // the user starts typing. Without this the first tap-to-focus is
    // observed to drop occasionally on slow devices. Cheap to keep.
    final route = ModalRoute.of(context);
    final anim = route?.animation;
    if (anim == _watchedRouteAnim) return;
    if (_watchedRouteAnim != null && _routeAnimListener != null) {
      _watchedRouteAnim!.removeStatusListener(_routeAnimListener!);
    }
    _watchedRouteAnim = anim;
    if (anim == null) {
      _requestKeyboardAfterTransition();
      return;
    }
    if (anim.status == AnimationStatus.completed) {
      _requestKeyboardAfterTransition();
      return;
    }
    _routeAnimListener = (status) {
      if (status == AnimationStatus.completed) {
        anim.removeStatusListener(_routeAnimListener!);
        _routeAnimListener = null;
        _requestKeyboardAfterTransition();
      }
    };
    anim.addStatusListener(_routeAnimListener!);
  }

  void _requestKeyboardAfterTransition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _terminalViewKey.currentState?.requestKeyboard();
    });
  }

  @override
  void dispose() {
    if (_watchedRouteAnim != null && _routeAnimListener != null) {
      _watchedRouteAnim!.removeStatusListener(_routeAnimListener!);
    }
    if (widget.terminal.onOutput == _onOutputProxy) {
      widget.terminal.onOutput = _origOnOutput;
    }
    _scrollback.dispose();
    _scrollbackModel.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  /// Intercepts every byte heading to the PTY. When Ctrl is armed, swap
  /// a single ASCII letter / [\]^_ / ? for its control byte and disarm.
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
    if (c >= 0x41 && c <= 0x5a) return String.fromCharCode(c - 0x40);
    if (c >= 0x61 && c <= 0x7a) return String.fromCharCode(c - 0x60);
    if (c >= 0x5b && c <= 0x5f) return String.fromCharCode(c - 0x40);
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

  void _forceSelect() {
    _forceSelectAtCursor?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: TerminalGestureHost(
            terminal: widget.terminal,
            terminalController: _ctrl,
            terminalViewKey: _terminalViewKey,
            scrollback: _scrollbackModel,
            scrollbackController: _scrollback,
            registerForceSelect: (cb) => _forceSelectAtCursor = cb,
            child: TerminalView(
              widget.terminal,
              key: _terminalViewKey,
              controller: _ctrl,
              scrollController: _scrollback,
              autofocus: false,
              backgroundOpacity: 1.0,
              // simulateScroll stays off — our host emits the right key
              // / wheel events itself; leaving xterm's simulation
              // enabled would only matter if its inner Scrollable saw
              // pointer input, which it no longer does (host wins arena).
              simulateScroll: false,
              textStyle: const TerminalStyle(
                fontFamily: 'JetBrainsMonoNF',
                fontFamilyFallback: ['monospace'],
              ),
            ),
          ),
        ),
        _KeyToolbar(
          ctrlArmed: _ctrlArmed,
          onCtrl: _toggleCtrl,
          onKey: _sendKey,
          onForceSelect: _forceSelect,
        ),
      ],
    );
  }
}

class _KeyToolbar extends StatelessWidget {
  final bool ctrlArmed;
  final VoidCallback onCtrl;
  final void Function(TerminalKey) onKey;
  final VoidCallback onForceSelect;
  const _KeyToolbar({
    required this.ctrlArmed,
    required this.onCtrl,
    required this.onKey,
    required this.onForceSelect,
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
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: AppSpacing.xs,
            ),
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
              // Force-select entry point for mouseReport modes where
              // long-press is reserved for the running TUI.
              _KeyBtn(label: 'Sel', onTap: onForceSelect),
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
    const padding = EdgeInsets.symmetric(horizontal: AppSpacing.md);
    const minSize = Size(40, 36);
    const density = VisualDensity.compact;
    final text = Text(label, style: Theme.of(context).textTheme.labelMedium);
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
