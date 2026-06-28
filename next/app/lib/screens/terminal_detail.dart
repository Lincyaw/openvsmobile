// Full-screen terminal detail view. Pushed as a root-level MaterialPageRoute
// from the Terminal-tab session list, so the home shell's bottom nav and
// workspace chooser are not in the widget tree — both naturally disappear.
// System back pops this route and returns the user to the session list.
//
// PTY lifecycle is unchanged — popping the detail view does NOT call
// terminal.dispose; the live `Terminal` instance comes from
// `AppState.terminalFor`, which keeps it across rebuilds so scrollback
// survives.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';
import '../services/terminal_gesture_host.dart';
import '../settings_store.dart';
import '../ui/app_tokens.dart';

class TerminalDetailScreen extends StatelessWidget {
  final AppState appState;
  final SettingsStore? settingsStore;
  final String sessionId;
  final String title;

  const TerminalDetailScreen({
    super.key,
    required this.appState,
    this.settingsStore,
    required this.sessionId,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final terminal = appState.terminalForIfKnown(sessionId);
        final generation = appState.terminalGenerationFor(sessionId);
        final session = appState.terminalSessionFor(sessionId);
        final externalName = session?.externalSessionId;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                if (externalName != null)
                  Text(
                    'zellij attach $externalName',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
            titleSpacing: 0,
          ),
          body: terminal == null
              ? const _TerminalEndedView()
              : TerminalSessionView(
                  key: ValueKey('$sessionId#$generation'),
                  terminal: terminal,
                  settingsStore: settingsStore,
                ),
        );
      },
    );
  }
}

class _TerminalEndedView extends StatelessWidget {
  const _TerminalEndedView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.power_settings_new,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Terminal session ended.',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton(
              onPressed: () {
                final nav = Navigator.of(context);
                if (nav.canPop()) nav.pop();
              },
              child: const Text('Back to sessions'),
            ),
          ],
        ),
      ),
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
  final SettingsStore? settingsStore;
  const TerminalSessionView({
    super.key,
    required this.terminal,
    this.settingsStore,
  });

  @override
  State<TerminalSessionView> createState() => _TerminalSessionViewState();
}

class _TerminalSessionViewState extends State<TerminalSessionView> {
  final TerminalController _ctrl = TerminalController();
  final FocusNode _terminalFocus = FocusNode(debugLabel: 'terminal-session');
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  final ScrollController _scrollback = ScrollController();
  final TerminalScrollbackModel _scrollbackModel = TerminalScrollbackModel();
  VoidCallback? _forceSelectAtCursor;

  /// Sticky-modifier state. When armed, the next keystroke routed through
  /// the Terminal's onOutput (soft keyboard or toolbar) has Ctrl applied,
  /// then auto-disarms. Termux-style.
  bool _ctrlArmed = false;
  double _terminalFontSize = kTerminalFontSizeDefault;
  void Function(String)? _origOnOutput;
  Timer? _fontSaveTimer;

  AnimationStatusListener? _routeAnimListener;
  Animation<double>? _watchedRouteAnim;

  @override
  void initState() {
    super.initState();
    _origOnOutput = widget.terminal.onOutput;
    widget.terminal.onOutput = _onOutputProxy;
    _loadTerminalPrefs();
  }

