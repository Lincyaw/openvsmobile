import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/file_provider.dart';
import '../providers/editor_provider.dart';
import '../widgets/file_tree_view.dart';
import 'code_screen.dart';

class FilesScreen extends StatelessWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Consumer<FileProvider>(
          builder: (context, fileProvider, child) {
            final name = fileProvider.currentProject == '/'
                ? 'Files'
                : fileProvider.currentProject.split('/').last;
            return Text(name);
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () {
              context.read<FileProvider>().refresh();
            },
          ),
        ],
      ),
      body: FileTreeView(
        onFileTap: (path, name) {
          final editorProvider = context.read<EditorProvider>();
          editorProvider.openFile(path).then((_) {
            if (context.mounted) {
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
        },
      ),
    );
  }
}
