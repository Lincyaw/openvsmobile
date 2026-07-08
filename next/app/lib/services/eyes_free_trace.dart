import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'diag_log.dart';

class EyesFreeTrace {
  const EyesFreeTrace._();

  static void log(String source, String message) {
    final line = '$source $message';
    DiagLog.instance.log(DiagCat.eyes, line);
    if (kDebugMode && Platform.isAndroid) {
      debugPrint('OVM-EYES $line');
    }
  }
}
