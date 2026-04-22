import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/diagnostic.dart';
import '../models/editor_context.dart';
import '../models/editor_models.dart';
import '../models/chat_message.dart';
import '../services/api_client.dart';
import '../services/editor_api_client.dart';

class OpenFile {
  final String path;
  final String name;
  String originalContent;
  String currentContent;
  int version;
  bool isEditing;
  bool bridgeTracking;
  EditorCursor cursor;
  EditorSelection? selection;
  EditorSelection? revealSelection;
  int revealNonce;
  List<Diagnostic> diagnostics;

  OpenFile({
    required this.path,
    required this.name,
    required this.originalContent,
    required this.currentContent,
    required this.version,
    this.isEditing = false,
    this.bridgeTracking = false,
    EditorCursor? cursor,
    this.selection,
    this.revealSelection,
    this.revealNonce = 0,
    List<Diagnostic>? diagnostics,
  }) : cursor = cursor ?? const EditorCursor(line: 1, column: 1),
       diagnostics = diagnostics ?? <Diagnostic>[];

  bool get hasUnsavedChanges => currentContent != originalContent;
}

class EditorJumpLocation {
  final String path;
  final EditorSelection? selection;
  final EditorCursor? cursor;

  const EditorJumpLocation({required this.path, this.selection, this.cursor});
}

class EditorProvider extends ChangeNotifier {
  EditorProvider({required this.apiClient, required this.editorApiClient}) {
    unawaited(refreshCapabilities());
    _connectEvents();
  }

  final ApiClient apiClient;
  final EditorApiClient editorApiClient;

  final List<OpenFile> _openFiles = <OpenFile>[];
  final List<EditorJumpLocation> _jumpHistory = <EditorJumpLocation>[];
  final Set<String> _syncingPaths = <String>{};
  final Map<String, String> _pendingContentSync = <String, String>{};
  final Map<String, Completer<void>> _syncCompleters =
      <String, Completer<void>>{};

  WebSocketChannel? _eventsChannel;
  StreamSubscription<dynamic>? _eventsSubscription;
  Future<void> _eventsTeardown = Future<void>.value();
  BridgeCapabilitiesDocument? _capabilities;
  int _currentFileIndex = -1;
  bool _isLoading = false;
  String? _error;
  bool _isLoadingDiagnostics = false;
  bool _isLoadingCompletions = false;
  EditorHover? _hover;
  EditorSignatureHelp? _signatureHelp;
  List<EditorCompletionItem> _completionItems = <EditorCompletionItem>[];
  List<EditorLocation> _lastLocations = <EditorLocation>[];
  String _lastLocationLabel = 'Locations';
  bool _isDisposed = false;

  List<OpenFile> get openFiles => List.unmodifiable(_openFiles);
  OpenFile? get currentFile =>
      _currentFileIndex >= 0 && _currentFileIndex < _openFiles.length
      ? _openFiles[_currentFileIndex]
      : null;
  int get currentFileIndex => _currentFileIndex;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isLoadingDiagnostics => _isLoadingDiagnostics;
  bool get isLoadingCompletions => _isLoadingCompletions;
  List<Diagnostic> get diagnostics =>
      List.unmodifiable(currentFile?.diagnostics ?? const <Diagnostic>[]);
  List<Diagnostic> get allDiagnostics =>
      _openFiles.expand((file) => file.diagnostics).toList(growable: false);
  EditorCursor? get cursor => currentFile?.cursor;
  EditorSelection? get selection => currentFile?.selection;
  EditorSelection? get revealSelection => currentFile?.revealSelection;
  int get revealNonce => currentFile?.revealNonce ?? 0;
  BridgeCapabilitiesDocument? get capabilities => _capabilities;
  EditorHover? get hover => _hover;
  EditorSignatureHelp? get signatureHelp => _signatureHelp;
  List<EditorCompletionItem> get completionItems =>
      List.unmodifiable(_completionItems);
  List<EditorLocation> get lastLocations => List.unmodifiable(_lastLocations);
  String get lastLocationLabel => _lastLocationLabel;
  bool get canJumpBack => _jumpHistory.isNotEmpty;
  bool get hasUnsavedChanges =>
      _openFiles.any((file) => file.hasUnsavedChanges);

