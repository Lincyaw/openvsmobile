// Terminal-specific instrumentation that feeds the general [DiagLog]. Kept
// apart from `diag_log.dart` so the general observability log stays free of
// VT/zellij specifics.

import 'diag_log.dart';

/// Scan a freshly-rendered chunk for the DEC private-mode set/reset
/// sequences that matter to scroll routing, and log each under
/// [DiagCat.mode]. Only the modes we actually reason about are surfaced —
/// the rest are noise. Cheap-exits when the log is disabled.
void sniffDecModes(String chunk) {
  if (!DiagLog.instance.enabled) return;
  var i = 0;
  while (true) {
    final start = chunk.indexOf('\x1b[?', i);
    if (start < 0) return;
    var j = start + 3;
    // Params run until the final byte (a letter); modes are ';'-separated
    // decimal digits.
    while (j < chunk.length) {
      final c = chunk.codeUnitAt(j);
      final isDigit = c >= 0x30 && c <= 0x39;
      final isSep = c == 0x3b; // ';'
      if (!isDigit && !isSep) break;
      j++;
    }
    if (j >= chunk.length) return;
    final fin = chunk[j];
    if (fin == 'h' || fin == 'l') {
      final params = chunk.substring(start + 3, j).split(';');
      for (final p in params) {
        final mode = int.tryParse(p);
        final name = _decModeName(mode);
        if (name != null) {
          DiagLog.instance.log(
            DiagCat.mode,
            '?$mode${fin == 'h' ? '↑on' : '↓off'} $name',
          );
        }
      }
    }
    i = j + 1;
  }
}

String? _decModeName(int? mode) => switch (mode) {
  1 => 'app-cursor-keys(DECCKM)',
  9 => 'mouse-X10',
  1000 => 'mouse-click(1000)',
  1002 => 'mouse-drag(1002)',
  1003 => 'mouse-move(1003)',
  1004 => 'focus-report(1004)',
  1006 => 'sgr-encoding(1006)',
  1007 => 'alt-scroll(1007)',
  1015 => 'urxvt-encoding(1015)',
  47 || 1047 => 'alt-buffer(47)',
  1048 => 'save-cursor(1048)',
  1049 => 'alt-buffer(1049)',
  2004 => 'bracketed-paste(2004)',
  _ => null,
};
