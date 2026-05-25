// LAN mDNS discovery for openvsmobile backends.
//
// Scans the local network for `_openvsmobile._tcp` services advertised by
// the backend's MdnsAdvertiser. Returns host, port, and version — the token
// is never broadcast over multicast; the user must still enter it manually.

import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

const String _kServiceType = '_openvsmobile._tcp.local';

/// One discovered backend on the LAN.
class DiscoveredBackend {
  /// Service instance name (usually the hostname).
  final String name;

  /// Resolved host — an IP address when possible, otherwise the .local name.
  final String host;

  /// Port the backend's HTTP server is listening on.
  final int port;

  /// Backend version string from the TXT record.
  final String version;

  /// When this record was observed.
  final DateTime discoveredAt;

  const DiscoveredBackend({
    required this.name,
    required this.host,
    required this.port,
    required this.version,
    required this.discoveredAt,
  });
}

/// Scans the LAN for `_openvsmobile._tcp` services.
///
/// Usage:
///   final results = await MdnsDiscovery().scan(timeout: Duration(seconds: 3));
class MdnsDiscovery {
  /// Scan duration. Three seconds is a pragmatic default — most LAN mDNS
  /// responses arrive within the first RTT; waiting longer mostly just burns
  /// battery for diminishing returns.
  static const Duration _kDefaultTimeout = Duration(seconds: 3);

  /// Sub-timeout for individual follow-up queries (SRV/TXT/A). If a service
  /// is advertised but its follow-up records are slow, we don't want to stall
  /// the whole scan.
  static const Duration _kQueryTimeout = Duration(seconds: 2);

  Future<List<DiscoveredBackend>> scan({
    Duration timeout = _kDefaultTimeout,
  }) async {
    final mdns = MDnsClient();
    await mdns.start();
    try {
      final results = <DiscoveredBackend>[];
      final seen = <String>{}; // dedupe by SRV name

      try {
        await for (final ptr
            in mdns
                .lookup<PtrResourceRecord>(
                  ResourceRecordQuery.serverPointer(_kServiceType),
                )
                .timeout(timeout, onTimeout: (sink) => sink.close())) {
          final srvName = ptr.domainName;
          if (!seen.add(srvName)) continue;

          final srv = await _querySrv(mdns, srvName);
          final txt = await _queryTxt(mdns, srvName);
          final resolvedHost = await _resolveHost(mdns, srv?.target ?? srvName);

          final effectivePort = srv?.port ?? txt.port ?? 7860;
          results.add(
            DiscoveredBackend(
              name: srvName.split('.').first,
              host: resolvedHost,
              port: effectivePort,
              version: txt.version,
              discoveredAt: DateTime.now(),
            ),
          );
        }
      } on TimeoutException {
        // No services found within timeout — this is normal.
      }
      return results;
    } finally {
      mdns.stop();
    }
  }

  Future<SrvResourceRecord?> _querySrv(MDnsClient mdns, String name) async {
    await for (final srv
        in mdns
            .lookup<SrvResourceRecord>(ResourceRecordQuery.service(name))
            .timeout(_kQueryTimeout, onTimeout: (sink) => sink.close())) {
      return srv;
    }
    return null;
  }

  Future<({String version, int? port})> _queryTxt(
    MDnsClient mdns,
    String name,
  ) async {
    String version = '';
    int? port;
    await for (final txt
        in mdns
            .lookup<TxtResourceRecord>(ResourceRecordQuery.text(name))
            .timeout(_kQueryTimeout, onTimeout: (sink) => sink.close())) {
      for (final entry in txt.text.split('\n')) {
        if (entry.startsWith('v=')) {
          version = entry.substring(2);
        } else if (entry.startsWith('port=')) {
          port = int.tryParse(entry.substring(5));
        }
      }
      break;
    }
    return (version: version, port: port);
  }

  Future<String> _resolveHost(MDnsClient mdns, String host) async {
    final normalizedHost = host.endsWith('.')
        ? host.substring(0, host.length - 1)
        : host;
    if (!normalizedHost.endsWith('.local')) return normalizedHost;

    // Try IPv4 first, then IPv6.
    await for (final ip
        in mdns
            .lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(host),
            )
            .timeout(_kQueryTimeout, onTimeout: (sink) => sink.close())) {
      return ip.address.address;
    }
    await for (final ip
        in mdns
            .lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv6(host),
            )
            .timeout(_kQueryTimeout, onTimeout: (sink) => sink.close())) {
      return ip.address.address;
    }
    return normalizedHost; // fallback to the .local name
  }
}
