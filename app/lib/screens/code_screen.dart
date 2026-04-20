import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';
import 'chat_screen.dart';
import '../widgets/code_viewer.dart';
import '../widgets/code_editor.dart';
import '../widgets/contextual_chat.dart';

class CodeScreen extends StatefulWidget {
  const CodeScreen({super.key});

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends State<CodeScreen> {
  bool _showChat = false;

  Future<void> _confirmClose(
    BuildContext context,
    EditorProvider editorProvider,
  ) async {
    final file = editorProvider.currentFile;
    if (file == null) return;

    if (file.hasUnsavedChanges) {
      final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Unsaved Changes'),
          content: Text('${file.name} has unsaved changes. Close anyway?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (result != true) return;
    }

    editorProvider.closeFile(editorProvider.currentFileIndex);
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<EditorProvider>(
      builder: (context, editorProvider, child) {
        final file = editorProvider.currentFile;
        if (file == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('No file open')),
            body: const Center(child: Text('No file is currently open.')),
          );
        }

        final isEditing = file.isEditing;
        final hasChanges = file.hasUnsavedChanges;

        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasChanges)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                Flexible(
                  child: Text(file.name, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            actions: [
              if (isEditing) ...[
                if (editorProvider.isLoading)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.save),
                    tooltip: 'Save',
                    onPressed: hasChanges
                        ? () async {
                            final saved = await editorProvider
                                .saveCurrentFile();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    saved
                                        ? 'File saved'
                                        : 'Failed to save file',
                                  ),
                                  duration: const Duration(seconds: 1),
                                ),
                              );
                            }
                          }
                        : null,
                  ),
                IconButton(
                  icon: const Icon(Icons.visibility),
                  tooltip: 'View mode',
                  onPressed: () => editorProvider.exitEditMode(),
                ),
              ] else
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Edit mode',
                  onPressed: () => editorProvider.enterEditMode(),
                ),
              PopupMenuButton<String>(
                onSelected: (value) async {
                  switch (value) {
                    case 'close':
                      await _confirmClose(context, editorProvider);
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'close',
                    child: ListTile(
                      leading: Icon(Icons.close),
                      title: Text('Close file'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: Stack(
            children: [
              isEditing
                  ? CodeEditor(
                      content: file.currentContent,
                      fileName: file.name,
                      revealCursor: editorProvider.cursor,
                      revealToken: editorProvider.revealNonce,
                      onContentChanged: (content) {
                        editorProvider.updateContent(content);
                      },
                      onCursorChanged: editorProvider.updateCursor,
                      onSelectionChanged: (selection, cursor) {
                        editorProvider.updateSelection(
                          selection,
                          cursor: cursor,
                        );
                      },
                      onSave: hasChanges
                          ? () => editorProvider.saveCurrentFile()
                          : null,
                    )
                  : CodeViewer(
                      content: file.currentContent,
                      fileName: file.name,
                      revealCursor: editorProvider.cursor,
                      revealToken: editorProvider.revealNonce,
                      diagnostics: editorProvider.diagnostics,
                      onSelectionChanged: (selection) {
                        editorProvider.updateSelection(
                          selection,
                          cursor: selection?.end ?? editorProvider.cursor,
                        );
                      },
                      onAskAi: () {
                        setState(() => _showChat = true);
                      },
                      onEditRequested: () {
                        editorProvider.enterEditMode();
                      },
                    ),
              if (_showChat)
                ContextualChat(
                  onExpandToFullChat: () {
                    setState(() => _showChat = false);
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ChatScreen()),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
