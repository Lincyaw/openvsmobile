// App-wide floating observability overlay. Mounted once in `MaterialApp`'s
// `builder` so it floats over every screen (including pushed routes like the
// terminal detail view). Self-hides unless the `debug-overlay` Settings
// switch is on.
//
// The panel is drawn in-place (not via showModalBottomSheet) because the
// overlay lives above the app's Navigator and therefore has no Navigator /
// Overlay ancestor to host a route. Tapping the scrim or the X dismisses it.
//
// Lets the user watch a live [DiagLog] stream, drop their own markers, and
// record + tag windows of activity for export.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/diag_log.dart';
import '../ui/app_tokens.dart';

class DiagOverlay extends StatefulWidget {
  const DiagOverlay({super.key});

  @override
  State<DiagOverlay> createState() => _DiagOverlayState();
}

class _DiagOverlayState extends State<DiagOverlay> {
  Offset? _pos; // button top-left, seeded to bottom-right on first layout
  bool _open = false;
  static const double _btnSize = 48;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DiagLog.instance,
      builder: (context, _) {
        if (!DiagLog.instance.enabled) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (context, constraints) {
            if (_open) {
              return _DiagPanel(onClose: () => setState(() => _open = false));
            }
            final maxX = constraints.maxWidth - _btnSize;
            final maxY = constraints.maxHeight - _btnSize;
            final pos = _pos ??= Offset(maxX - 8, maxY - 96);
            final clamped = Offset(
              pos.dx.clamp(0, maxX > 0 ? maxX : 0),
              pos.dy.clamp(0, maxY > 0 ? maxY : 0),
            );
            // Only the button is a child; empty areas of this Stack fall
            // through to the app below.
            return Stack(
              children: [
                Positioned(
                  left: clamped.dx,
                  top: clamped.dy,
                  child: _DragButton(
                    size: _btnSize,
                    onTap: () => setState(() => _open = true),
                    onDrag: (delta) =>
                        setState(() => _pos = (_pos ?? clamped) + delta),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _DragButton extends StatelessWidget {
  const _DragButton({
    required this.size,
    required this.onTap,
    required this.onDrag,
  });

  final double size;
  final VoidCallback onTap;
  final void Function(Offset delta) onDrag;

  @override
  Widget build(BuildContext context) {
    final recording = DiagLog.instance.recording;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onPanUpdate: (d) => onDrag(d.delta),
      child: Material(
        elevation: 6,
        shape: const CircleBorder(),
        color: recording ? scheme.error : scheme.secondaryContainer,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            recording ? Icons.fiber_manual_record : Icons.bug_report_outlined,
            color: recording ? scheme.onError : scheme.onSecondaryContainer,
            size: AppIconSize.md,
          ),
        ),
      ),
    );
  }
}

class _DiagPanel extends StatefulWidget {
  const _DiagPanel({required this.onClose});
  final VoidCallback onClose;

  @override
  State<_DiagPanel> createState() => _DiagPanelState();
}

class _DiagPanelState extends State<_DiagPanel> {
  final ScrollController _logScroll = ScrollController();
  int _markCounter = 0;

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(
      ClipboardData(text: DiagLog.instance.exportText()),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Trace copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final diag = DiagLog.instance;
    final theme = Theme.of(context);
    return Stack(
      children: [
        // Scrim: absorbs touches so the app behind is frozen; tap to close.
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            heightFactor: 0.6,
            child: Material(
              elevation: 8,
              color: theme.colorScheme.surface,
              shape: const RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: SafeArea(
                top: false,
                child: ListenableBuilder(
                  listenable: diag,
                  builder: (context, _) {
                    _autoScroll();
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Header(diag: diag, onClose: widget.onClose),
                          const SizedBox(height: AppSpacing.xs),
                          _ActionBar(
                            diag: diag,
                            onMark: () => diag.mark('mark #${++_markCounter}'),
                          ),
                          _SegmentsBar(diag: diag, onCopyAll: _copyAll),
                          const Divider(height: AppSpacing.md),
                          Expanded(
                            child: _LogList(
                              diag: diag,
                              controller: _logScroll,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.diag, required this.onClose});
  final DiagLog diag;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text('Debug event log', style: theme.textTheme.titleMedium),
        ),
        if (!diag.recording)
          FilledButton.icon(
            onPressed: diag.startRecording,
            icon: const Icon(Icons.fiber_manual_record, size: AppIconSize.sm),
            label: const Text('Record'),
          )
        else ...[
          OutlinedButton(
            onPressed: () => diag.stopRecording('normal'),
            child: const Text('Stop·OK'),
          ),
          const SizedBox(width: AppSpacing.xs),
          FilledButton.tonal(
            onPressed: () => diag.stopRecording('problem'),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.errorContainer,
              foregroundColor: theme.colorScheme.onErrorContainer,
            ),
            child: const Text('Stop·BAD'),
          ),
        ],
        IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
      ],
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.diag, required this.onMark});
  final DiagLog diag;
  final VoidCallback onMark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = diag.recording
        ? 'Recording · ${diag.recordingCount} events'
        : 'Not recording — markers still show live';
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: onMark,
          icon: const Icon(Icons.bookmark_add_outlined, size: AppIconSize.sm),
          label: const Text('Mark'),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            status,
            style: theme.textTheme.bodySmall?.copyWith(
              color: diag.recording
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _SegmentsBar extends StatelessWidget {
  const _SegmentsBar({required this.diag, required this.onCopyAll});
  final DiagLog diag;
  final Future<void> Function() onCopyAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = diag.segments.length;
    final bad = diag.segments.where((s) => s.label == 'problem').length;
    return Row(
      children: [
        Expanded(
          child: Text(
            n == 0
                ? 'No saved segments yet'
                : '$n segment(s) · $bad problem · ${n - bad} other',
            style: theme.textTheme.bodySmall,
          ),
        ),
        TextButton.icon(
          onPressed: n == 0 ? null : () => onCopyAll(),
          icon: const Icon(Icons.copy_all, size: AppIconSize.sm),
          label: const Text('Copy'),
        ),
        TextButton(
          onPressed: n == 0 ? null : diag.clearSegments,
          child: const Text('Clear'),
        ),
      ],
    );
  }
}

class _LogList extends StatelessWidget {
  const _LogList({required this.diag, required this.controller});
  final DiagLog diag;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final entries = diag.live;
    if (entries.isEmpty) {
      return Center(
        child: Text(
          'Interact with the app to capture events.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return ListView.builder(
      controller: controller,
      itemCount: entries.length,
      itemBuilder: (context, i) => _LogRow(entry: entries[i]),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});
  final DiagEntry entry;

  static Color _catColor(String cat, ColorScheme s) => switch (cat) {
    DiagCat.error => s.error,
    DiagCat.mode => s.tertiary,
    DiagCat.resize => s.primary,
    DiagCat.net => s.primary,
    DiagCat.rpc => s.secondary,
    DiagCat.marker => s.secondary,
    DiagCat.terminal => s.onSurface,
    _ => s.onSurfaceVariant,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = DateTime.fromMillisecondsSinceEpoch(entry.tMs);
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final ms = (t.millisecond ~/ 10).toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$hh:$mm:$ss.$ms ',
              style: AppText.mono(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
            TextSpan(
              text: '${entry.category.padRight(5)} ',
              style: AppText.mono(
                fontSize: 11,
                color: _catColor(entry.category, scheme),
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: entry.text,
              style: AppText.mono(
                fontSize: 11,
                color: _catColor(entry.category, scheme),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
