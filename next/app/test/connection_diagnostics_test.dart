import 'package:flutter_test/flutter_test.dart';

import 'package:mobilecode/backend_client.dart';
import 'package:mobilecode/services/connection_diagnostics.dart';

void main() {
  test(
    'connectionIssueSummary maps transport errors to user-readable causes',
    () {
      expect(
        connectionIssueSummary(
          'socket error: PlatformException(IROH_CLOSED, frame too large, null, null)',
        ),
        'Message too large',
      );
      expect(
        connectionIssueSummary(
          'connect failed: WebSocketChannelException: WebSocketException: '
          'Connection refused, errno = 61, address = 127.0.0.1, port = 7860',
        ),
        'Backend refused connection',
      );
      expect(
        connectionIssueSummary('auth failed: unauthorized'),
        'Token rejected',
      );
    },
  );

  test('connectionStatusCopy keeps reconnect state and exposes last issue', () {
    final copy = connectionStatusCopy(
      state: BackendConnectionState.reconnecting,
      backendName: 'home',
      lastError: 'heartbeat timeout',
    );

    expect(copy.title, 'Reconnecting to home…');
    expect(copy.detail, 'Last issue: Heartbeat timed out');
    expect(copy.loading, isTrue);
    expect(copy.semanticsLabel, contains('Heartbeat timed out'));
  });

  test('connectionCompactLabel stays short for terminal backend headers', () {
    expect(
      connectionCompactLabel(
        BackendConnectionState.reconnecting,
        lastError: 'socket error: PlatformException(IROH_CLOSED, too big)',
      ),
      'reconnecting: Message too large',
    );
    expect(
      connectionCompactLabel(BackendConnectionState.waitingForNetwork),
      'waiting for network',
    );
  });
}
