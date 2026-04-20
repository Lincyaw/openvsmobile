import 'dart:convert';

import 'editor_context.dart';

class BridgeEventEnvelope {
  final String type;
  final dynamic payload;

  const BridgeEventEnvelope({required this.type, required this.payload});

  factory BridgeEventEnvelope.fromJson(Map<String, dynamic> json) {
    return BridgeEventEnvelope(
      type: json['type'] as String? ?? '',
      payload: json['payload'],
    );
  }
}

class BridgeCapability {
  final bool enabled;
  final String? reason;
  final Map<String, dynamic> raw;

  const BridgeCapability({
    required this.enabled,
    required this.raw,
    this.reason,
  });

  factory BridgeCapability.fromJson(dynamic json) {
    if (json is bool) {
      return BridgeCapability(enabled: json, raw: <String, dynamic>{});
    }
    if (json is Map<String, dynamic>) {
      return BridgeCapability(
        enabled: json['enabled'] as bool? ?? false,
        reason: json['reason'] as String?,
        raw: Map<String, dynamic>.from(json),
      );
    }
    if (json is Map) {
      return BridgeCapability.fromJson(Map<String, dynamic>.from(json));
    }
    return const BridgeCapability(enabled: false, raw: <String, dynamic>{});
  }
}

class BridgeCapabilitiesDocument {
  final String state;
  final String protocolVersion;
  final String bridgeVersion;
  final String generation;
  final Map<String, BridgeCapability> capabilities;

  const BridgeCapabilitiesDocument({
    required this.state,
    required this.protocolVersion,
    required this.bridgeVersion,
    required this.generation,
    required this.capabilities,
  });

  factory BridgeCapabilitiesDocument.fromJson(Map<String, dynamic> json) {
    final rawCapabilities = json['capabilities'];
    final capabilities = <String, BridgeCapability>{};
    if (rawCapabilities is Map) {
      for (final entry in rawCapabilities.entries) {
        capabilities[entry.key.toString()] = BridgeCapability.fromJson(
          entry.value,
        );
      }
    }
    return BridgeCapabilitiesDocument(
      state: json['state'] as String? ?? '',
      protocolVersion: json['protocolVersion'] as String? ?? '',
      bridgeVersion: json['bridgeVersion'] as String? ?? '',
      generation: json['generation'] as String? ?? '',
      capabilities: capabilities,
    );
  }

  bool isEnabled(String name, [Iterable<String> aliases = const <String>[]]) {
    final candidates = <String>[name, ...aliases];
    for (final candidate in candidates) {
      final capability = capabilities[candidate];
      if (capability != null) {
        return capability.enabled;
      }
    }
    return false;
  }
}

class DocumentPosition {
  final int line;
  final int character;

  const DocumentPosition({required this.line, required this.character});

  factory DocumentPosition.fromJson(Map<String, dynamic> json) {
    return DocumentPosition(
      line: json['line'] as int? ?? 0,
      character: json['character'] as int? ?? 0,
    );
  }

  factory DocumentPosition.fromCursor(EditorCursor cursor) {
    return DocumentPosition(
      line: cursor.line > 0 ? cursor.line - 1 : 0,
      character: cursor.column > 0 ? cursor.column - 1 : 0,
    );
  }

  Map<String, dynamic> toJson() => {'line': line, 'character': character};

  EditorCursor toCursor() =>
      EditorCursor(line: line + 1, column: character + 1);
}

class DocumentRange {
  final DocumentPosition start;
  final DocumentPosition end;

  const DocumentRange({required this.start, required this.end});

  factory DocumentRange.fromJson(Map<String, dynamic> json) {
    return DocumentRange(
      start: DocumentPosition.fromJson(
        Map<String, dynamic>.from(
          json['start'] as Map? ?? const <String, dynamic>{},
        ),
      ),
      end: DocumentPosition.fromJson(
        Map<String, dynamic>.from(
          json['end'] as Map? ?? const <String, dynamic>{},
        ),
      ),
    );
  }

  factory DocumentRange.fromSelection(EditorSelection selection) {
    return DocumentRange(
      start: DocumentPosition.fromCursor(selection.start),
      end: DocumentPosition.fromCursor(selection.end),
    );
  }

  Map<String, dynamic> toJson() => {
    'start': start.toJson(),
    'end': end.toJson(),
  };

  EditorSelection toSelection() =>
      EditorSelection(start: start.toCursor(), end: end.toCursor());

  bool containsLine(int oneBasedLine) {
    final zeroBased = oneBasedLine > 0 ? oneBasedLine - 1 : 0;
    return zeroBased >= start.line && zeroBased <= end.line;
  }

  int get startLineOneBased => start.line + 1;
  int get endLineOneBased => end.line + 1;
}

class DocumentChange {
  final DocumentRange? range;
  final String text;

