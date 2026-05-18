// Read-only unified-diff viewer. One file at a time, hunks pre-expanded,
// no inline edit affordances (first principle #6: writes stay in the
// terminal; the app observes). Pulled via `git.diff` against HEAD —
// backend computes everything; client renders.
//
// Render rules:
//   * Top bar: `<filename> · +N -M · vs HEAD`.
//   * Body: each hunk is a card with its lines colored:
//       add → tertiaryContainer / onTertiaryContainer
//       del → errorContainer / onErrorContainer
//       context → surface / onSurface
//   * Between hunks: a decorative `... K unchanged lines ...` strip. The
//     `K` is computed from hunk boundaries (newStart of next hunk minus
//     newStart+newLines of previous). It is visual only — tapping does
//     nothing in v0 because the backend does not surface unchanged-line
//     content (and we don't want to fake it).
//   * Binary / oversize diffs render a placeholder card with the reason
//     (issue #55 AC: backend signals these via `isBinary: true` and
//     `tooLarge: true` flags on the response).

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../ui/app_tokens.dart';

/// Signature of the diff fetch the viewer uses. Production wires this to
/// `AppState.gitDiff`; widget tests inject a fake to render against a
/// canned response without spinning up a backend.
typedef GitDiffFn = Future<Map<String, dynamic>> Function({
  required String workspaceId,
  required String path,
});

class DiffViewerScreen extends StatefulWidget {
  final AppState appState;
  final String workspaceId;
  final String path;

  /// Test-only override for the diff RPC. Defaults to `appState.gitDiff`.
  @visibleForTesting
  final GitDiffFn? diffOverride;

  const DiffViewerScreen({
    super.key,
    required this.appState,
    required this.workspaceId,
    required this.path,
    this.diffOverride,
  });

  @override
  State<DiffViewerScreen> createState() => _DiffViewerScreenState();
}

class _DiffViewerScreenState extends State<DiffViewerScreen> {
  Future<Map<String, dynamic>>? _future;

  @override
  void initState() {
    super.initState();
    final fetch = widget.diffOverride ?? widget.appState.gitDiff;
    _future = fetch(
      workspaceId: widget.workspaceId,
      path: widget.path,
    );
  }

  @override
  Widget build(BuildContext context) {
    final filename = widget.path.split('/').last;
    return Scaffold(
      appBar: AppBar(
        title: Text(filename, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Show full path',
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(widget.path)),
              );
            },
          ),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(height: AppSpacing.md),
                  Text('Loading diff…'),
                ],
              ),
            );
          }
          if (snap.hasError) {
            return _DiffErrorView(
              path: widget.path,
              message: '${snap.error}',
            );
          }
          final data = snap.data;
          if (data == null) {
            return _DiffErrorView(
              path: widget.path,
              message: 'No response from backend',
            );
          }
          return _DiffBody(path: widget.path, data: data);
        },
      ),
    );
  }
}

class _DiffBody extends StatelessWidget {
  final String path;
  final Map<String, dynamic> data;
  const _DiffBody({required this.path, required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Backend wire shape (see next/backend/src/rpc.ts `git.diff`):
    //   { hunks, baseSha, headSha, isBinary, tooLarge? }
    // `isBinary` and `tooLarge` are mutually exclusive with a non-empty
    // `hunks`; honour them first so the placeholder always wins.
    final isBinary = data['isBinary'] == true;
    final tooLarge = data['tooLarge'] == true;
    if (isBinary) {
      return _DiffPlaceholder(path: path, kind: 'binary');
    }
    if (tooLarge) {
      return _DiffPlaceholder(path: path, kind: 'too-large');
    }
    final hunksRaw = data['hunks'] as List? ?? const [];
    final hunks = hunksRaw
        .whereType<Map<String, dynamic>>()
        .map(_parseHunk)
        .whereType<_Hunk>()
        .toList(growable: false);
    if (hunks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Text(
            'No changes vs HEAD.',
            style: theme.textTheme.bodyLarge,
          ),
        ),
      );
    }
    int adds = 0;
    int dels = 0;
    for (final h in hunks) {
      for (final l in h.lines) {
        if (l.kind == 'add') adds++;
        if (l.kind == 'del') dels++;
      }
    }
    return Column(
      children: [
        _DiffHeader(path: path, adds: adds, dels: dels),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: AppSpacing.xl),
            itemCount: hunks.length * 2 - 1,
            itemBuilder: (context, i) {
              if (i.isEven) {
                final hunk = hunks[i ~/ 2];
                return _HunkCard(hunk: hunk);
              }
              final prev = hunks[(i - 1) ~/ 2];
              final next = hunks[(i + 1) ~/ 2];
              final gap = next.newStart - (prev.newStart + prev.newLines);
              if (gap <= 0) return const SizedBox.shrink();
              return _GapStrip(unchanged: gap);
            },
          ),
        ),
      ],
    );
  }

  _Hunk? _parseHunk(Map<String, dynamic> m) {
    final oldStart = (m['oldStart'] as num?)?.toInt();
    final oldLines = (m['oldLines'] as num?)?.toInt();
    final newStart = (m['newStart'] as num?)?.toInt();
    final newLines = (m['newLines'] as num?)?.toInt();
    if (oldStart == null ||
        oldLines == null ||
        newStart == null ||
        newLines == null) {
      return null;
    }
    final linesRaw = m['lines'] as List? ?? const [];
    final lines = <_DiffLine>[];
    for (final ln in linesRaw.whereType<Map<String, dynamic>>()) {
      lines.add(_DiffLine(
        kind: ln['kind'] as String? ?? 'context',
        text: ln['text'] as String? ?? '',
      ));
    }
    return _Hunk(
      oldStart: oldStart,
      oldLines: oldLines,
      newStart: newStart,
      newLines: newLines,
      lines: lines,
    );
  }
}

