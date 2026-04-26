import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/editor_provider.dart';
import '../widgets/code_viewer.dart';
import '../widgets/contextual_chat.dart';
import 'chat_screen.dart';

/// Read-only viewer for the active file. Selection is forwarded to
/// [EditorProvider] so the chat surfaces can attach it as context.
class CodeScreen extends StatefulWidget {
  const CodeScreen({super.key});

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends State<CodeScreen> {
  bool _showChat = false;

  Widget _buildErrorBanner(
    BuildContext context,
    EditorProvider editorProvider,
  ) {
    final error = editorProvider.error;
    if (error == null || error.isEmpty) {
      return const SizedBox.shrink();
    }

    return MaterialBanner(
      content: Text(error),
      backgroundColor: Theme.of(context).colorScheme.errorContainer,
      leading: const Icon(Icons.error_outline),
      actions: [
        TextButton(
          onPressed: editorProvider.clearError,
          child: const Text('Dismiss'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<EditorProvider>(
      builder: (context, editorProvider, _) {
        final file = editorProvider.currentFile;
        if (file == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('No file open')),
            body: const Center(child: Text('No file is currently open.')),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(file.name, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close file',
                onPressed: () async {
                  await editorProvider.closeFile(
                    editorProvider.currentFileIndex,
                  );
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ],
          ),
          body: Column(
            children: [
              _buildErrorBanner(context, editorProvider),
              Expanded(
                child: Stack(
                  children: [
                    CodeViewer(
                      content: file.content,
                      fileName: file.name,
                      revealSelection: editorProvider.revealSelection,
                      revealNonce: editorProvider.revealNonce,
                      onSelectionChanged: (selection) {
                        editorProvider.updateSelection(
                          selection,
                          cursor: selection?.end ?? editorProvider.cursor,
                        );
                      },
                      onAskAi: () {
                        setState(() => _showChat = true);
                      },
                    ),
                    if (_showChat)
                      ContextualChat(
                        onExpandToFullChat: () {
                          setState(() => _showChat = false);
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ChatScreen(),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
