import 'package:flutter/material.dart';

import '../widgets/unified_diff_view.dart';

class GitHubPatchScreen extends StatelessWidget {
  final String path;
  final String patch;

  const GitHubPatchScreen({super.key, required this.path, required this.patch});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(path, overflow: TextOverflow.ellipsis)),
      body: UnifiedDiffView(
        diff: patch,
        emptyLabel: 'No patch is available for this file.',
      ),
    );
  }
}
