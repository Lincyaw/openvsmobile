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

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../app_state.dart';
import '../services/terminal_gesture_host.dart';
import '../settings_store.dart';
import '../state/terminal_hub.dart';
import '../ui/app_tokens.dart';

class TerminalDetailScreen extends StatelessWidget {
  final AppState? appState;
  final TerminalHub? terminalHub;
  final String? backendId;
  final SettingsStore? settingsStore;
  final String sessionId;
  final String title;
  final Future<void> Function()? onOpenFiles;

  const TerminalDetailScreen({
    super.key,
    this.appState,
    this.terminalHub,
    this.backendId,
    this.settingsStore,
    required this.sessionId,
    required this.title,
    this.onOpenFiles,
  }) : assert(
         appState != null || (terminalHub != null && backendId != null),
         'TerminalDetailScreen needs AppState or TerminalHub + backendId.',
       );

  @override
  Widget build(BuildContext context) {
    final listenable = terminalHub ?? appState!;
    return AnimatedBuilder(
      animation: listenable,
      builder: (context, _) {
        final hub = terminalHub;
        final bid = backendId;
        final terminal = hub == null
            ? appState!.terminalForIfKnown(sessionId)
            : hub.terminalForIfKnown(bid!, sessionId);
        final generation = hub == null
            ? appState!.terminalGenerationFor(sessionId)
            : hub.terminalGenerationFor(bid!, sessionId);
        final session = hub == null
            ? appState!.terminalSessionFor(sessionId)
            : hub.sessionFor(bid!, sessionId)?.session;
        final externalName = session?.externalSessionId;
        final canOpenFiles = session?.workspaceRoot != null;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
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
            actions: [
              if (canOpenFiles)
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  tooltip: 'Open Files',
                  onPressed: onOpenFiles == null
                      ? null
                      : () async {
                          await onOpenFiles!();
                          if (context.mounted &&
                              Navigator.of(context).canPop()) {
                            Navigator.of(context).pop();
                          }
                        },
                ),
            ],
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

class _TerminalSessionViewState extends State<TerminalSessionView>
    with WidgetsBindingObserver {
  final TerminalController _ctrl = TerminalController();
  final FocusNode _terminalFocus = FocusNode(debugLabel: 'terminal-session');
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  final ScrollController _scrollback = ScrollController();
  final TerminalScrollbackModel _scrollbackModel = TerminalScrollbackModel();

  /// Sticky-modifier state. When armed, the next soft-keyboard character
  /// has Ctrl / Alt applied, then the modifier auto-disarms. Termux-style.
  bool _ctrlArmed = false;
  bool _altArmed = false;

  /// Set while the key bar itself calls `keyInput` with the modifiers
  /// already applied, so [_onOutputProxy] does not apply them twice.
  bool _modifiersApplied = false;

  /// Mirrors the IME's on-screen state so the key bar's keyboard button
  /// can toggle rather than only open.
  bool _keyboardVisible = false;
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
    WidgetsBinding.instance.addObserver(this);
    _loadTerminalPrefs();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final visible = View.of(context).viewInsets.bottom > 0;
    if (visible != _keyboardVisible) {
      setState(() => _keyboardVisible = visible);
    }
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
    WidgetsBinding.instance.removeObserver(this);
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

  /// Intercepts every byte heading to the PTY and applies armed sticky
  /// modifiers to the next typed character.
  ///
  /// onOutput also carries traffic the user did not type: mouse clicks,
  /// wheel events from swipes, and the terminal's own replies to queries
  /// (DA, DSR). All of those are escape sequences, so anything starting
  /// with ESC passes through untouched and leaves the modifier armed.
  void _onOutputProxy(String data) {
    final armed = _ctrlArmed || _altArmed;
    if (!armed ||
        _modifiersApplied ||
        data.isEmpty ||
        data.codeUnitAt(0) == 0x1b) {
      _origOnOutput?.call(data);
      return;
    }
    var out = _ctrlArmed ? _ctrlMaybeTransform(data) : data;
    if (_altArmed && data.length == 1) out = '\x1b$out';
    _origOnOutput?.call(out);
    _disarmModifiers();
  }

  void _disarmModifiers() {
    if (!_ctrlArmed && !_altArmed) return;
    if (!mounted) {
      _ctrlArmed = _altArmed = false;
      return;
    }
    setState(() => _ctrlArmed = _altArmed = false);
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

  // Key-bar keys never touch keyboard visibility: a user who hid the IME
  // to read output must be able to page with PgUp / arrows without the
  // keyboard popping back and resizing the PTY.
  void _toggleCtrl() => setState(() => _ctrlArmed = !_ctrlArmed);

  void _toggleAlt() => setState(() => _altArmed = !_altArmed);

  void _sendKey(TerminalKey key, {bool shift = false}) {
    _modifiersApplied = true;
    try {
      widget.terminal.keyInput(
        key,
        shift: shift,
        ctrl: _ctrlArmed,
        alt: _altArmed,
      );
    } finally {
      _modifiersApplied = false;
    }
    _disarmModifiers();
  }

  void _toggleKeyboard() {
    if (_keyboardVisible) {
      _terminalViewKey.currentState?.closeKeyboard();
    } else {
      _requestTerminalKeyboard();
    }
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
          altArmed: _altArmed,
          keyboardVisible: _keyboardVisible,
          onCtrl: _toggleCtrl,
          onAlt: _toggleAlt,
          onKey: _sendKey,
          onKeyboard: _toggleKeyboard,
        ),
      ],
    );
  }
}

// Key-bar geometry. Rows are 40dp so each key keeps a ~36dp touch target
// while the bar stays two rows tall above the IME.
const double _kKeyRowHeight = 40;
const double _kDpadCell = 40;

class _KeyToolbar extends StatelessWidget {
  final bool ctrlArmed;
  final bool altArmed;
  final bool keyboardVisible;
  final VoidCallback onCtrl;
  final VoidCallback onAlt;
  final void Function(TerminalKey key, {bool shift}) onKey;
  final VoidCallback onKeyboard;
  const _KeyToolbar({
    required this.ctrlArmed,
    required this.altArmed,
    required this.keyboardVisible,
    required this.onCtrl,
    required this.onAlt,
    required this.onKey,
    required this.onKeyboard,
  });

