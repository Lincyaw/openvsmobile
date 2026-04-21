import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/editor_models.dart';
import '../providers/editor_provider.dart';
import '../widgets/code_editor.dart';
import '../widgets/code_viewer.dart';
import '../widgets/contextual_chat.dart';
import 'chat_screen.dart';

enum _EditorMenuAction {
  requestCompletion,
  hover,
  definition,
  references,
  rename,
  format,
  quickFixes,
  problems,
  close,
}

enum _CloseChoice { save, discard, cancel }

class CodeScreen extends StatefulWidget {
  const CodeScreen({super.key});

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends State<CodeScreen> {
  bool _showChat = false;

  Future<void> _showFeedback(BuildContext context, String message) async {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _closeCurrentFile(
    BuildContext context,
    EditorProvider editorProvider,
  ) async {
    final file = editorProvider.currentFile;
    if (file == null) {
      return;
    }

    if (!file.hasUnsavedChanges) {
      await editorProvider.closeFile(editorProvider.currentFileIndex);
      if (context.mounted) {
        Navigator.of(context).pop();
      }
      return;
    }

    final choice = await showDialog<_CloseChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: Text('Save changes to ${file.name} before closing?'),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_CloseChoice.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_CloseChoice.discard),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(_CloseChoice.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (choice == null || choice == _CloseChoice.cancel) {
      return;
    }

    if (choice == _CloseChoice.save) {
      final saved = await editorProvider.saveCurrentFile();
      if (!saved) {
        if (!context.mounted) {
          return;
        }
        await _showFeedback(context, 'Failed to save file before closing.');
        return;
      }
    }

    await editorProvider.closeFile(editorProvider.currentFileIndex);
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _showLocations(
    BuildContext context,
    EditorProvider editorProvider,
    String title,
    Future<List<EditorLocation>> Function() loader,
  ) async {
    final locations = await loader();
    if (!context.mounted) {
      return;
    }
    if (locations.isEmpty) {
      await _showFeedback(context, 'No $title found.');
      return;
    }
    if (locations.length == 1) {
      await editorProvider.openLocation(locations.first);
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView.builder(
            itemCount: locations.length,
            itemBuilder: (context, index) {
              final location = locations[index];
              return ListTile(
                leading: const Icon(Icons.place_outlined),
                title: Text(location.path.split('/').last),
                subtitle: Text(location.label),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await editorProvider.openLocation(location);
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showProblemsPanel(
    BuildContext context,
    EditorProvider editorProvider,
  ) async {
    final diagnostics = editorProvider.allDiagnostics;
    if (diagnostics.isEmpty) {
      await _showFeedback(context, 'No problems for open files.');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView.separated(
            itemCount: diagnostics.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final diagnostic = diagnostics[index];
              return ListTile(
                leading: Icon(
                  diagnostic.isError
                      ? Icons.error_outline
                      : diagnostic.isWarning
                      ? Icons.warning_amber_rounded
                      : Icons.info_outline,
                  color: diagnostic.isError
                      ? Theme.of(context).colorScheme.error
                      : diagnostic.isWarning
                      ? Colors.orange
                      : Theme.of(context).colorScheme.primary,
                ),
                title: Text(
                  diagnostic.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${diagnostic.filePath}:${diagnostic.line}:${diagnostic.column}',
                ),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await editorProvider.openDiagnostic(diagnostic);
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showHover(
    BuildContext context,
    EditorProvider editorProvider,
  ) async {
    final hover = await editorProvider.requestHover();
    if (!context.mounted) {
      return;
    }
    final hoverText = hover?.plainText ?? '';
    if (hover == null || hoverText.isEmpty) {
      await _showFeedback(context, 'No hover details available here.');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(child: SelectableText(hoverText)),
          ),
        );
      },
    );
  }

  Future<void> _showQuickFixes(
    BuildContext context,
    EditorProvider editorProvider,
  ) async {
    final actions = await editorProvider.loadCodeActions(quickFixOnly: true);
    if (!context.mounted) {
      return;
    }
    if (actions.isEmpty) {
      await _showFeedback(context, 'No quick fixes available.');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView.builder(
            itemCount: actions.length,
            itemBuilder: (context, index) {
              final action = actions[index];
              return ListTile(
                leading: const Icon(Icons.auto_fix_high),
                title: Text(action.title),
                subtitle: action.kind.isNotEmpty ? Text(action.kind) : null,
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final applied = await editorProvider.applyCodeAction(action);
                  if (!context.mounted) {
                    return;
                  }
                  await _showFeedback(
                    context,
                    applied
                        ? 'Applied quick fix.'
                        : 'Quick fix did not return edits.',
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _renameSymbol(
    BuildContext context,
    EditorProvider editorProvider,
  ) async {
    final controller = TextEditingController();
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename symbol'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'New name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) {
      return;
    }

    final renamed = await editorProvider.renameSymbol(newName);
    if (!context.mounted) {
      return;
    }
    await _showFeedback(
      context,
      renamed ? 'Rename applied.' : 'Rename did not return any edits.',
    );
  }

  Future<void> _handleMenuAction(
    BuildContext context,
    EditorProvider editorProvider,
    _EditorMenuAction action,
  ) async {
    switch (action) {
      case _EditorMenuAction.requestCompletion:
        final items = await editorProvider.requestCompletion();
        if (items.isEmpty && context.mounted) {
          await _showFeedback(context, 'No completion items available.');
        }
        break;
      case _EditorMenuAction.hover:
        await _showHover(context, editorProvider);
        break;
      case _EditorMenuAction.definition:
        await _showLocations(
          context,
          editorProvider,
          'definitions',
          editorProvider.requestDefinition,
        );
        break;
      case _EditorMenuAction.references:
        await _showLocations(
          context,
          editorProvider,
          'references',
          editorProvider.requestReferences,
        );
        break;
      case _EditorMenuAction.rename:
        await _renameSymbol(context, editorProvider);
        break;
      case _EditorMenuAction.format:
        final formatted = await editorProvider.formatCurrentFile();
        if (context.mounted) {
          await _showFeedback(
            context,
            formatted
                ? 'Formatting edits applied.'
                : 'No formatting edits available.',
          );
        }
        break;
      case _EditorMenuAction.quickFixes:
        await _showQuickFixes(context, editorProvider);
        break;
      case _EditorMenuAction.problems:
        await _showProblemsPanel(context, editorProvider);
        break;
      case _EditorMenuAction.close:
        await _closeCurrentFile(context, editorProvider);
        break;
    }
  }

  Widget _buildBridgeBanner(
    BuildContext context,
    EditorProvider editorProvider,
  ) {
    final file = editorProvider.currentFile;
    if (file == null || file.bridgeTracking) {
      return const SizedBox.shrink();
    }

    return MaterialBanner(
      content: const Text(
        'Bridge-backed editor features are limited until the runtime bridge is ready.',
      ),
      leading: const Icon(Icons.link_off),
      actions: [
        TextButton(
          onPressed: editorProvider.refreshCapabilities,
          child: const Text('Retry'),
        ),
      ],
    );
  }

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

  Widget _buildCompletionPanel(
    BuildContext context,
    EditorProvider editorProvider,
  ) {
    if (editorProvider.completionItems.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: editorProvider.completionItems.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = editorProvider.completionItems[index];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.bolt),
                title: Text(item.label),
                subtitle: item.detail.isNotEmpty
                    ? Text(
                        item.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : item.documentationText.isNotEmpty
                    ? Text(
                        item.documentationText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      )
                    : null,
                onTap: () async {
                  final applied = await editorProvider.applyCompletionItem(
                    item,
                  );
                  if (!applied && context.mounted) {
                    await _showFeedback(
                      context,
                      'Failed to apply completion item.',
                    );
                  }
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildSignatureHelpCard(
    BuildContext context,
    EditorProvider editorProvider,
  ) {
    final signatureHelp = editorProvider.signatureHelp;
    final label = signatureHelp?.activeLabel;
    if (label == null || label.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: 16,
      right: 16,
      top: 16,
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(12),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.functions, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
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

        final isEditing = file.isEditing;
        final hasChanges = file.hasUnsavedChanges;
        final diagnosticsCount = editorProvider.allDiagnostics.length;
        final canRequestCompletions =
            isEditing &&
            file.bridgeTracking &&
            editorProvider.capabilityEnabled('completion');
        final canHover =
            file.bridgeTracking && editorProvider.capabilityEnabled('hover');
        final canDefinition =
            file.bridgeTracking &&
            editorProvider.capabilityEnabled('definition');
        final canReferences =
            file.bridgeTracking &&
            editorProvider.capabilityEnabled('references');
        final canRename =
            file.bridgeTracking && editorProvider.capabilityEnabled('rename');
        final canFormat =
            file.bridgeTracking &&
            editorProvider.capabilityEnabled('formatting');
        final canQuickFix =
            file.bridgeTracking &&
            editorProvider.capabilityEnabled('codeActions', const <String>[
              'code-actions',
            ]);

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
              if (editorProvider.canJumpBack)
                IconButton(
                  icon: const Icon(Icons.reply),
                  tooltip: 'Jump back',
                  onPressed: () => editorProvider.jumpBack(),
                ),
              IconButton(
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.rule_folder_outlined),
                    if (diagnosticsCount > 0)
                      Positioned(
                        right: -6,
                        top: -6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.error,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            diagnosticsCount.toString(),
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.onError,
                                ),
                          ),
                        ),
                      ),
                  ],
                ),
                tooltip: 'Problems',
                onPressed: () => _showProblemsPanel(context, editorProvider),
              ),
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
                              await _showFeedback(
                                context,
                                saved ? 'File saved.' : 'Failed to save file.',
                              );
                            }
                          }
                        : null,
                  ),
                IconButton(
                  icon: const Icon(Icons.visibility),
                  tooltip: 'View mode',
                  onPressed: editorProvider.exitEditMode,
                ),
              ] else
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Edit mode',
                  onPressed: editorProvider.enterEditMode,
                ),
              PopupMenuButton<_EditorMenuAction>(
                onSelected: (action) =>
                    _handleMenuAction(context, editorProvider, action),
                itemBuilder: (context) => [
                  PopupMenuItem<_EditorMenuAction>(
                    value: _EditorMenuAction.requestCompletion,
                    enabled: canRequestCompletions,
                    child: const ListTile(
                      leading: Icon(Icons.bolt_outlined),
                      title: Text('Request completions'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem<_EditorMenuAction>(
                    value: _EditorMenuAction.hover,
                    enabled: canHover,
                    child: const ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text('Hover details'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem<_EditorMenuAction>(
                    value: _EditorMenuAction.definition,
                    enabled: canDefinition,
                    child: const ListTile(
                      leading: Icon(Icons.my_location_outlined),
                      title: Text('Go to definition'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem<_EditorMenuAction>(
                    value: _EditorMenuAction.references,
                    enabled: canReferences,
                    child: const ListTile(
                      leading: Icon(Icons.find_in_page_outlined),
                      title: Text('Find references'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem<_EditorMenuAction>(
                    value: _EditorMenuAction.rename,
                    enabled: canRename,
                    child: const ListTile(
                      leading: Icon(Icons.drive_file_rename_outline),
                      title: Text('Rename symbol'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem<_EditorMenuAction>(
                    value: _EditorMenuAction.format,
                    enabled: canFormat,
                    child: const ListTile(
                      leading: Icon(Icons.auto_fix_high_outlined),
                      title: Text('Format file'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem<_EditorMenuAction>(
                    value: _EditorMenuAction.quickFixes,
                    enabled: canQuickFix,
                    child: const ListTile(
                      leading: Icon(Icons.build_circle_outlined),
                      title: Text('Quick fixes'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem<_EditorMenuAction>(
                    value: _EditorMenuAction.problems,
                    child: ListTile(
                      leading: Icon(Icons.rule_folder_outlined),
                      title: Text('Problems panel'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuItem<_EditorMenuAction>(
                    value: _EditorMenuAction.close,
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
          body: Column(
            children: [
              _buildBridgeBanner(context, editorProvider),
              _buildErrorBanner(context, editorProvider),
              Expanded(
                child: Stack(
                  children: [
                    isEditing
                        ? CodeEditor(
                            content: file.currentContent,
                            fileName: file.name,
                            diagnostics: editorProvider.diagnostics,
                            revealSelection: editorProvider.revealSelection,
                            revealNonce: editorProvider.revealNonce,
                            onContentChanged: editorProvider.updateContent,
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
                            diagnostics: editorProvider.diagnostics,
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
                            onEditRequested: editorProvider.enterEditMode,
                            onLongPressHover: canHover
                                ? () => _showHover(context, editorProvider)
                                : null,
                            onDefinitionRequested: canDefinition
                                ? () => _showLocations(
                                    context,
                                    editorProvider,
                                    'definitions',
                                    editorProvider.requestDefinition,
                                  )
                                : null,
                          ),
                    _buildSignatureHelpCard(context, editorProvider),
                    if (isEditing)
                      _buildCompletionPanel(context, editorProvider),
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
