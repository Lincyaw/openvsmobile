import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../models/session.dart';
import '../providers/chat_provider.dart';
import '../providers/editor_provider.dart';
import '../providers/workspace_provider.dart';
import '../widgets/chat_bubble.dart';
import 'code_screen.dart';

/// Read-only view of a past session's full conversation.
/// Fetches messages from GET /api/sessions/:id/messages.
class SessionDetailScreen extends StatefulWidget {
  final SessionMeta session;

  const SessionDetailScreen({super.key, required this.session});

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  List<ChatMessage>? _messages;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMessages();
  }

  Future<void> _loadMessages() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final provider = context.read<ChatProvider>();
      final messages = await provider.loadSessionMessages(
        widget.session.sessionId,
      );
      if (mounted) {
        setState(() {
          _messages = messages;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _navigateToFile(String filePath) {
    final editorProvider = context.read<EditorProvider>();
    editorProvider.openFile(filePath).then((_) {
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChangeNotifierProvider.value(
              value: editorProvider,
              child: const CodeScreen(),
            ),
          ),
        );
      }
    });
  }

  void _resumeSession() async {
    final workspaceProvider = context.read<WorkspaceProvider>();
    final chatProvider = context.read<ChatProvider>();

    await workspaceProvider.setWorkspace(widget.session.cwd);
    chatProvider.setWorkspace(widget.session.cwd);
    if (_messages != null) {
      chatProvider.setHistoryMessages(_messages!);
    }
    chatProvider.resumeConversation(widget.session.sessionId);

    if (mounted) {
      // Pop back to the main shell (Chat tab) rather than just the list screen.
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.projectName),
        actions: [
          if (widget.session.entrypoint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Chip(
                label: Text(
                  widget.session.entrypoint,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.play_arrow),
        label: const Text('Resume'),
        onPressed: _isLoading ? null : _resumeSession,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Failed to load messages',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: _loadMessages,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final messages = _messages;
    if (messages == null || messages.isEmpty) {
      return Center(
        child: Text(
          'No messages in this session',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        final nextMsg = index + 1 < messages.length
            ? messages[index + 1]
            : null;
        return ChatBubble(
          message: msg,
          nextMessage: nextMsg,
          sessionId: widget.session.sessionId,
          onFileTap: (filePath) => _navigateToFile(filePath),
        );
      },
    );
  }
}
