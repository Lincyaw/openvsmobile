import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../models/editor_context.dart';
import '../models/editor_models.dart';
import '../providers/editor_provider.dart';
import '../screens/code_screen.dart';

Future<void> openCodePath(
  BuildContext context, {
  required String path,
  EditorSelection? selection,
  EditorCursor? cursor,
  int? line,
  int? offset,
  int? limit,
}) async {
  final editorProvider = context.read<EditorProvider>();
  await editorProvider.openFileAt(
    path,
    selection: selection,
    cursor: cursor,
    line: line,
    offset: offset,
    limit: limit,
  );

  if (!context.mounted) {
    return;
  }

  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChangeNotifierProvider.value(
        value: editorProvider,
        child: const CodeScreen(),
      ),
    ),
  );
}

Future<void> openCodeLocation(BuildContext context, EditorLocation location) {
  return openCodePath(
    context,
    path: location.path,
    selection: location.range.toSelection(),
    cursor: location.range.start.toCursor(),
  );
}

Future<void> openCodeAnnotation(
  BuildContext context, {
  required String path,
  FileAnnotation? annotation,
}) {
  return openCodePath(
    context,
    path: path,
    offset: annotation?.offset,
    limit: annotation?.limit,
  );
}
