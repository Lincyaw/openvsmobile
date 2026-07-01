// Wire-format Notification mirror — what backend `notification.show` /
// `notification.list` push or return. Matches design §4.5 verbatim plus the
// server-assigned fields (`supersededBy`, `readBy`, `ttlUntil`) the backend
// returns on `list` and `show`.
//
// Optional fields parse defensively: unknown keys are ignored (forward-
// compat), wrong types degrade to null rather than throwing — a malformed
// notification should not poison the whole stream. See conventions §5.

enum NotificationLevel { info, success, warning, error }

NotificationLevel _parseLevel(Object? v) {
  switch (v) {
    case 'success':
      return NotificationLevel.success;
    case 'warning':
      return NotificationLevel.warning;
    case 'error':
      return NotificationLevel.error;
    case 'info':
    default:
      // Unknown levels degrade to info rather than throwing — staying
      // forward-compatible with future levels the design might add (debug,
      // trace, …). The user still sees the entry.
      return NotificationLevel.info;
  }
}

String levelToWire(NotificationLevel l) {
  switch (l) {
    case NotificationLevel.success:
      return 'success';
    case NotificationLevel.warning:
      return 'warning';
    case NotificationLevel.error:
      return 'error';
    case NotificationLevel.info:
      return 'info';
  }
}

class NotificationField {
  final String key;
  final String value;
  const NotificationField({required this.key, required this.value});
  factory NotificationField.fromJson(Map<String, dynamic> json) =>
      NotificationField(
        key: json['key'] as String? ?? '',
        value: json['value'] as String? ?? '',
      );
}

class NotificationLink {
  final String title;
  final String url;
  const NotificationLink({required this.title, required this.url});
  factory NotificationLink.fromJson(Map<String, dynamic> json) =>
      NotificationLink(
        title: json['title'] as String? ?? '',
        url: json['url'] as String? ?? '',
      );
}

/// Tap-target for the notification body. Mirrors the backend action sum.
sealed class NotificationAction {
  const NotificationAction();
  static NotificationAction? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    switch (json['kind']) {
      case 'open-url':
        final url = json['url'];
        if (url is String && url.isNotEmpty) {
          return OpenUrlAction(url);
        }
        return null;
      case 'copy':
        final text = json['text'];
        return CopyAction(text is String ? text : '');
      case 'open-workspace':
        final id = json['workspaceId'];
        if (id is String && id.isNotEmpty) {
          return OpenWorkspaceAction(id);
        }
        return null;
      case 'open-terminal':
        final sessionId = json['sessionId'];
        if (sessionId is String && sessionId.isNotEmpty) {
          final backendId = json['backendId'];
          final externalSessionId = json['externalSessionId'];
          return OpenTerminalAction(
            sessionId: sessionId,
            backendId: backendId is String && backendId.isNotEmpty
                ? backendId
                : null,
            externalSessionId:
                externalSessionId is String && externalSessionId.isNotEmpty
                ? externalSessionId
                : null,
          );
        }
        return null;
      default:
        return null;
    }
  }
}

class OpenUrlAction extends NotificationAction {
  final String url;
  const OpenUrlAction(this.url);
}

class CopyAction extends NotificationAction {
  final String text;
  const CopyAction(this.text);
}

class OpenWorkspaceAction extends NotificationAction {
  final String workspaceId;
  const OpenWorkspaceAction(this.workspaceId);
}

class OpenTerminalAction extends NotificationAction {
  final String sessionId;
  final String? backendId;
  final String? externalSessionId;
  const OpenTerminalAction({
    required this.sessionId,
    this.backendId,
    this.externalSessionId,
  });
}

/// One persisted notification entry. Server-assigned fields (`id`,
/// `timestamp`, `supersededBy`, `readBy`, `ttlUntil`) are always present
/// when the backend pushes/returns; sender-only fields are nullable.
///
/// Note: `widget` is held as raw JSON. The §4.3 renderer is not wired in v0
/// — see task brief §"Out of scope".
class AppNotification {
  final String id;
  final String source;
  final NotificationLevel level;
  final String title;
  final String? body;
  final List<NotificationField> fields;
  final List<NotificationLink> links;
  final NotificationAction? action;
  final String? groupKey;
  final String? supersedes;
  final String? supersededBy;
  final bool important;
  final int? ttl;
  final int? ttlUntil;
  final int timestamp;
  final Object? widget;
  final List<String> readBy;

  const AppNotification({
    required this.id,
    required this.source,
    required this.level,
    required this.title,
    required this.timestamp,
    this.body,
    this.fields = const [],
    this.links = const [],
    this.action,
    this.groupKey,
    this.supersedes,
    this.supersededBy,
    this.important = false,
    this.ttl,
    this.ttlUntil,
    this.widget,
    this.readBy = const [],
  });

  bool readByDevice(String deviceId) => readBy.contains(deviceId);

  AppNotification withReadBy(List<String> next) => AppNotification(
    id: id,
    source: source,
    level: level,
    title: title,
    body: body,
    fields: fields,
    links: links,
    action: action,
    groupKey: groupKey,
    supersedes: supersedes,
    supersededBy: supersededBy,
    important: important,
    ttl: ttl,
    ttlUntil: ttlUntil,
    timestamp: timestamp,
    widget: widget,
    readBy: next,
  );

  AppNotification withImportant(bool next) => AppNotification(
    id: id,
    source: source,
    level: level,
    title: title,
    body: body,
    fields: fields,
    links: links,
    action: action,
    groupKey: groupKey,
    supersedes: supersedes,
    supersededBy: supersededBy,
    important: next,
    ttl: ttl,
    ttlUntil: ttlUntil,
    timestamp: timestamp,
    widget: widget,
    readBy: readBy,
  );

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    final fieldsRaw = json['fields'];
    final linksRaw = json['links'];
    final readByRaw = json['readBy'];
    return AppNotification(
      id: json['id'] as String? ?? '',
      source: json['source'] as String? ?? '',
      level: _parseLevel(json['level']),
      title: json['title'] as String? ?? '',
      body: json['body'] as String?,
      fields: fieldsRaw is List
          ? fieldsRaw
                .whereType<Map<String, dynamic>>()
                .map(NotificationField.fromJson)
                .toList(growable: false)
          : const [],
      links: linksRaw is List
          ? linksRaw
                .whereType<Map<String, dynamic>>()
                .map(NotificationLink.fromJson)
                .toList(growable: false)
          : const [],
      action: NotificationAction.fromJson(
        json['action'] is Map<String, dynamic>
            ? json['action'] as Map<String, dynamic>
            : null,
      ),
      groupKey: json['groupKey'] as String?,
      supersedes: json['supersedes'] as String?,
      supersededBy: json['supersededBy'] as String?,
      important: json['important'] == true,
      ttl: (json['ttl'] as num?)?.toInt(),
      ttlUntil: (json['ttlUntil'] as num?)?.toInt(),
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      widget: json['widget'],
      readBy: readByRaw is List
          ? readByRaw.whereType<String>().toList(growable: false)
          : const [],
    );
  }
}
