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
                  key: ValueKey(focusedId),
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

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TerminalView(
      widget.terminal,
      controller: _ctrl,
      autofocus: true,
      backgroundOpacity: 1.0,
    );
  }
}
