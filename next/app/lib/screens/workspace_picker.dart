// Step-by-step directory picker. No raw path input — the user drills.
// Uses fs.listDir({ path, picker: true }) so it can traverse outside any
// active workspace.
//
// The picker's directory + entry cache lives in AppState so it survives a
// rebuild and stays in one place — see docs/conventions.md §2.

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../ui/app_tokens.dart';
import '../models.dart';

class WorkspacePickerScreen extends StatefulWidget {
  final AppState appState;
  const WorkspacePickerScreen({super.key, required this.appState});

  @override
  State<WorkspacePickerScreen> createState() => _WorkspacePickerScreenState();
}

class _WorkspacePickerScreenState extends State<WorkspacePickerScreen> {
  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppStateChanged);
    // Start at the BACKEND's $HOME, not the phone's. The phone's $HOME on
    // Android is something useless like `/data/user/0/...` — the picker
    // would crash or list a placeholder dir. The handshake response carries
    // the server-side default cwd; fall back to "/" if missing.
    widget.appState.openPicker();
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppStateChanged);
    widget.appState.closePicker();
    super.dispose();
  }

  void _onAppStateChanged() {
    if (mounted) setState(() {});
  }

  String _parent(String path) {
    if (path == '/' || path.isEmpty) return '/';
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return '/';
    return path.substring(0, idx);
  }

  Future<void> _select() async {
    final navigator = Navigator.of(context);
    final picker = widget.appState.pickerState;
    if (picker == null) return;
    final ws = await widget.appState.openWorkspace(picker.path);
    if (!mounted) return;
    if (ws == null) {
      // AppState surfaces the failure via lastOperationError → SnackBar
      // (handled centrally by HomeShell). Nothing extra to do.
      return;
    }
    navigator.pop(ws);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final picker = widget.appState.pickerState;
    final path = picker?.path ?? widget.appState.backendDefaultCwd;
    final entries = picker?.entries;
    final loading = picker?.loading ?? true;
    final error = picker?.error;
    final dirs = entries?.where((e) => e.isDir).toList() ?? const <DirEntry>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a folder'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed:
                loading ? null : () => widget.appState.navigatePicker(path),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: 'Parent',
                  onPressed: path == '/'
                      ? null
                      : () =>
                          widget.appState.navigatePicker(_parent(path)),
                ),
                Expanded(
                  child: Text(
                    path,
                    style: AppText.mono(),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(error,
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: entries == null
                ? const SizedBox.shrink()
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (ctx, i) {
                      final e = entries[i];
                      final enabled = e.isDir;
                      return ListTile(
                        leading: Icon(
                          e.isDir
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                          color: enabled ? null : theme.disabledColor,
                        ),
                        title: Text(
                          e.name,
                          style: TextStyle(
                            color: enabled ? null : theme.disabledColor,
                          ),
                        ),
                        onTap: enabled
                            ? () => widget.appState.navigatePicker(
                                  path.endsWith('/')
                                      ? '$path${e.name}'
                                      : '$path/${e.name}',
                                )
                            : null,
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: Text('Select this directory (${dirs.length} subdirs)'),
                  onPressed: loading ? null : _select,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