  EditorChatContext get chatContext => EditorChatContext(
    activeFile: currentFile?.path,
    cursor: currentFile?.cursor,
    selection: currentFile?.selection,
  );

  bool capabilityEnabled(
    String name, [
    Iterable<String> aliases = const <String>[],
  ]) {
    final capabilities = _capabilities;
    if (capabilities == null) {
      return false;
    }
    return capabilities.isEnabled(name, aliases);
  }

  String? capabilityReason(
    String name, [
    Iterable<String> aliases = const <String>[],
  ]) {
    final capabilities = _capabilities;
    if (capabilities == null) {
      return null;
    }
    final capability = capabilities.capability(name, aliases);
    if (capability != null &&
        capability.reason != null &&
        capability.reason!.isNotEmpty) {
      return capability.reason;
    }
    return null;
  }

  String unavailableMessage(String feature) {
    final capabilities = _capabilities;
    if (capabilities == null) {
      return 'Editor bridge is not ready for $feature.';
    }
    final normalized = feature
        .toLowerCase()
        .replaceAll(' ', '')
        .replaceAll('-', '');
    return capabilityReason(normalized) ??
        '$feature is unavailable for the current bridge session.';
  }

  void clearError() {
    if (_error == null) {
      return;
    }
    _error = null;
    notifyListeners();
  }

  Future<void> refreshCapabilities() async {
    try {
      _capabilities = await editorApiClient.getCapabilities();
      _error = null;
    } catch (error) {
      _capabilities = null;
      _error = error.toString();
    }
    notifyListeners();
  }

  Future<void> openFile(String path) => openFileAt(path);