  const DocumentChange({required this.text, this.range});

  const DocumentChange.fullReplacement(String content)
    : text = content,
      range = null;

  Map<String, dynamic> toJson() => {
    if (range != null) 'range': range!.toJson(),
    'text': text,
  };
}

class DocumentSnapshot {
  final String path;
  final int version;
  final String content;

  const DocumentSnapshot({
    required this.path,
    required this.version,
    required this.content,
  });

  factory DocumentSnapshot.fromJson(Map<String, dynamic> json) {
    return DocumentSnapshot(
      path: json['path'] as String? ?? '',
      version: json['version'] as int? ?? 0,
      content: json['content'] as String? ?? '',
    );
  }
}

class EditorLocation {
  final String uri;
  final String path;
  final DocumentRange range;

  const EditorLocation({
    required this.uri,
    required this.path,
    required this.range,
  });

  factory EditorLocation.fromJson(Map<String, dynamic> json) {
    final uri = json['uri'] as String? ?? '';
    final path = (json['path'] as String?) ?? _pathFromUri(uri);
    return EditorLocation(
      uri: uri,
      path: path,
      range: DocumentRange.fromJson(
        Map<String, dynamic>.from(
          json['range'] as Map? ?? const <String, dynamic>{},
        ),
      ),
    );
  }

  String get label => '$path:${range.startLineOneBased}';
}

class EditorTextEdit {
  final DocumentRange range;
  final String newText;

  const EditorTextEdit({required this.range, required this.newText});

  factory EditorTextEdit.fromJson(Map<String, dynamic> json) {
    final explicitRange = json['range'];
    if (explicitRange is Map) {
      return EditorTextEdit(
        range: DocumentRange.fromJson(Map<String, dynamic>.from(explicitRange)),
        newText: json['newText'] as String? ?? '',
      );
    }

    final replace = json['replace'];
    if (replace is Map) {
      return EditorTextEdit(
        range: DocumentRange.fromJson(Map<String, dynamic>.from(replace)),
        newText: json['newText'] as String? ?? '',
      );
    }

    final insert = json['insert'];
    if (insert is Map) {
      return EditorTextEdit(
        range: DocumentRange.fromJson(Map<String, dynamic>.from(insert)),
        newText: json['newText'] as String? ?? '',
      );
    }

    return const EditorTextEdit(
      range: DocumentRange(
        start: DocumentPosition(line: 0, character: 0),
        end: DocumentPosition(line: 0, character: 0),
      ),
      newText: '',
    );
  }

  Map<String, dynamic> toJson() => {
    'range': range.toJson(),
    'newText': newText,
  };
}

class EditorWorkspaceEdit {
  final Map<String, List<EditorTextEdit>> changes;

  const EditorWorkspaceEdit({required this.changes});

  factory EditorWorkspaceEdit.fromJson(Map<String, dynamic> json) {
    final changes = <String, List<EditorTextEdit>>{};
    final rawChanges = json['changes'];
    if (rawChanges is Map) {
      for (final entry in rawChanges.entries) {
        final edits = <EditorTextEdit>[];
        if (entry.value is List) {
          for (final edit in entry.value as List) {
            if (edit is Map) {
              edits.add(
                EditorTextEdit.fromJson(Map<String, dynamic>.from(edit)),
              );
            }
          }
        }
        changes[entry.key.toString()] = edits;
      }
    }

    final rawDocumentChanges = json['documentChanges'];
    if (rawDocumentChanges is List) {
      for (final change in rawDocumentChanges) {
        if (change is! Map) {
          continue;
        }
        final map = Map<String, dynamic>.from(change);
        final textDocument = map['textDocument'];
        final edits = map['edits'];
        final uri = textDocument is Map
            ? (textDocument['uri'] as String? ?? '')
            : '';
        final path = _pathFromUri(uri);
        if (path.isEmpty || edits is! List) {
          continue;
        }
        final parsedEdits = changes.putIfAbsent(path, () => <EditorTextEdit>[]);
        for (final edit in edits) {
          if (edit is Map) {
            parsedEdits.add(
              EditorTextEdit.fromJson(Map<String, dynamic>.from(edit)),
            );
          }
        }
      }
    }

    return EditorWorkspaceEdit(changes: changes);
  }

  bool get isEmpty => changes.values.every((edits) => edits.isEmpty);
}

class EditorHover {
  final dynamic contents;
  final DocumentRange? range;

  const EditorHover({required this.contents, this.range});

  factory EditorHover.fromJson(Map<String, dynamic> json) {
    final rawRange = json['range'];
    return EditorHover(
      contents: json['contents'],
      range: rawRange is Map
          ? DocumentRange.fromJson(Map<String, dynamic>.from(rawRange))
          : null,
    );
  }

  String get plainText => _stringifyMarkup(contents).trim();
}

