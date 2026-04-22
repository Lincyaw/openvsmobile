import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../navigation/editor_navigation.dart';
import '../providers/search_provider.dart';
import '../providers/workspace_provider.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSearch(String query) {
    final provider = context.read<SearchProvider>();
    final rootPath = context.read<WorkspaceProvider>().currentPath;
    switch (provider.searchMode) {
      case SearchMode.fileName:
        provider.search(query, rootPath);
        break;
      case SearchMode.fileContent:
        provider.searchContent(query, rootPath);
        break;
      case SearchMode.workspaceSymbols:
        provider.searchSymbols(query, rootPath);
        break;
    }
  }

  Future<void> _onResultTap(String path, {int? line}) {
    return openCodePath(context, path: path, line: line);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Consumer<WorkspaceProvider>(
          builder: (context, ws, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Search'),
                Text(
                  'in ${ws.statusLabel}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            );
          },
        ),
      ),
      body: Column(
        children: [
          // Search mode toggle
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Consumer<SearchProvider>(
              builder: (context, provider, _) {
                final segments = <ButtonSegment<SearchMode>>[
                  const ButtonSegment(
                    value: SearchMode.fileName,
                    label: Text('Files'),
                    icon: Icon(Icons.insert_drive_file),
                  ),
                  const ButtonSegment(
                    value: SearchMode.fileContent,
                    label: Text('Content'),
                    icon: Icon(Icons.text_snippet),
                  ),
                  if (provider.workspaceSymbolsAvailable)
                    const ButtonSegment(
                      value: SearchMode.workspaceSymbols,
                      label: Text('Symbols'),
                      icon: Icon(Icons.account_tree_outlined),
                    ),
                ];
                return SegmentedButton<SearchMode>(
                  segments: segments,
                  selected: {provider.searchMode},
                  onSelectionChanged: (selected) {
                    provider.setSearchMode(selected.first);
                    if (_controller.text.isNotEmpty) {
                      _onSearch(_controller.text);
                    }
                  },
                );
              },
            ),
          ),
          // Search field
          Padding(
            padding: const EdgeInsets.all(12),
            child: Consumer<SearchProvider>(
              builder: (context, provider, _) {
                return TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  decoration: InputDecoration(
                    hintText: provider.searchMode == SearchMode.fileContent
                        ? 'Search in file contents...'
                        : provider.searchMode == SearchMode.workspaceSymbols
                        ? 'Search workspace symbols...'
                        : 'Search files...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _controller.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _controller.clear();
                              context.read<SearchProvider>().clearResults();
                              setState(() {});
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                  ),
                  onChanged: (value) {
                    setState(() {});
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 300), () {
                      _onSearch(value);
                    });
                  },
                  onSubmitted: _onSearch,
                  textInputAction: TextInputAction.search,
                );
              },
            ),
          ),
          // Results
          Expanded(
            child: Consumer<SearchProvider>(
              builder: (context, provider, child) {
                if (provider.isSearching) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (provider.error != null) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 48,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Search failed',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          provider.error!,
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }

                if (provider.query.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.search,
                          size: 64,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          provider.searchMode == SearchMode.fileContent
                              ? 'Search for text in files'
                              : provider.searchMode ==
                                    SearchMode.workspaceSymbols
                              ? 'Search for symbols across the workspace'
                              : 'Search for files by name',
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      ],
                    ),
                  );
                }

                switch (provider.searchMode) {
                  case SearchMode.fileContent:
                    return _buildContentResults(provider);
                  case SearchMode.workspaceSymbols:
                    return _buildSymbolResults(provider);
                  case SearchMode.fileName:
                    return _buildFileResults(provider);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileResults(SearchProvider provider) {
    if (provider.results.isEmpty) {
      return _buildEmptyState(provider.query);
    }

    return ListView.builder(
      itemCount: provider.results.length,
      itemBuilder: (context, index) {
        final result = provider.results[index];
        return ListTile(
          leading: Icon(
            result.isDirectory ? Icons.folder : Icons.insert_drive_file,
            color: result.isDirectory
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          title: Text(result.name),
          subtitle: Text(
            result.path,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: result.isDirectory ? null : () => _onResultTap(result.path),
        );
      },
    );
  }

  Widget _buildContentResults(SearchProvider provider) {
    if (provider.contentResults.isEmpty) {
      return _buildEmptyState(provider.query);
    }

    return ListView.builder(
      itemCount: provider.contentResults.length,
      itemBuilder: (context, index) {
        final result = provider.contentResults[index];
        final fileName = result.file.split('/').last;
        return ListTile(
          leading: const Icon(Icons.text_snippet),
          title: Text(
            '$fileName:${result.line}',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                result.file,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              _buildHighlightedLine(result.content, provider.query),
            ],
          ),
          isThreeLine: true,
          onTap: () => _onResultTap(result.file, line: result.line),
        );
      },
    );
  }

  Widget _buildSymbolResults(SearchProvider provider) {
    if (provider.symbolResults.isEmpty) {
      return _buildEmptyState(provider.query);
    }

    return ListView.builder(
      itemCount: provider.symbolResults.length,
      itemBuilder: (context, index) {
        final result = provider.symbolResults[index];
        return ListTile(
          leading: const Icon(Icons.account_tree_outlined),
          title: Text(result.name),
          subtitle: Text(
            result.subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () =>
              _onResultTap(result.path, line: result.range.startLineOneBased),
        );
      },
    );
  }

  Widget _buildHighlightedLine(String line, String query) {
    final lowerLine = line.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final matchIndex = lowerLine.indexOf(lowerQuery);

    if (matchIndex == -1) {
      return Text(
        line.trim(),
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    final before = line.substring(0, matchIndex);
    final match = line.substring(matchIndex, matchIndex + query.length);
    final after = line.substring(matchIndex + query.length);

    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        children: [
          TextSpan(text: before.trimLeft()),
          TextSpan(
            text: match,
            style: TextStyle(
              backgroundColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.3),
              fontWeight: FontWeight.bold,
            ),
          ),
          TextSpan(text: after),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String query) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'No results for "$query"',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