  Future<void> openFileAt(
    String path, {
    EditorSelection? selection,
    EditorCursor? cursor,
    int? line,
    int? offset,
    int? limit,
    bool recordJump = true,
  }) async {
    if (recordJump) {
      _recordCurrentLocation();
    }

    final existingIndex = _openFiles.indexWhere((file) => file.path == path);
    if (existingIndex >= 0) {
      _currentFileIndex = existingIndex;
      final file = _openFiles[existingIndex];
      _applyReveal(
        file,
        selection: selection,
        cursor: cursor,
        line: line,
        offset: offset,
        limit: limit,
      );
      _clearTransientUi();
      notifyListeners();
      unawaited(loadDiagnostics());
      return;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final content = await apiClient.readFile(path);
      var version = 1;
      var bridgeTracking = false;
      try {
        final snapshot = await editorApiClient.openDocument(
          path: path,
          version: 1,
          content: content,
        );
        version = snapshot.version;
        bridgeTracking = true;
      } catch (_) {
        // Keep local editing available even when the bridge is not ready.
      }

      final file = OpenFile(
        path: path,
        name: path.split('/').last,
        originalContent: content,
        currentContent: content,
        version: version,
        bridgeTracking: bridgeTracking,
      );
      _openFiles.add(file);
      _currentFileIndex = _openFiles.length - 1;
      _applyReveal(
        file,
        selection: selection,
        cursor: cursor,
        line: line,
        offset: offset,
        limit: limit,
      );
      _clearTransientUi();
      unawaited(loadDiagnostics());
    } catch (error) {
      _error = error.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> closeFile(int index) async {
    if (index < 0 || index >= _openFiles.length) {
      return false;
    }

    final file = _openFiles[index];
    _pendingContentSync.remove(file.path);
    await _flushDocument(file.path);
    if (file.bridgeTracking) {
      try {
        await editorApiClient.closeDocument(file.path);
      } catch (_) {
        // Closing the local UI should still succeed if the bridge session vanished.
      }
    }

    _openFiles.removeAt(index);
    if (_currentFileIndex >= _openFiles.length) {
      _currentFileIndex = _openFiles.length - 1;
    } else if (_currentFileIndex > index) {
      _currentFileIndex -= 1;
    }
    _clearTransientUi();
    notifyListeners();
    return true;
  }

  void switchToFile(int index) {
    if (index < 0 || index >= _openFiles.length) {
      return;
    }
    _currentFileIndex = index;
    _clearTransientUi();
    notifyListeners();
    unawaited(loadDiagnostics());
  }

  void toggleEditMode() {
    final file = currentFile;
    if (file == null) {
      return;
    }
    file.isEditing = !file.isEditing;
    notifyListeners();
  }

  void enterEditMode() {
    final file = currentFile;
    if (file == null) {
      return;
    }
    file.isEditing = true;
    notifyListeners();
  }

  void exitEditMode() {
    final file = currentFile;
    if (file == null) {
      return;
    }
    file.isEditing = false;
    notifyListeners();
  }

  void updateContent(String content) {
    final file = currentFile;
    if (file == null || content == file.currentContent) {
      return;
    }

    final previousContent = file.currentContent;
    file.currentContent = content;
    _queueDocumentSync(file.path, content);
    notifyListeners();

    final insertedCharacter = _detectSingleInsertedCharacter(
      previousContent,
      content,
    );
    if (insertedCharacter == '.') {
      unawaited(requestCompletion());
    }
    if (insertedCharacter == '(' || insertedCharacter == ',') {
      unawaited(requestSignatureHelp());
    }
  }

  void updateCursor(EditorCursor? cursor) {
    final file = currentFile;
    if (file == null || cursor == null) {
      return;
    }
    file.cursor = cursor;
    if (file.selection?.isCollapsed ?? false) {
      file.selection = null;
    }
    notifyListeners();
  }

  void updateSelection(EditorSelection? selection, {EditorCursor? cursor}) {
    final file = currentFile;
    if (file == null) {
      return;
    }
    file.selection = selection;
    if (cursor != null) {
      file.cursor = cursor;
    }
    notifyListeners();
  }

  void clearSelection() {
    final file = currentFile;
    if (file == null) {
      return;
    }
    file.selection = null;
    notifyListeners();
  }

  Future<bool> saveCurrentFile() async {
    final file = currentFile;
    if (file == null) {
      return false;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _flushDocument(file.path);
      if (file.bridgeTracking) {
        final snapshot = await editorApiClient.saveDocument(file.path);
        file.version = snapshot.version;
      } else {
        await apiClient.writeFile(file.path, file.currentContent);
      }
      file.originalContent = file.currentContent;
      await loadDiagnostics();
      return true;
    } catch (error) {
      _error = error.toString();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadDiagnostics() async {
    final file = currentFile;
    if (file == null) {
      return;
    }

    _isLoadingDiagnostics = true;
    notifyListeners();

    try {
      if (file.bridgeTracking && capabilityEnabled('diagnostics')) {
        await _flushDocument(file.path);
        file.diagnostics = await editorApiClient.diagnostics(
          path: file.path,
          version: file.version,
          workDir: _extractWorkDir(file.path),
        );
      } else {
        final legacy = await apiClient.getDiagnostics(
          filePath: file.path,
          workDir: _extractWorkDir(file.path),
        );
        file.diagnostics = legacy;
      }
      _error = null;
    } catch (error) {
      _error = error.toString();
      file.diagnostics = <Diagnostic>[];
    } finally {
      _isLoadingDiagnostics = false;
      notifyListeners();
    }
  }

  List<Diagnostic> diagnosticsForLine(int line) {
    return diagnostics
        .where((diagnostic) => diagnostic.range.containsLine(line))
        .toList();
  }

  Future<List<EditorCompletionItem>> requestCompletion() async {
    final file = currentFile;
    if (file == null) {
      return const <EditorCompletionItem>[];
    }
    if (!file.bridgeTracking || !capabilityEnabled('completion')) {
      _error = unavailableMessage('Completion');
      _completionItems = <EditorCompletionItem>[];
      notifyListeners();
      return const <EditorCompletionItem>[];
    }

    _isLoadingCompletions = true;
    notifyListeners();
    try {
      await _flushDocument(file.path);
      final result = await editorApiClient.completion(
        path: file.path,
        version: file.version,
        position: DocumentPosition.fromCursor(file.cursor),
        workDir: _extractWorkDir(file.path),
      );
      _completionItems = result.items;
      return _completionItems;
    } catch (error) {
      _error = error.toString();
      _completionItems = <EditorCompletionItem>[];
      return const <EditorCompletionItem>[];
    } finally {
      _isLoadingCompletions = false;
      notifyListeners();
    }
  }

  void clearCompletionItems() {
    if (_completionItems.isEmpty) {
      return;
    }
    _completionItems = <EditorCompletionItem>[];
    notifyListeners();
  }

  Future<bool> applyCompletionItem(EditorCompletionItem item) async {
    final file = currentFile;
    if (file == null) {
      return false;
    }

    final edits = <EditorTextEdit>[
      if (item.textEdit != null) item.textEdit!,
      ...item.additionalTextEdits,
    ];

    if (edits.isEmpty) {
      edits.add(
        EditorTextEdit(
          range: DocumentRange(
            start: DocumentPosition.fromCursor(file.cursor),
            end: DocumentPosition.fromCursor(file.cursor),
          ),
          newText: item.insertText ?? item.label,
        ),
      );
    }

    final applied = await applyTextEdits(file.path, edits, recordJump: false);
    if (applied) {
      _completionItems = <EditorCompletionItem>[];
      await requestSignatureHelp();
      notifyListeners();
    }
    return applied;
  }

  Future<EditorHover?> requestHover() async {
    final file = currentFile;
    if (file == null) {
      return null;
    }
    if (!file.bridgeTracking || !capabilityEnabled('hover')) {
      _error = unavailableMessage('Hover');
      notifyListeners();
      return null;
    }

    try {
      await _flushDocument(file.path);
      _hover = await editorApiClient.hover(
        path: file.path,
        version: file.version,
        position: DocumentPosition.fromCursor(file.cursor),
        workDir: _extractWorkDir(file.path),
      );
      notifyListeners();
      return _hover;
    } catch (error) {
      _error = error.toString();
      notifyListeners();
      return null;
    }
  }

  void clearHover() {
    if (_hover == null) {
      return;
    }
    _hover = null;
    notifyListeners();
  }

  Future<EditorSignatureHelp?> requestSignatureHelp() async {
    final file = currentFile;
    if (file == null) {
      return null;
    }
    if (!file.bridgeTracking ||
        !capabilityEnabled('signatureHelp', <String>['signature-help'])) {
      _signatureHelp = null;
      notifyListeners();
      return null;
    }

    try {
      await _flushDocument(file.path);
      _signatureHelp = await editorApiClient.signatureHelp(
        path: file.path,
        version: file.version,
        position: DocumentPosition.fromCursor(file.cursor),
        workDir: _extractWorkDir(file.path),
      );
    } catch (error) {
      _error = error.toString();
      _signatureHelp = null;
    }
    notifyListeners();
    return _signatureHelp;
  }

  Future<List<EditorLocation>> requestDefinition() async {
    return _requestLocations(
      label: 'Definitions',
      capability: 'definition',
      request: (file) => editorApiClient.definition(
        path: file.path,
        version: file.version,
        position: DocumentPosition.fromCursor(file.cursor),
        workDir: _extractWorkDir(file.path),
      ),
    );
  }

  Future<List<EditorLocation>> requestReferences() async {
    return _requestLocations(
      label: 'References',
      capability: 'references',
      request: (file) => editorApiClient.references(
        path: file.path,
        version: file.version,
        position: DocumentPosition.fromCursor(file.cursor),
        workDir: _extractWorkDir(file.path),
      ),
    );
  }

  Future<bool> jumpBack() async {
    if (_jumpHistory.isEmpty) {
      return false;
    }
    final target = _jumpHistory.removeLast();
    await openFileAt(
      target.path,
      selection: target.selection,
      cursor: target.cursor,
      recordJump: false,
    );
    return true;
  }

  Future<bool> formatCurrentFile() async {
    final file = currentFile;
    if (file == null) {
      return false;
    }
    if (!file.bridgeTracking || !capabilityEnabled('formatting')) {
      _error = unavailableMessage('Formatting');
      notifyListeners();
      return false;
    }
    try {
      await _flushDocument(file.path);
      final edits = await editorApiClient.formatting(
        path: file.path,
        version: file.version,
        workDir: _extractWorkDir(file.path),
      );
      return applyTextEdits(file.path, edits, recordJump: false);
    } catch (error) {
      _error = error.toString();
      notifyListeners();
      return false;
    }
  }

  Future<List<EditorCodeAction>> loadCodeActions({
    bool quickFixOnly = false,
  }) async {
    final file = currentFile;
    if (file == null) {
      return const <EditorCodeAction>[];
    }
    if (!file.bridgeTracking ||
        !capabilityEnabled('codeActions', <String>['code-actions'])) {
      _error = unavailableMessage('Code actions');
      notifyListeners();
      return const <EditorCodeAction>[];
    }

    final effectiveSelection =
        file.selection ?? EditorSelection(start: file.cursor, end: file.cursor);

    try {
      await _flushDocument(file.path);
      final actions = await editorApiClient.codeActions(
        path: file.path,
        version: file.version,
        range: DocumentRange.fromSelection(effectiveSelection),
        workDir: _extractWorkDir(file.path),
      );
      if (quickFixOnly) {
        return actions.where((action) => action.isQuickFix).toList();
      }
      return actions;
    } catch (error) {
      _error = error.toString();
      notifyListeners();
      return const <EditorCodeAction>[];
    }
  }

  Future<bool> applyCodeAction(EditorCodeAction action) async {
    final edit = action.edit;
    if (edit == null || edit.isEmpty) {
      return false;
    }
    return applyWorkspaceEdit(edit, recordJump: false);
  }

  Future<bool> renameSymbol(String newName) async {
    final file = currentFile;
    if (file == null) {
      return false;
    }
    if (!file.bridgeTracking || !capabilityEnabled('rename')) {
      _error = unavailableMessage('Rename');
      notifyListeners();
      return false;
    }
    try {
      await _flushDocument(file.path);
      final edit = await editorApiClient.rename(
        path: file.path,
        version: file.version,
        position: DocumentPosition.fromCursor(file.cursor),
        workDir: _extractWorkDir(file.path),
        newName: newName,
      );
      return applyWorkspaceEdit(edit, recordJump: false);
    } catch (error) {
      _error = error.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> applyWorkspaceEdit(
    EditorWorkspaceEdit edit, {
    bool recordJump = true,
  }) async {
    var success = true;
    for (final entry in edit.changes.entries) {
      final applied = await applyTextEdits(
        entry.key,
        entry.value,
        recordJump: recordJump,
      );
      success = success && applied;
    }
    return success;
  }

  Future<bool> applyTextEdits(
    String path,
    List<EditorTextEdit> edits, {
    bool recordJump = true,
  }) async {
    if (edits.isEmpty) {
      return true;
    }

    await openFileAt(path, recordJump: recordJump);
    final file = currentFile;
    if (file == null || file.path != path) {
      return false;
    }

    try {
      final updated = _applyTextEditsToContent(file.currentContent, edits);
      updateContent(updated);
      final focusSelection = edits.last.range.toSelection();
      updateSelection(focusSelection, cursor: focusSelection.end);
      file.revealSelection = focusSelection;
      file.revealNonce += 1;
      notifyListeners();
      return true;
    } catch (error) {
      _error = error.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> openAnnotation(String path, FileAnnotation? annotation) async {
    await openFileAt(
      path,
      offset: annotation?.offset,
      limit: annotation?.limit,
      recordJump: true,
    );
  }

  Future<void> openLocation(EditorLocation location, {bool recordJump = true}) {
    return openFileAt(
      location.path,
      selection: location.range.toSelection(),
      cursor: location.range.start.toCursor(),
      recordJump: recordJump,
    );
  }

  Future<void> openDiagnostic(Diagnostic diagnostic, {bool recordJump = true}) {
    return openFileAt(
      diagnostic.filePath,
      selection: diagnostic.range.toSelection(),
      cursor: diagnostic.range.start.toCursor(),
      recordJump: recordJump,
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    unawaited(_disconnectEvents());
    super.dispose();
  }

  Future<List<EditorLocation>> _requestLocations({
    required String label,
    required String capability,
    required Future<List<EditorLocation>> Function(OpenFile file) request,
  }) async {
    final file = currentFile;
    if (file == null) {
      return const <EditorLocation>[];
    }
    if (!file.bridgeTracking || !capabilityEnabled(capability)) {
      _error = unavailableMessage(label);
      notifyListeners();
      return const <EditorLocation>[];
    }

    try {
      await _flushDocument(file.path);
      _lastLocations = await request(file);
      _lastLocationLabel = label;
    } catch (error) {
      _error = error.toString();
      _lastLocations = <EditorLocation>[];
    }
    notifyListeners();
    return _lastLocations;
  }

  void _recordCurrentLocation() {
    final file = currentFile;
    if (file == null) {
      return;
    }
    _jumpHistory.add(
      EditorJumpLocation(
        path: file.path,
        selection: file.selection,
        cursor: file.cursor,
      ),
    );
  }

  void _clearTransientUi() {
    _completionItems = <EditorCompletionItem>[];
    _hover = null;
    _signatureHelp = null;
    _lastLocations = <EditorLocation>[];
    _lastLocationLabel = 'Locations';
  }

  void _connectEvents() {
    unawaited(_reconnectEvents());
  }

  void _onBridgeEvent(dynamic raw) {
    if (_isDisposed || raw is! String) {
      return;
    }
    unawaited(_handleBridgeEvent(raw));
  }

  Future<void> _handleBridgeEvent(String raw) async {
    if (_isDisposed) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final event = BridgeEventEnvelope.fromJson(decoded);
      if (event.type == 'bridge/ready' || event.type == 'bridge/restarted') {
        await refreshCapabilities();
        await _reopenBridgeDocuments();
        return;
      }
      if (event.type != 'document/diagnosticsChanged' &&
          event.type != 'bridge/editor/diagnosticsChanged' &&
          event.type != 'bridge/diagnosticsChanged') {
        return;
      }
      final payload = event.payload;
      if (payload is! Map) {
        return;
      }
      final report = Map<String, dynamic>.from(payload);
      final path = report['file'] as String? ?? report['path'] as String? ?? '';
      OpenFile? file;
      for (final candidate in _openFiles) {
        if (candidate.path == path) {
          file = candidate;
          break;
        }
      }
      if (file == null) {
        return;
      }
      file.diagnostics = Diagnostic.listFromReportJson(report);
      if (!_isDisposed) {
        notifyListeners();
      }
    } catch (_) {
      // Ignore malformed bridge events.
    }
  }

  Future<void> _reconnectEvents() async {
    await _disconnectEvents();
    if (_isDisposed) {
      return;
    }
    try {
      final channel = editorApiClient.connectEventsWebSocket();
      if (_isDisposed) {
        await channel.sink.close();
        return;
      }
      _eventsChannel = channel;
      _eventsSubscription = channel.stream.listen(
        _onBridgeEvent,
        onError: (_) {},
        onDone: () {},
      );
    } catch (_) {
      _eventsChannel = null;
      _eventsSubscription = null;
    }
  }

  Future<void> _disconnectEvents() {
    _eventsTeardown = _eventsTeardown.then((_) async {
      final subscription = _eventsSubscription;
      final channel = _eventsChannel;
      _eventsSubscription = null;
      _eventsChannel = null;

      if (subscription != null) {
        try {
          await subscription.cancel();
        } catch (_) {
          // Best-effort teardown; reconnection will self-heal.
        }
      }
      if (channel != null) {
        try {
          await channel.sink.close();
        } catch (_) {
          // The socket may already be closing; ignore teardown races.
        }
      }
    });
    return _eventsTeardown;
  }

  Future<void> _reopenBridgeDocuments() async {
    for (final file in _openFiles) {
      try {
        final snapshot = await editorApiClient.openDocument(
          path: file.path,
          version: 1,
          content: file.currentContent,
        );
        file.version = snapshot.version;
        file.bridgeTracking = true;
      } catch (_) {
        file.bridgeTracking = false;
      }
    }
    if (currentFile != null) {
      await loadDiagnostics();
    } else {
      notifyListeners();
    }
  }

  void _queueDocumentSync(String path, String content) {
    final file = _fileForPath(path);
    if (file == null || !file.bridgeTracking) {
      return;
    }
    _pendingContentSync[path] = content;
    _syncCompleters.putIfAbsent(path, Completer<void>.new);
    if (_syncingPaths.contains(path)) {
      return;
    }
    unawaited(_drainDocumentSync(path));
  }

  Future<void> _drainDocumentSync(String path) async {
    final file = _fileForPath(path);
    if (file == null) {
      _completeSync(path);
      return;
    }

    _syncingPaths.add(path);
    try {
      while (true) {
        final pending = _pendingContentSync.remove(path);
        if (pending == null) {
          break;
        }
        final nextVersion = file.version + 1;
        try {
          final snapshot = await editorApiClient.changeDocument(
            path: path,
            version: nextVersion,
            changes: <DocumentChange>[DocumentChange.fullReplacement(pending)],
          );
          file.version = snapshot.version;
        } catch (error) {
          _error = error.toString();
          break;
        }
      }
    } finally {
      _syncingPaths.remove(path);
      _completeSync(path);
      notifyListeners();
    }
  }

  Future<void> _flushDocument(String path) async {
    final pending = _syncCompleters[path];
    if (pending == null) {
      return;
    }
    if (!_pendingContentSync.containsKey(path) &&
        !_syncingPaths.contains(path)) {
      _completeSync(path);
      return;
    }
    await pending.future;
  }

  void _completeSync(String path) {
    final completer = _syncCompleters.remove(path);
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  OpenFile? _fileForPath(String path) {
    for (final file in _openFiles) {
      if (file.path == path) {
        return file;
      }
    }
    return null;
  }

  void _applyReveal(
    OpenFile file, {
    EditorSelection? selection,
    EditorCursor? cursor,
    int? line,
    int? offset,
    int? limit,
  }) {
    var effectiveSelection = selection;
    var effectiveCursor = cursor;

    if (effectiveSelection == null && line != null) {
      final collapsed = EditorCursor(line: line, column: 1);
      effectiveSelection = EditorSelection(start: collapsed, end: collapsed);
      effectiveCursor = collapsed;
    }

    if (effectiveSelection == null && offset != null) {
      effectiveSelection = _selectionFromOffset(
        file.currentContent,
        offset,
        limit: limit,
      );
      effectiveCursor = effectiveSelection?.start;
    }

    if (effectiveSelection != null) {
      file.selection = effectiveSelection;
      file.cursor = effectiveCursor ?? effectiveSelection.end;
      file.revealSelection = effectiveSelection;
      file.revealNonce += 1;
      return;
    }

    if (effectiveCursor != null) {
      file.cursor = effectiveCursor;
      file.selection = null;
      file.revealSelection = EditorSelection(
        start: effectiveCursor,
        end: effectiveCursor,
      );
      file.revealNonce += 1;
      return;
    }

    file.cursor = const EditorCursor(line: 1, column: 1);
    file.selection = null;
    file.revealSelection = null;
  }

  EditorSelection? _selectionFromOffset(
    String content,
    int offset, {
    int? limit,
  }) {
    if (content.isEmpty) {
      return null;
    }
    final startOffset = offset.clamp(0, content.length);
    final endOffset = (offset + (limit ?? 0)).clamp(
      startOffset,
      content.length,
    );
    final start = _offsetToCursor(content, startOffset);
    final end = _offsetToCursor(content, endOffset);
    return EditorSelection(start: start, end: end);
  }

  EditorCursor _offsetToCursor(String content, int rawOffset) {
    final clampedOffset = rawOffset.clamp(0, content.length);
    var line = 1;
    var column = 1;
    for (var index = 0; index < clampedOffset; index += 1) {
      if (content.codeUnitAt(index) == 10) {
        line += 1;
        column = 1;
      } else {
        column += 1;
      }
    }
    return EditorCursor(line: line, column: column);
  }

  String _extractWorkDir(String filePath) {
    final parts = filePath.split('/');
    if (parts.length > 1) {
      return parts.sublist(0, parts.length - 1).join('/');
    }
    return '/';
  }

  String? _detectSingleInsertedCharacter(String previous, String current) {
    if (current.length != previous.length + 1) {
      return null;
    }
    final cursor = this.cursor;
    if (cursor == null) {
      return current.substring(current.length - 1);
    }
    final offset = _cursorToOffset(current, cursor).clamp(1, current.length);
    return current.substring(offset - 1, offset);
  }

  int _cursorToOffset(String content, EditorCursor cursor) {
    final targetLine = cursor.line > 0 ? cursor.line : 1;
    final targetColumn = cursor.column > 0 ? cursor.column : 1;
    var line = 1;
    var column = 1;
    for (var index = 0; index < content.length; index += 1) {
      if (line == targetLine && column == targetColumn) {
        return index;
      }
      if (content.codeUnitAt(index) == 10) {
        line += 1;
        column = 1;
      } else {
        column += 1;
      }
    }
    return content.length;
  }

  String _applyTextEditsToContent(String content, List<EditorTextEdit> edits) {
    final sorted = List<EditorTextEdit>.from(edits)
      ..sort((left, right) {
        final leftOffset = _positionToOffset(content, left.range.start);
        final rightOffset = _positionToOffset(content, right.range.start);
        return rightOffset.compareTo(leftOffset);
      });

    var updated = content;
    for (final edit in sorted) {
      final startOffset = _positionToOffset(updated, edit.range.start);
      final endOffset = _positionToOffset(updated, edit.range.end);
      updated = updated.replaceRange(startOffset, endOffset, edit.newText);
    }
    return updated;
  }

  int _positionToOffset(String content, DocumentPosition position) {
    final lines = content.split('\n');
    if (position.line < 0 || position.line > lines.length) {
      throw RangeError('line ${position.line} is out of range');
    }
    if (position.line == lines.length) {
      return content.length;
    }
    var offset = 0;
    for (var index = 0; index < position.line; index += 1) {
      offset += lines[index].length + 1;
    }
    final line = lines[position.line];
    final clampedCharacter = position.character.clamp(0, line.length);
    return offset + clampedCharacter;
  }
}
