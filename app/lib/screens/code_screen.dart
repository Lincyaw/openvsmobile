import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/editor_provider.dart';
import '../widgets/code_viewer.dart';
import '../widgets/code_editor.dart';

class CodeScreen extends StatelessWidget {
  const CodeScreen({super.key});

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
                onSelected: (value) {
                  switch (value) {
                    case 'close':
                      editorProvider.closeFile(editorProvider.currentFileIndex);
                      Navigator.of(context).pop();
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
          body: isEditing
              ? CodeEditor(
                  content: file.currentContent,
                  fileName: file.name,
                  onContentChanged: (content) {
                    editorProvider.updateContent(content);
                  },
                  onSave: hasChanges
                      ? () => editorProvider.saveCurrentFile()
                      : null,
                )
              : CodeViewer(
                  content: file.currentContent,
                  fileName: file.name,
                  diagnostics: editorProvider.diagnostics,
                  onAskAi: (selectedText) {
                    editorProvider.setSelectedText(selectedText);
                    // Set code context on ChatProvider so contextual chat
                    // includes the selected code snippet.
                    final lines = selectedText.split('\n');
                    context.read<ChatProvider>().setCodeContext(
                      CodeContext(
                        filePath: file.path,
                        startLine: 1,
                        endLine: lines.length,
                        selectedText: selectedText,
                      ),
                    );
                  },
                  onEditRequested: () {
                    editorProvider.enterEditMode();
                  },
                ),
        );
      },
    );
  }
}
