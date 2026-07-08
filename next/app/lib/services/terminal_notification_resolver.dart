import '../notification.dart';
import '../models.dart';
import '../state/terminal_hub.dart';

Future<BackendTerminalSession?> resolveTerminalForNotification({
  required TerminalHub terminalHub,
  required OpenTerminalAction action,
  String? activeBackendId,
  bool Function()? isMounted,
}) async {
  final scopedBackendId = _nonEmpty(action.backendId);
  final activeId = _nonEmpty(activeBackendId);

  var ref = _terminalSessionForNotification(
    terminalHub: terminalHub,
    action: action,
    backendId: scopedBackendId,
    activeBackendId: activeId,
  );
  if (ref != null) return ref;

  await terminalHub.refreshAll();
  if (isMounted != null && !isMounted()) return null;

  ref = _terminalSessionForNotification(
    terminalHub: terminalHub,
    action: action,
    backendId: scopedBackendId,
    activeBackendId: activeId,
  );
  if (ref != null) return ref;

  final externalSessionId = _nonEmpty(action.externalSessionId);
  final adoptBackendId = scopedBackendId ?? activeId;
  if (externalSessionId == null || adoptBackendId == null) return null;

  final adopted = await terminalHub.adoptExternalSession(
    backendId: adoptBackendId,
    sessionName: externalSessionId,
    cols: 80,
    rows: 24,
  );
  if (isMounted != null && !isMounted()) return null;
  if (adopted == null) return null;

  return terminalHub.sessionFor(adoptBackendId, adopted.id) ??
      terminalHub.sessionForExternalSessionId(
        adoptBackendId,
        externalSessionId,
      );
}

BackendTerminalSession? _terminalSessionForNotification({
  required TerminalHub terminalHub,
  required OpenTerminalAction action,
  String? backendId,
  String? activeBackendId,
}) {
  final scopedBackendId = _nonEmpty(backendId);
  if (scopedBackendId != null) {
    return _terminalSessionForBackend(terminalHub, scopedBackendId, action);
  }

  final sessionId = _nonEmpty(action.sessionId);
  if (sessionId != null) {
    final byId = _uniquePreferredSession(
      _sessionsWhere(terminalHub, (session) => session.id == sessionId),
      activeBackendId: _nonEmpty(activeBackendId),
    );
    if (byId != null) return byId;
  }

  final externalSessionId = _nonEmpty(action.externalSessionId);
  if (externalSessionId == null) return null;
  return _uniquePreferredSession(
    _sessionsWhere(
      terminalHub,
      (session) => session.externalSessionId == externalSessionId,
    ),
    activeBackendId: _nonEmpty(activeBackendId),
  );
}

BackendTerminalSession? _terminalSessionForBackend(
  TerminalHub terminalHub,
  String backendId,
  OpenTerminalAction action,
) {
  final sessionId = _nonEmpty(action.sessionId);
  if (sessionId != null) {
    final byId = terminalHub.sessionFor(backendId, sessionId);
    if (byId != null) return byId;
  }

  final externalSessionId = _nonEmpty(action.externalSessionId);
  if (externalSessionId == null) return null;
  return terminalHub.sessionForExternalSessionId(backendId, externalSessionId);
}

Iterable<BackendTerminalSession> _sessionsWhere(
  TerminalHub terminalHub,
  bool Function(TerminalSession session) predicate,
) sync* {
  for (final group in terminalHub.groups) {
    for (final session in group.sessions) {
      if (predicate(session)) {
        yield BackendTerminalSession(backend: group.backend, session: session);
      }
    }
  }
}

BackendTerminalSession? _uniquePreferredSession(
  Iterable<BackendTerminalSession> matches, {
  String? activeBackendId,
}) {
  final list = matches.toList(growable: false);
  if (list.length == 1) return list.single;
  final activeId = _nonEmpty(activeBackendId);
  if (activeId == null) return null;
  final activeMatches = list
      .where((match) => match.backendId == activeId)
      .toList(growable: false);
  return activeMatches.length == 1 ? activeMatches.single : null;
}

String? _nonEmpty(String? value) {
  if (value == null || value.isEmpty) return null;
  return value;
}