  @override
  Widget build(BuildContext context) {
    // Two rows of non-arrow keys on the left (modifiers lead), with the
    // arrows in a keyboard-style inverted-T d-pad pinned to the right.
    // Keys that users hold (arrows, Del, PgUp/PgDn) auto-repeat.
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
                        label: 'Esc',
                        onTap: () => onKey(TerminalKey.escape),
                      ),
                      _KeyBtn(
                        label: 'Ctrl',
                        onTap: onCtrl,
                        highlighted: ctrlArmed,
                      ),
                      _KeyBtn(
                        label: 'Alt',
                        onTap: onAlt,
                        highlighted: altArmed,
                      ),
                      _KeyBtn(
                        label: 'Tab',
                        onTap: () => onKey(TerminalKey.tab),
                      ),
                      _KeyBtn(
                        label: '⇧Tab',
                        semanticLabel: 'Shift Tab',
                        onTap: () => onKey(TerminalKey.tab, shift: true),
                      ),
                    ],
                  ),
                  _KeyRow(
                    children: [
                      _KeyBtn(
                        label: 'Home',
                        onTap: () => onKey(TerminalKey.home),
                      ),
                      _KeyBtn(
                        label: 'End',
                        onTap: () => onKey(TerminalKey.end),
                      ),
                      _KeyBtn(
                        label: 'PgUp',
                        repeat: true,
                        onTap: () => onKey(TerminalKey.pageUp),
                      ),
                      _KeyBtn(
                        label: 'PgDn',
                        repeat: true,
                        onTap: () => onKey(TerminalKey.pageDown),
                      ),
                      _KeyBtn(
                        label: 'Del',
                        repeat: true,
                        onTap: () => onKey(TerminalKey.delete),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: _DPad(
                onKey: onKey,
                keyboardVisible: keyboardVisible,
                onKeyboard: onKeyboard,
              ),
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
      height: _kKeyRowHeight,
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

/// Keyboard-style arrow cluster: `↑` on top, `← ↓ →` below, every slot a
/// fixed-width cell so `↑` sits exactly above `↓`. The free top-left slot
/// holds the show/hide-keyboard toggle.
class _DPad extends StatelessWidget {
  final void Function(TerminalKey key, {bool shift}) onKey;
  final bool keyboardVisible;
  final VoidCallback onKeyboard;
  const _DPad({
    required this.onKey,
    required this.keyboardVisible,
    required this.onKeyboard,
  });

  Widget _arrow(String label, String semantic, TerminalKey key) => SizedBox(
    width: _kDpadCell,
    child: _KeyBtn(
      label: label,
      semanticLabel: semantic,
      repeat: true,
      onTap: () => onKey(key),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: _kKeyRowHeight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: _kDpadCell,
                child: _KeyBtn(
                  key: const ValueKey('terminal-keyboard-toggle'),
                  icon: keyboardVisible ? Icons.keyboard_hide : Icons.keyboard,
                  semanticLabel: keyboardVisible
                      ? 'Hide keyboard'
                      : 'Show keyboard',
                  onTap: onKeyboard,
                ),
              ),
              _arrow('↑', 'Up', TerminalKey.arrowUp),
              const SizedBox(width: _kDpadCell),
            ],
          ),
        ),
        SizedBox(
          height: _kKeyRowHeight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _arrow('←', 'Left', TerminalKey.arrowLeft),
              _arrow('↓', 'Down', TerminalKey.arrowDown),
              _arrow('→', 'Right', TerminalKey.arrowRight),
            ],
          ),
        ),
      ],
    );
  }
}

