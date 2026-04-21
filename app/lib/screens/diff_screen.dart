import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/git_models.dart';
import '../providers/git_provider.dart';
import '../widgets/unified_diff_view.dart';

class DiffScreen extends StatefulWidget {
  final String filePath;
  final bool staged;
  final bool isConflict;

  const DiffScreen({
    super.key,
    required this.filePath,
    required this.staged,
    this.isConflict = false,
  });

  @override
  State<DiffScreen> createState() => _DiffScreenState();
}

class _DiffScreenState extends State<DiffScreen> {
  late Future<GitDiffDocument> _diffFuture;

  @override
  void initState() {
    super.initState();
    _diffFuture = _loadDiff();
  }

  Future<GitDiffDocument> _loadDiff() {
    return context.read<GitProvider>().fetchDiff(
      widget.filePath,
      staged: widget.staged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.filePath, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Refresh diff',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                _diffFuture = _loadDiff();
              });
            },
          ),
        ],
      ),
      body: FutureBuilder<GitDiffDocument>(
        future: _diffFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: colorScheme.error,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Failed to load diff',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${snapshot.error}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () {
                        setState(() {
                          _diffFuture = _loadDiff();
                        });
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            );
          }

          final diff = snapshot.data!;
          return UnifiedDiffView(
            diff: diff.diff,
            isConflict: widget.isConflict,
            emptyLabel: widget.isConflict
                ? 'Open this file in the editor to resolve the conflict.'
                : 'No diff available for this file',
          );
        },
      ),
    );
  }
}
