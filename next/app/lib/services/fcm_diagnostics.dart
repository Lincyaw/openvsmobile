// In-app FCM diagnostics — captures the same debugPrints the FCM path
// emits, plus a structured snapshot of the latest known state, so a user
// without adb access can still see what's going wrong on their device.
//
// Surfaced via the "FCM diagnostics" entry in the More tab. The data lives
// in a single global instance to keep the FCM service's call sites cheap
// (no plumbing through widget tree) — there is only ever one FCM transport
// per process anyway.

import 'package:flutter/foundation.dart';

/// Coarse-grained state for the top of the debug screen. Each transition
/// the FCM transport goes through (init, getToken, register) updates one
/// of these fields and pings listeners so the screen re-renders.
class FcmDiagnostics extends ChangeNotifier {
  FcmDiagnostics._();
  static final FcmDiagnostics instance = FcmDiagnostics._();

  bool? firebaseInitOk;
  String? firebaseInitError;

  bool? controllerInitOk;
  String? controllerInitError;

  String? lastTokenPrefix; // first 24 chars; full token never persisted here
  String? lastTokenError;
  DateTime? lastTokenAt;

  String? lastRegisterStatus; // "ok" | "failed: ..." | "skipped: ..."
  DateTime? lastRegisterAt;

  String? permissionStatus;

  /// Ring buffer of the most recent log lines. Capped so a long-running
  /// session can't OOM the screen.
  final List<String> log = <String>[];
  static const int _logCap = 200;

  void append(String line) {
    final stamped = '[${DateTime.now().toIso8601String().substring(11, 19)}] $line';
    debugPrint(stamped);
    log.add(stamped);
    if (log.length > _logCap) {
      log.removeRange(0, log.length - _logCap);
    }
    notifyListeners();
  }

  void setFirebaseInit({required bool ok, String? error}) {
    firebaseInitOk = ok;
    firebaseInitError = error;
    append(ok
        ? 'Firebase.initializeApp OK'
        : 'Firebase.initializeApp FAILED: $error');
  }

  void setControllerInit({required bool ok, String? error}) {
    controllerInitOk = ok;
    controllerInitError = error;
    append(ok
        ? 'FcmController.init OK'
        : 'FcmController.init FAILED: $error');
  }

  void setToken({String? token, String? error}) {
    lastTokenAt = DateTime.now();
    if (error != null) {
      lastTokenError = error;
      lastTokenPrefix = null;
      append('getToken FAILED: $error');
    } else if (token == null || token.isEmpty) {
      lastTokenError = 'null/empty';
      lastTokenPrefix = null;
      append('getToken returned null/empty');
    } else {
      lastTokenError = null;
      lastTokenPrefix = token.length <= 24 ? token : '${token.substring(0, 24)}…';
      append('getToken OK (${token.length} chars, prefix $lastTokenPrefix)');
    }
    notifyListeners();
  }

  void setRegister({required String status}) {
    lastRegisterStatus = status;
    lastRegisterAt = DateTime.now();
    append('register: $status');
  }

  void setPermission(String status) {
    permissionStatus = status;
    append('permission: $status');
  }
}