/// A key-bar button. With [repeat], holding it fires [onTap] repeatedly
/// after a short delay, like a hardware key.
class _KeyBtn extends StatefulWidget {
  final String? label;
  final IconData? icon;
  final String? semanticLabel;
  final VoidCallback onTap;
  final bool highlighted;
  final bool repeat;
  const _KeyBtn({
    super.key,
    this.label,
    this.icon,
    this.semanticLabel,
    required this.onTap,
    this.highlighted = false,
    this.repeat = false,
  }) : assert(label != null || icon != null);

  @override
  State<_KeyBtn> createState() => _KeyBtnState();
}

class _KeyBtnState extends State<_KeyBtn> {
  static const _repeatDelay = Duration(milliseconds: 350);
  static const _repeatInterval = Duration(milliseconds: 60);

  Timer? _repeatTimer;

  void _handleTap() {
    HapticFeedback.selectionClick();
    widget.onTap();
  }

  void _startRepeat() {
    _handleTap();
    _repeatTimer?.cancel();
    _repeatTimer = Timer.periodic(_repeatInterval, (_) => widget.onTap());
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  @override
  void dispose() {
    _stopRepeat();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const padding = EdgeInsets.symmetric(horizontal: 6);
    const minSize = Size(36, 36);
    const density = VisualDensity.compact;
    final Widget content = widget.icon != null
        ? Icon(widget.icon, size: 18)
        : Text(widget.label!, style: Theme.of(context).textTheme.labelMedium);
    Widget button = widget.highlighted
        ? FilledButton(
            onPressed: _handleTap,
            style: FilledButton.styleFrom(
              padding: padding,
              visualDensity: density,
              minimumSize: minSize,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: content,
          )
        : OutlinedButton(
            onPressed: _handleTap,
            style: OutlinedButton.styleFrom(
              padding: padding,
              visualDensity: density,
              minimumSize: minSize,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: content,
          );
    if (widget.repeat) {
      // A long-press recognizer beside the button's tap recognizer: a
      // quick tap still wins as a single press, holding past the delay
      // switches to auto-repeat until the finger lifts.
      button = RawGestureDetector(
        gestures: <Type, GestureRecognizerFactory>{
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(duration: _repeatDelay),
                (r) {
                  r.onLongPressStart = (_) => _startRepeat();
                  r.onLongPressEnd = (_) => _stopRepeat();
                  r.onLongPressCancel = _stopRepeat;
                },
              ),
        },
        child: button,
      );
    }
    if (widget.semanticLabel != null) {
      button = Semantics(
        label: widget.semanticLabel,
        excludeSemantics: true,
        button: true,
        child: button,
      );
    }
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: button,
      ),
    );
  }
}