class _DiffHeader extends StatelessWidget {
  final String path;
  final int adds;
  final int dels;
  const _DiffHeader({required this.path, required this.adds, required this.dels});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(
          horizontal: AppDensity.bannerHPad, vertical: AppDensity.bannerVPad),
      child: Row(
        children: [
          Expanded(
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.mono(fontSize: 12),
            ),
          ),
          Text(
            '+$adds',
            style: AppText.mono(
              color: theme.colorScheme.tertiary,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            '-$dels',
            style: AppText.mono(
              color: theme.colorScheme.error,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'vs HEAD',
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _HunkCard extends StatelessWidget {
  final _Hunk hunk;
  const _HunkCard({required this.hunk});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: theme.colorScheme.surfaceContainer,
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
            child: Text(
              '@@ -${hunk.oldStart},${hunk.oldLines} '
              '+${hunk.newStart},${hunk.newLines} @@',
              style: AppText.mono(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final ln in hunk.lines) _DiffLineRow(line: ln),
        ],
      ),
    );
  }
}

class _DiffLineRow extends StatelessWidget {
  final _DiffLine line;
  const _DiffLineRow({required this.line});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color bg;
    final Color fg;
    final String marker;
    switch (line.kind) {
      case 'add':
        bg = theme.colorScheme.tertiaryContainer;
        fg = theme.colorScheme.onTertiaryContainer;
        marker = '+';
        break;
      case 'del':
        bg = theme.colorScheme.errorContainer;
        fg = theme.colorScheme.onErrorContainer;
        marker = '-';
        break;
      case 'noNewline':
        bg = theme.colorScheme.surfaceContainerHighest;
        fg = theme.colorScheme.onSurfaceVariant;
        marker = '\\';
        break;
      default:
        bg = theme.colorScheme.surface;
        fg = theme.colorScheme.onSurface;
        marker = ' ';
    }
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: AppSpacing.md,
            child: Text(
              marker,
              style: AppText.mono(
                color: fg,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: SelectableText(
              line.text,
              style: AppText.mono(
                color: fg,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GapStrip extends StatelessWidget {
  final int unchanged;
  const _GapStrip({required this.unchanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: 2),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      alignment: Alignment.center,
      child: Text(
        '… $unchanged unchanged line${unchanged == 1 ? '' : 's'} …',
        style: AppText.mono(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _DiffPlaceholder extends StatelessWidget {
  final String path;
  final String kind;
  const _DiffPlaceholder({required this.path, required this.kind});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = switch (kind) {
      'binary' => 'Binary file — diff not shown.',
      'too-large' => 'Diff exceeds the 500 KB cap. View in terminal.',
      'deleted' => 'File deleted. The old contents are in HEAD.',
      _ => 'Unsupported diff shape: $kind',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  path,
                  style: AppText.mono(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(reason, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DiffErrorView extends StatelessWidget {
  final String path;
  final String message;
  const _DiffErrorView({required this.path, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Could not load diff for $path',
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Hunk {
  final int oldStart;
  final int oldLines;
  final int newStart;
  final int newLines;
  final List<_DiffLine> lines;
  const _Hunk({
    required this.oldStart,
    required this.oldLines,
    required this.newStart,
    required this.newLines,
    required this.lines,
  });
}

class _DiffLine {
  final String kind; // context | add | del | noNewline
  final String text;
  const _DiffLine({required this.kind, required this.text});
}
