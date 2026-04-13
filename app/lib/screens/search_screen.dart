import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/search_provider.dart';
import '../providers/editor_provider.dart';
import 'code_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSearch(String query) {
    final provider = context.read<SearchProvider>();
    if (provider.searchMode == SearchMode.fileContent) {
      provider.searchContent(query, '/');
    } else {
      provider.search(query, '/');
    }
  }

  void _onResultTap(String path, String name) {
    final editorProvider = context.read<EditorProvider>();
    editorProvider.openFile(path).then((_) {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: Column(
        children: [
          // Search mode toggle
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Consumer<SearchProvider>(
              builder: (context, provider, _) {
                return SegmentedButton<SearchMode>(
                  segments: const [
                    ButtonSegment(
                      value: SearchMode.fileName,
                      label: Text('Files'),
                      icon: Icon(Icons.insert_drive_file),
                    ),
                    ButtonSegment(
                      value: SearchMode.fileContent,
                      label: Text('Content'),
                      icon: Icon(Icons.text_snippet),
                    ),
                  ],
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
                    _onSearch(value);
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

                if (provider.searchMode == SearchMode.fileContent) {
                  return _buildContentResults(provider);
                }
                return _buildFileResults(provider);
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
          onTap: result.isDirectory
              ? null
              : () => _onResultTap(result.path, result.name),
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
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
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
          onTap: () => _onResultTap(result.file, fileName),
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
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
            ),
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
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
            ),
        children: [
          TextSpan(text: before.trimLeft()),
          TextSpan(
            text: match,
            style: TextStyle(
              backgroundColor:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
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
