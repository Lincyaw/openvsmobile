import '../backend_client.dart';

class ConnectionStatusCopy {
  final String title;
  final String? detail;
  final String semanticsLabel;
  final bool loading;

  const ConnectionStatusCopy({
    required this.title,
    required this.semanticsLabel,
    this.detail,
    this.loading = false,
  });
}

ConnectionStatusCopy connectionStatusCopy({
  required BackendConnectionState state,
  String? backendName,
  String? lastError,
}) {
  final target = _targetSuffix(backendName);
  final issue = connectionIssueSummary(lastError);
  final detail = issue == null ? null : 'Last issue: $issue';
  return switch (state) {
    BackendConnectionState.connected => ConnectionStatusCopy(
      title: backendName == null || backendName.trim().isEmpty
          ? 'Connected'
          : '${backendName.trim()} connected',
      semanticsLabel: backendName == null || backendName.trim().isEmpty
          ? 'Backend connected'
          : 'Backend ${backendName.trim()} connected',
    ),
    BackendConnectionState.connecting => ConnectionStatusCopy(
      title: 'Connecting$target…',
      detail: detail,
      semanticsLabel: _joinSemantics('Connecting$target', detail),
      loading: true,
    ),
    BackendConnectionState.reconnecting => ConnectionStatusCopy(
      title: 'Reconnecting$target…',
      detail: detail,
      semanticsLabel: _joinSemantics('Reconnecting$target', detail),
      loading: true,
    ),
    BackendConnectionState.waitingForNetwork => ConnectionStatusCopy(
      title: backendName == null || backendName.trim().isEmpty
          ? 'Waiting for network'
          : 'Waiting for network: ${backendName.trim()}',
      semanticsLabel: backendName == null || backendName.trim().isEmpty
          ? 'Waiting for network'
          : 'Waiting for network: ${backendName.trim()}',
      loading: true,
    ),
    BackendConnectionState.failed => ConnectionStatusCopy(
      title: issue ?? 'Connection failed',
      detail: _rawDetail(lastError, issue),
      semanticsLabel: _joinSemantics(
        issue ?? 'Connection failed',
        _rawDetail(lastError, issue),
      ),
    ),
    BackendConnectionState.disconnected => ConnectionStatusCopy(
      title: backendName == null || backendName.trim().isEmpty
          ? 'Disconnected'
          : '${backendName.trim()} disconnected',
      semanticsLabel: backendName == null || backendName.trim().isEmpty
          ? 'Backend disconnected'
          : 'Backend ${backendName.trim()} disconnected',
    ),
  };
}

String connectionCompactLabel(
  BackendConnectionState state, {
  String? lastError,
}) {
  final issue = connectionIssueSummary(lastError);
  return switch (state) {
    BackendConnectionState.connected => 'connected',
    BackendConnectionState.connecting =>
      issue == null ? 'connecting' : 'connecting: $issue',
    BackendConnectionState.reconnecting =>
      issue == null ? 'reconnecting' : 'reconnecting: $issue',
    BackendConnectionState.waitingForNetwork => 'waiting for network',
    BackendConnectionState.failed => issue ?? 'failed',
    BackendConnectionState.disconnected => issue ?? 'disconnected',
  };
}

String? connectionIssueSummary(String? rawError) {
  final raw = rawError?.trim();
  if (raw == null || raw.isEmpty) return null;
  final text = raw.toLowerCase();
  if (text.contains('no settings configured')) {
    return 'No backend configured';
  }
  if (text.contains('auth failed') ||
      text.contains('unauthorized') ||
      text.contains('token rejected') ||
      text.contains('invalid token')) {
    return 'Token rejected';
  }
  if (_containsAny(text, const [
    'message too large',
    'frame too large',
    'too big',
    'max frame',
    'maximum frame',
    'payload too large',
    'exceeds max',
    'exceeded max',
  ])) {
    return 'Message too large';
  }
  if (text.contains('heartbeat timeout')) {
    return 'Heartbeat timed out';
  }
  if (text.contains('connection refused') ||
      text.contains('errno = 61') ||
      text.contains('os error: 61')) {
    return 'Backend refused connection';
  }
  if (text.contains('failed host lookup') ||
      text.contains('nodename nor servname') ||
      text.contains('no address associated')) {
    return 'Host not found';
  }
  if (text.contains('timed out') || text.contains('timeout')) {
    return 'Connection timed out';
  }
  if (text.contains('ticket') && text.contains('expired')) {
    return 'Iroh ticket expired';
  }
  if (text.contains('iroh_closed') ||
      text.contains('iroh_error') ||
      text.contains('iroh connection')) {
    return _compactRawConnectionError(raw, fallback: 'Iroh connection failed');
  }
  if (text.contains('socket closed')) {
    return 'Socket closed';
  }
  return _compactRawConnectionError(raw);
}

String _targetSuffix(String? backendName) {
  final name = backendName?.trim();
  if (name == null || name.isEmpty) return '';
  return ' to $name';
}

String _joinSemantics(String title, String? detail) {
  if (detail == null || detail.trim().isEmpty) return title;
  return '$title. $detail';
}

String? _rawDetail(String? rawError, String? issue) {
  final raw = rawError?.trim();
  if (raw == null || raw.isEmpty || raw == issue) return null;
  return raw;
}

bool _containsAny(String text, List<String> needles) =>
    needles.any(text.contains);

String _compactRawConnectionError(String raw, {String? fallback}) {
  var s = raw.trim();
  s = s.replaceFirst(RegExp(r'^(connect|handshake|socket) failed:\s*'), '');
  s = s.replaceFirst(RegExp(r'^(connect|handshake|socket) error:\s*'), '');
  s = s.replaceFirst(RegExp(r'^PlatformException\([^,]+,\s*'), '');
  s = s.replaceFirst(RegExp(r'^WebSocketChannelException:\s*'), '');
  s = s.replaceFirst(RegExp(r'^WebSocketException:\s*'), '');
  s = s.replaceFirst(RegExp(r',?\s*null,\s*null\)?$'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return fallback ?? 'Connection failed';
  if (s.length <= 72) return s;
  return '${s.substring(0, 71)}…';
}