class EditorCompletionList {
  final bool isIncomplete;
  final List<EditorCompletionItem> items;

  const EditorCompletionList({required this.isIncomplete, required this.items});

  factory EditorCompletionList.fromJson(Map<String, dynamic> json) {
    final items = <EditorCompletionItem>[];
    final rawItems = json['items'];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is Map) {
          items.add(
            EditorCompletionItem.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    return EditorCompletionList(
      isIncomplete: json['isIncomplete'] as bool? ?? false,
      items: items,
    );
  }
}

class EditorCompletionItem {
  final String label;
  final String detail;
  final String? insertText;
  final EditorTextEdit? textEdit;
  final List<EditorTextEdit> additionalTextEdits;
  final dynamic documentation;
  final Map<String, dynamic> raw;

  const EditorCompletionItem({
    required this.label,
    required this.detail,
    required this.insertText,
    required this.textEdit,
    required this.additionalTextEdits,
    required this.documentation,
    required this.raw,
  });

  factory EditorCompletionItem.fromJson(Map<String, dynamic> json) {
    final rawAdditional = json['additionalTextEdits'];
    final additionalTextEdits = <EditorTextEdit>[];
    if (rawAdditional is List) {
      for (final edit in rawAdditional) {
        if (edit is Map) {
          additionalTextEdits.add(
            EditorTextEdit.fromJson(Map<String, dynamic>.from(edit)),
          );
        }
      }
    }

    EditorTextEdit? textEdit;
    final rawTextEdit = json['textEdit'];
    if (rawTextEdit is Map) {
      textEdit = EditorTextEdit.fromJson(
        Map<String, dynamic>.from(rawTextEdit),
      );
    }

    final label = json['label'];
    return EditorCompletionItem(
      label: label is String ? label : jsonEncode(label),
      detail: json['detail'] as String? ?? '',
      insertText: json['insertText'] as String?,
      textEdit: textEdit,
      additionalTextEdits: additionalTextEdits,
      documentation: json['documentation'],
      raw: Map<String, dynamic>.from(json),
    );
  }

  String get documentationText => _stringifyMarkup(documentation).trim();
}

class EditorCodeAction {
  final String title;
  final String kind;
  final EditorWorkspaceEdit? edit;
  final Map<String, dynamic> raw;

  const EditorCodeAction({
    required this.title,
    required this.kind,
    required this.raw,
    this.edit,
  });

  factory EditorCodeAction.fromJson(Map<String, dynamic> json) {
    final rawEdit = json['edit'];
    return EditorCodeAction(
      title: json['title'] as String? ?? 'Untitled action',
      kind: json['kind'] as String? ?? '',
      edit: rawEdit is Map
          ? EditorWorkspaceEdit.fromJson(Map<String, dynamic>.from(rawEdit))
          : null,
      raw: Map<String, dynamic>.from(json),
    );
  }

  bool get isQuickFix => kind == 'quickfix' || kind.startsWith('quickfix.');
}

class EditorSignatureHelp {
  final List<String> signatures;
  final int activeSignature;
  final int activeParameter;

  const EditorSignatureHelp({
    required this.signatures,
    required this.activeSignature,
    required this.activeParameter,
  });

  factory EditorSignatureHelp.fromJson(Map<String, dynamic> json) {
    final signatures = <String>[];
    final rawSignatures = json['signatures'];
    if (rawSignatures is List) {
      for (final signature in rawSignatures) {
        if (signature is Map) {
          final label = signature['label'] as String?;
          if (label != null && label.isNotEmpty) {
            signatures.add(label);
          }
        } else if (signature is String && signature.isNotEmpty) {
          signatures.add(signature);
        }
      }
    }
    return EditorSignatureHelp(
      signatures: signatures,
      activeSignature: json['activeSignature'] as int? ?? 0,
      activeParameter: json['activeParameter'] as int? ?? 0,
    );
  }

  String? get activeLabel {
    if (signatures.isEmpty) {
      return null;
    }
    final index = activeSignature.clamp(0, signatures.length - 1);
    return signatures[index];
  }
}

String _pathFromUri(String uri) {
  if (uri.isEmpty) {
    return '';
  }
  try {
    return Uri.parse(uri).path;
  } catch (_) {
    return uri;
  }
}

String _stringifyMarkup(dynamic value) {
  if (value == null) {
    return '';
  }
  if (value is String) {
    return value;
  }
  if (value is List) {
    return value
        .map(_stringifyMarkup)
        .where((part) => part.isNotEmpty)
        .join('\n\n');
  }
  if (value is Map) {
    final map = Map<String, dynamic>.from(value);
    final preferred = map['value'] ?? map['language'] ?? map['kind'];
    if (preferred is String && preferred.isNotEmpty) {
      return preferred;
    }
  }
  return value.toString();
}