  @override
  void didUpdateWidget(covariant TerminalSessionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settingsStore != widget.settingsStore) {
      _loadTerminalPrefs();
    }
  }

  Future<void> _loadTerminalPrefs() async {
    final store = widget.settingsStore;
    if (store == null) return;
    final prefs = await store.loadTerminalPrefs();
    if (!mounted) return;
    setState(() => _terminalFontSize = prefs.fontSize);
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
      _requestTerminalKeyboard();
    });
  }

  void _requestTerminalKeyboard() {
    _terminalFocus.requestFocus();
    _terminalViewKey.currentState?.requestKeyboard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _terminalFocus.requestFocus();
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
    _fontSaveTimer?.cancel();
    _scrollback.dispose();
    _scrollbackModel.dispose();
    _terminalFocus.dispose();
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
    _requestTerminalKeyboard();
  }

  void _sendKey(TerminalKey key) {
    widget.terminal.keyInput(key, ctrl: _ctrlArmed);
    if (_ctrlArmed && mounted) {
      setState(() => _ctrlArmed = false);
    }
    _requestTerminalKeyboard();
  }

  void _forceSelect() {
    _forceSelectAtCursor?.call();
  }

  void _scaleFont(double factor) {
    if (!factor.isFinite || factor <= 0) return;
    final next = clampTerminalFontSize(_terminalFontSize * factor);
    if ((next - _terminalFontSize).abs() < 0.05) return;
    setState(() => _terminalFontSize = next);
    _scheduleSaveTerminalPrefs();
  }

  void _scheduleSaveTerminalPrefs() {
    final store = widget.settingsStore;
    if (store == null) return;
    _fontSaveTimer?.cancel();
    _fontSaveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(
        store.saveTerminalPrefs(TerminalPrefs(fontSize: _terminalFontSize)),
      );
    });
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
            requestKeyboard: _requestTerminalKeyboard,
            onFontScale: _scaleFont,
            child: TerminalView(
              widget.terminal,
              key: _terminalViewKey,
              controller: _ctrl,
              scrollController: _scrollback,
              focusNode: _terminalFocus,
              autofocus: false,
              backgroundOpacity: 1.0,
              // simulateScroll stays off — our host emits the right key
              // / wheel events itself; leaving xterm's simulation
              // enabled would only matter if its inner Scrollable saw
              // pointer input, which it no longer does (host wins arena).
              simulateScroll: false,
              textStyle: TerminalStyle(
                fontSize: _terminalFontSize,
                fontFamily: 'JetBrainsMonoNF',
                fontFamilyFallback: const ['monospace'],
              ),
            ),
          ),
        ),
        _KeyToolbar(
          ctrlArmed: _ctrlArmed,
          onCtrl: _toggleCtrl,
          onKey: _sendKey,
          onKeyboard: _requestTerminalKeyboard,
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
  final VoidCallback onKeyboard;
  final VoidCallback onForceSelect;
  const _KeyToolbar({
    required this.ctrlArmed,
    required this.onCtrl,
    required this.onKey,
    required this.onKeyboard,
    required this.onForceSelect,
  });

  @override
  Widget build(BuildContext context) {
    // Two rows of non-arrow keys on the left (Ctrl leads), with the four
    // arrows pulled out into a keyboard-style inverted-T d-pad pinned to
    // the right so the cluster reads like a physical arrow key block.
    return Material(
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _KeyRow(
                    children: [
                      _KeyBtn(
                        label: 'Ctrl',
                        onTap: onCtrl,
                        highlighted: ctrlArmed,
                      ),
                      _KeyBtn(
                        label: 'Tab',
                        onTap: () => onKey(TerminalKey.tab),
                      ),
                      _KeyBtn(
                        label: 'Esc',
                        onTap: () => onKey(TerminalKey.escape),
                      ),
                      _KeyBtn(
                        label: 'Home',
                        onTap: () => onKey(TerminalKey.home),
                      ),
                      _KeyBtn(
                        label: 'End',
                        onTap: () => onKey(TerminalKey.end),
                      ),
                    ],
                  ),
                  _KeyRow(
                    children: [
                      _KeyBtn(
                        label: 'PgUp',
                        onTap: () => onKey(TerminalKey.pageUp),
                      ),
                      _KeyBtn(
                        label: 'PgDn',
                        onTap: () => onKey(TerminalKey.pageDown),
                      ),
                      _KeyBtn(
                        label: 'Del',
                        onTap: () => onKey(TerminalKey.delete),
                      ),
                      // Explicit selection entry point for users who prefer
                      // the companion bar over long-press.
                      _KeyBtn(label: 'Sel', onTap: onForceSelect),
                      _KeyBtn(label: 'Kbd', onTap: onKeyboard),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: _DPad(onKey: onKey),
            ),
          ],
        ),
      ),
    );
  }
}

/// One horizontally-scrollable row of companion keys. Two of these stack in
/// [_KeyToolbar]; per-row scrolling keeps the strip from overflowing on
/// narrow screens while normally showing every key without a scroll.
class _KeyRow extends StatelessWidget {
  final List<Widget> children;
  const _KeyRow({required this.children});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 31,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: 2,
        ),
        children: children,
      ),
    );
  }
}

/// Keyboard-style arrow cluster: `↑` on top, `← ↓ →` below. Every slot is a
/// fixed-width cell (empty slots flank the top arrow) so `↑` sits exactly
/// above `↓`. Two rows of [_kDpadRowHeight] match the two left-hand
/// [_KeyRow]s, keeping the toolbar a uniform height.
class _DPad extends StatelessWidget {
  final void Function(TerminalKey) onKey;
  const _DPad({required this.onKey});

  static const double _cell = 35;
  static const double _kDpadRowHeight = 31;

  Widget _btn(String label, TerminalKey key) => SizedBox(
    width: _cell,
    child: _KeyBtn(label: label, onTap: () => onKey(key)),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: _kDpadRowHeight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: _cell),
              _btn('↑', TerminalKey.arrowUp),
              const SizedBox(width: _cell),
            ],
          ),
        ),
        SizedBox(
          height: _kDpadRowHeight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _btn('←', TerminalKey.arrowLeft),
              _btn('↓', TerminalKey.arrowDown),
              _btn('→', TerminalKey.arrowRight),
            ],
          ),
        ),
      ],
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

  void _handleTap() {
    HapticFeedback.selectionClick();
    onTap();
  }

  @override
  Widget build(BuildContext context) {
    const padding = EdgeInsets.symmetric(horizontal: 7);
    const minSize = Size(29, 25);
    const density = VisualDensity.compact;
    final text = Text(label, style: Theme.of(context).textTheme.labelSmall);
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: highlighted
            ? FilledButton(
                onPressed: _handleTap,
                style: FilledButton.styleFrom(
                  padding: padding,
                  visualDensity: density,
                  minimumSize: minSize,
                ),
                child: text,
              )
            : OutlinedButton(
                onPressed: _handleTap,
                style: OutlinedButton.styleFrom(
                  padding: padding,
                  visualDensity: density,
                  minimumSize: minSize,
                ),
                child: text,
              ),
      ),
    );
  }
}
