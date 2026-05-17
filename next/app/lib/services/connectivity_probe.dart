// Production [ConnectivityProbe] backed by `connectivity_plus`. Maps the
// list of active link types to a single boolean — we don't care which link
// is up, only whether at least one is.
//
// Lives in `services/` (rather than inline in `main.dart`) because the probe
// is stateful cross-screen logic that doesn't fit AppState — see
// docs/conventions.md §2 "Module boundaries inside client".

import 'package:connectivity_plus/connectivity_plus.dart';

import '../backend_client.dart';

class ConnectivityPlusProbe implements ConnectivityProbe {
  ConnectivityPlusProbe();

  final Connectivity _impl = Connectivity();

  @override
  Stream<bool> get changes => _impl.onConnectivityChanged.map(_anyOnline);

  @override
  Future<bool> isOnline() async {
    try {
      return _anyOnline(await _impl.checkConnectivity());
    } catch (_) {
      // Plugin not implemented on this platform (e.g. desktop) → assume yes.
      return true;
    }
  }

  bool _anyOnline(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);
}
