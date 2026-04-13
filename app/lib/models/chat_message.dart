// Models for chat messages and their content blocks.

class FileAnnotation {
  final String? filePath;
  final String? oldString;
  final String? newString;
  final String? content;
  final int? offset;
  final int? limit;
  final String? command;

  const FileAnnotation({
    this.filePath,
    this.oldString,
    this.newString,
    this.content,
    this.offset,
    this.limit,
    this.command,
  });

  factory FileAnnotation.fromJson(Map<String, dynamic> json) {
    return FileAnnotation(
      filePath: json['filePath'] as String?,
      oldString: json['oldString'] as String?,
      newString: json['newString'] as String?,
      content: json['content'] as String?,
      offset: json['offset'] as int?,
      limit: json['limit'] as int?,
      command: json['command'] as String?,
    );
  }
}

class ContentBlock {
  final String type;

  // text block
  final String? text;

  // thinking block
  final String? thinking;
  final String? signature;

  // tool_use block
  final String? id;
  final String? name;
  final Map<String, dynamic>? input;
  final FileAnnotation? fileAnnotation;

  // tool_result block
  final String? toolUseId;
  final dynamic resultContent;
  final bool? isError;

  const ContentBlock({
    required this.type,
    this.text,
    this.thinking,
    this.signature,
    this.id,
    this.name,
    this.input,
    this.fileAnnotation,
    this.toolUseId,
    this.resultContent,
    this.isError,
  });

  factory ContentBlock.fromJson(Map<String, dynamic> json) {
    FileAnnotation? annotation;
    if (json['fileAnnotation'] != null) {
      annotation = FileAnnotation.fromJson(
        json['fileAnnotation'] as Map<String, dynamic>,
      );
    }

    // Go session API nests tool_use fields under "toolUse" and
    // tool_result fields under "toolResult" objects.
    final toolUse = json['toolUse'] as Map<String, dynamic>?;
    final toolResult = json['toolResult'] as Map<String, dynamic>?;

    return ContentBlock(
      type: json['type'] as String,
      text: json['text'] as String?,
      thinking: json['thinking'] as String?,
      signature: json['signature'] as String?,
      id: json['id'] as String? ?? toolUse?['id'] as String?,
      name: json['name'] as String? ?? toolUse?['name'] as String?,
      input:
          json['input'] as Map<String, dynamic>? ??
          _parseInput(toolUse?['input']),
      fileAnnotation: annotation,
      toolUseId:
          json['tool_use_id'] as String? ??
          toolResult?['tool_use_id'] as String?,
      resultContent: json['content'] ?? toolResult?['content'],
      isError: json['is_error'] as bool? ?? toolResult?['is_error'] as bool?,
    );
  }

  static Map<String, dynamic>? _parseInput(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    return null;
  }
}

class ChatMessage {
  final String role; // 'user' or 'assistant'
  final List<ContentBlock> content;

  const ChatMessage({required this.role, required this.content});

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawContent = json['content'] ?? json['contentBlocks'];
    List<ContentBlock> blocks;

    if (rawContent is String) {
      blocks = [ContentBlock(type: 'text', text: rawContent)];
    } else if (rawContent is List) {
      blocks = rawContent
          .map((b) => ContentBlock.fromJson(b as Map<String, dynamic>))
          .toList();
    } else {
      blocks = [];
    }

    // Go session API returns "type" (user/assistant/system),
    // while live chat uses "role". Accept both.
    final role = json['role'] as String? ?? json['type'] as String? ?? '';

    return ChatMessage(role: role, content: blocks);
  }

  /// Helper to get all text content concatenated.
  String get textContent {
    return content
        .where((b) => b.type == 'text' && b.text != null)
        .map((b) => b.text!)
        .join('\n');
  }
}

/// Represents a code context attached to a chat message.
class CodeContext {
  final String filePath;
  final int startLine;
  final int endLine;
  final String selectedText;

  const CodeContext({
    required this.filePath,
    required this.startLine,
    required this.endLine,
    required this.selectedText,
  });

  String get label {
    final fileName = filePath.split('/').last;
    return '$fileName:$startLine-$endLine';
  }
}
