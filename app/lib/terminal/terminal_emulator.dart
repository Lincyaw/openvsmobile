import 'dart:convert';
import 'dart:typed_data';

import 'terminal_buffer.dart';
import 'terminal_cursor.dart';
import 'terminal_snapshot.dart';
import 'terminal_style.dart';

class TerminalEmulator {
  TerminalEmulator({int rows = 24, int cols = 80, this.scrollbackLimit = 10000})
    : _mainBuffer = TerminalBuffer(
        rows: rows,
        cols: cols,
        scrollbackLimit: scrollbackLimit,
      ),
      _alternateBuffer = TerminalBuffer(
        rows: rows,
        cols: cols,
        scrollbackLimit: 0,
        enableScrollback: false,
      );

  final int scrollbackLimit;
  final TerminalBuffer _mainBuffer;
  final TerminalBuffer _alternateBuffer;
  final TerminalSavedCursor _savedMainCursor = TerminalSavedCursor();
  final TerminalSavedCursor _savedAlternateCursor = TerminalSavedCursor();
  final List<String> _pendingResponses = <String>[];

  TerminalStyle _style = TerminalStyle.reset;
  String _remainder = '';
  bool _inAlternateBuffer = false;
  bool _applicationCursorKeys = false;
  int _viewportOffset = 0;

  int get rows => _buffer.rows;
  int get cols => _buffer.cols;
  bool get isAlternateBuffer => _inAlternateBuffer;
  TerminalCursor get cursor => _buffer.cursor;

  TerminalBuffer get _buffer =>
      _inAlternateBuffer ? _alternateBuffer : _mainBuffer;
  TerminalSavedCursor get _savedCursor =>
      _inAlternateBuffer ? _savedAlternateCursor : _savedMainCursor;

  List<String> write(String chunk) {
    if (chunk.isEmpty) {
      return const <String>[];
    }
    final input = '$_remainder$chunk';
    _remainder = '';

    int index = 0;
    while (index < input.length) {
      final codeUnit = input.codeUnitAt(index);
      if (codeUnit == 0x1B) {
        final parsed = _consumeEscape(input, index);
        if (parsed == null) {
          _remainder = input.substring(index);
          break;
        }
        index = parsed;
        continue;
      }
      if (codeUnit < 0x20 || codeUnit == 0x7F) {
        _applyControl(codeUnit);
        index += 1;
        continue;
      }

      final nextBoundary = _nextControlBoundary(input, index);
      _writeText(input.substring(index, nextBoundary));
      index = nextBoundary;
    }

    return drainResponses();
  }

  List<String> writeBytes(Uint8List chunk) {
    return write(utf8.decode(chunk, allowMalformed: true));
  }

  void resize(int rows, int cols) {
    _mainBuffer.resize(rows, cols);
    _alternateBuffer.resize(rows, cols);
  }

  void reset() {
    _style = TerminalStyle.reset;
    _remainder = '';
    _viewportOffset = 0;
    _inAlternateBuffer = false;
    _applicationCursorKeys = false;
    _pendingResponses.clear();
    _mainBuffer.reset();
    _alternateBuffer.reset();
  }

  void setViewportOffset(int offsetFromBottom) {
    _viewportOffset = offsetFromBottom < 0 ? 0 : offsetFromBottom;
  }

  void clearSelection() {}

  TerminalSnapshot snapshot({bool clearDirtyRows = false}) {
    return _buffer.snapshot(
      isAlternateBuffer: _inAlternateBuffer,
      applicationCursorKeys: _applicationCursorKeys,
      viewportOffset: _viewportOffset,
      clearDirtyRows: clearDirtyRows,
    );
  }

  String get plainText => _buffer.backlogText();

  List<String> drainResponses() {
    if (_pendingResponses.isEmpty) {
      return const <String>[];
    }
    final responses = List<String>.from(_pendingResponses, growable: false);
    _pendingResponses.clear();
    return responses;
  }

  int? _consumeEscape(String input, int start) {
    if (start + 1 >= input.length) {
      return null;
    }

    final next = input.codeUnitAt(start + 1);
    if (next == 0x5B) {
      return _consumeCsi(input, start);
    }
    if (next == 0x5D) {
      return _consumeOsc(input, start);
    }

    switch (next) {
      case 0x37: // ESC 7
        _buffer.saveCursor(_savedCursor);
        return start + 2;
      case 0x38: // ESC 8
        _buffer.restoreCursor(_savedCursor);
        return start + 2;
      case 0x44: // ESC D
        _buffer.lineFeed();
        return start + 2;
      case 0x45: // ESC E
        _buffer.carriageReturn();
        _buffer.lineFeed();
        return start + 2;
      case 0x4D: // ESC M
        _buffer.reverseIndex();
        return start + 2;
      case 0x5A: // ESC Z
        _emitPrimaryDeviceAttributes();
        return start + 2;
      case 0x63: // RIS
        reset();
        return start + 2;
      default:
        return start + 2;
    }
  }

  int? _consumeCsi(String input, int start) {
    int cursor = start + 2;
    while (cursor < input.length) {
      final codeUnit = input.codeUnitAt(cursor);
      if (codeUnit >= 0x40 && codeUnit <= 0x7E) {
        final payload = input.substring(start + 2, cursor);
        final finalByte = String.fromCharCode(codeUnit);
        _applyCsi(payload, finalByte);
        return cursor + 1;
      }
      cursor += 1;
    }
    return null;
  }

  int? _consumeOsc(String input, int start) {
    int cursor = start + 2;
    while (cursor < input.length) {
      final codeUnit = input.codeUnitAt(cursor);
      if (codeUnit == 0x07) {
        return cursor + 1;
      }
      if (codeUnit == 0x1B &&
          cursor + 1 < input.length &&
          input.codeUnitAt(cursor + 1) == 0x5C) {
        return cursor + 2;
      }
      cursor += 1;
    }
    return null;
  }

  void _applyControl(int codeUnit) {
    switch (codeUnit) {
      case 0x08:
        _buffer.backspace();
        break;
      case 0x09:
        _buffer.tab();
        break;
      case 0x0A:
      case 0x0B:
      case 0x0C:
        _buffer.lineFeed();
        break;
      case 0x0D:
        _buffer.carriageReturn();
        break;
      default:
        break;
    }
  }

  int _nextControlBoundary(String input, int start) {
    int index = start;
    while (index < input.length) {
      final codeUnit = input.codeUnitAt(index);
      if (codeUnit == 0x1B || codeUnit < 0x20 || codeUnit == 0x7F) {
        break;
      }
      index += 1;
    }
    return index;
  }

  void _writeText(String text) {
    for (final grapheme in _graphemes(text)) {
      final width = _cellWidth(grapheme);
      if (width == 0) {
        _buffer.appendCombiningMark(grapheme);
      } else {
        _buffer.putChar(grapheme, _style, width: width);
      }
    }
  }

  void _applyCsi(String payload, String finalByte) {
    String paramsPart = payload;
    String prefix = '';
    if (paramsPart.startsWith('?') || paramsPart.startsWith('>')) {
      prefix = paramsPart[0];
      paramsPart = paramsPart.substring(1);
    }

    switch (finalByte) {
      case 'A':
        _buffer.moveCursorRelative(rowDelta: -_firstParam(paramsPart, 1));
        return;
      case 'B':
        _buffer.moveCursorRelative(rowDelta: _firstParam(paramsPart, 1));
        return;
      case 'C':
        _buffer.moveCursorRelative(colDelta: _firstParam(paramsPart, 1));
        return;
      case 'D':
        _buffer.moveCursorRelative(colDelta: -_firstParam(paramsPart, 1));
        return;
      case 'E':
        _buffer.moveCursorRelative(rowDelta: _firstParam(paramsPart, 1));
        _buffer.moveCursor(col: 0);
        return;
      case 'F':
        _buffer.moveCursorRelative(rowDelta: -_firstParam(paramsPart, 1));
        _buffer.moveCursor(col: 0);
        return;
      case 'G':
        _buffer.moveCursor(col: _firstParam(paramsPart, 1) - 1);
        return;
      case 'H':
      case 'f':
        final params = _parseParams(paramsPart);
        final row = (params.isNotEmpty ? params[0] : 1) - 1;
        final col = (params.length > 1 ? params[1] : 1) - 1;
        _buffer.moveCursor(row: row, col: col);
        return;
      case 'J':
        _buffer.clearScreen(_firstParam(paramsPart, 0));
        return;
      case 'K':
        _buffer.clearLine(_firstParam(paramsPart, 0));
        return;
      case 'L':
        _buffer.insertLines(_firstParam(paramsPart, 1));
        return;
      case 'M':
        _buffer.deleteLines(_firstParam(paramsPart, 1));
        return;
      case '@':
        _buffer.insertChars(_firstParam(paramsPart, 1));
        return;
      case 'P':
        _buffer.deleteChars(_firstParam(paramsPart, 1));
        return;
      case 'X':
        _buffer.eraseChars(_firstParam(paramsPart, 1));
        return;
      case 'm':
        _applySgr(paramsPart);
        return;
      case 'n':
        _applyDeviceStatusReport(prefix, paramsPart);
        return;
      case 'c':
        _applyDeviceAttributes(prefix);
        return;
      case 'r':
        final params = _parseParams(paramsPart);
        if (params.isEmpty) {
          _buffer.setScrollRegion(null, null);
          return;
        }
        final top = (params[0] == 0 ? 1 : params[0]) - 1;
        final bottomParam = params.length > 1 ? params[1] : _buffer.rows;
        final bottom = (bottomParam == 0 ? _buffer.rows : bottomParam) - 1;
        _buffer.setScrollRegion(top, bottom);
        return;
      case 'h':
        _applyMode(prefix, paramsPart, enabled: true);
        return;
      case 'l':
        _applyMode(prefix, paramsPart, enabled: false);
        return;
      case 's':
        _buffer.saveCursor(_savedCursor);
        return;
      case 'u':
        _buffer.restoreCursor(_savedCursor);
        return;
      default:
        return;
    }
  }

  void _applyMode(String prefix, String paramsPart, {required bool enabled}) {
    final params = _parseParams(paramsPart);
    if (prefix == '?') {
      for (final param in params) {
        switch (param) {
          case 1:
            _applicationCursorKeys = enabled;
            break;
          case 7:
            _buffer.autoWrap = enabled;
            break;
          case 25:
            _buffer.setCursorVisibility(enabled);
            break;
          case 1049:
            _setAlternateBuffer(enabled);
            break;
        }
      }
    }
  }

  void _setAlternateBuffer(bool enabled) {
    if (enabled == _inAlternateBuffer) {
      return;
    }
    if (enabled) {
      _mainBuffer.saveCursor(_savedMainCursor);
      _alternateBuffer.reset();
      _inAlternateBuffer = true;
      _alternateBuffer.markAllDirty();
      return;
    }
    _inAlternateBuffer = false;
    _mainBuffer.restoreCursor(_savedMainCursor);
    _mainBuffer.markAllDirty();
  }

  void _applyDeviceStatusReport(String prefix, String paramsPart) {
    final code = _firstParam(paramsPart, 0);
    if (code == 5) {
      _emitResponse('\x1B[0n');
      return;
    }
    if (code != 6) {
      return;
    }
    final row = cursor.row + 1;
    final col = cursor.column + 1;
    if (prefix == '?') {
      _emitResponse('\x1B[?$row;${col}R');
      return;
    }
    _emitResponse('\x1B[$row;${col}R');
  }

  void _applyDeviceAttributes(String prefix) {
    if (prefix == '>') {
      _emitResponse('\x1B[>0;0;0c');
      return;
    }
    _emitPrimaryDeviceAttributes();
  }

  void _emitPrimaryDeviceAttributes() {
    _emitResponse('\x1B[?62;1;6;22c');
  }

  void _emitResponse(String response) {
    _pendingResponses.add(response);
  }

  void _applySgr(String paramsPart) {
    final params = _parseParams(paramsPart, defaultValue: 0);
    if (params.isEmpty) {
      _style = TerminalStyle.reset;
      return;
    }

    int index = 0;
    while (index < params.length) {
      final code = params[index];
      switch (code) {
        case 0:
          _style = TerminalStyle.reset;
          index += 1;
          break;
        case 1:
          _style = _style.copyWith(bold: true);
          index += 1;
          break;
        case 2:
          _style = _style.copyWith(dim: true);
          index += 1;
          break;
        case 3:
          _style = _style.copyWith(italic: true);
          index += 1;
          break;
        case 4:
          _style = _style.copyWith(underline: true);
          index += 1;
          break;
        case 7:
          _style = _style.copyWith(inverse: true);
          index += 1;
          break;
        case 9:
          _style = _style.copyWith(strikethrough: true);
          index += 1;
          break;
        case 22:
          _style = _style.copyWith(bold: false, dim: false);
          index += 1;
          break;
        case 23:
          _style = _style.copyWith(italic: false);
          index += 1;
          break;
        case 24:
          _style = _style.copyWith(underline: false);
          index += 1;
          break;
        case 27:
          _style = _style.copyWith(inverse: false);
          index += 1;
          break;
        case 29:
          _style = _style.copyWith(strikethrough: false);
          index += 1;
          break;
        case 39:
          _style = _style.copyWith(foreground: TerminalColor.defaultColor);
          index += 1;
          break;
        case 49:
          _style = _style.copyWith(background: TerminalColor.defaultColor);
          index += 1;
          break;
        default:
          if (30 <= code && code <= 37) {
            _style = _style.copyWith(
              foreground: TerminalColor.indexed(code - 30),
            );
            index += 1;
          } else if (40 <= code && code <= 47) {
            _style = _style.copyWith(
              background: TerminalColor.indexed(code - 40),
            );
            index += 1;
          } else if (90 <= code && code <= 97) {
            _style = _style.copyWith(
              foreground: TerminalColor.indexed(code - 90 + 8),
            );
            index += 1;
          } else if (100 <= code && code <= 107) {
            _style = _style.copyWith(
              background: TerminalColor.indexed(code - 100 + 8),
            );
            index += 1;
          } else if ((code == 38 || code == 48) && index + 1 < params.length) {
            final useForeground = code == 38;
            final mode = params[index + 1];
            if (mode == 5 && index + 2 < params.length) {
              final color = TerminalColor.indexed(params[index + 2]);
              _style = useForeground
                  ? _style.copyWith(foreground: color)
                  : _style.copyWith(background: color);
              index += 3;
            } else if (mode == 2 && index + 4 < params.length) {
              final color = TerminalColor.rgb(
                params[index + 2],
                params[index + 3],
                params[index + 4],
              );
              _style = useForeground
                  ? _style.copyWith(foreground: color)
                  : _style.copyWith(background: color);
              index += 5;
            } else {
              index += 1;
            }
          } else {
            index += 1;
          }
      }
    }
  }

  List<int> _parseParams(String paramsPart, {int? defaultValue}) {
    if (paramsPart.isEmpty) {
      return defaultValue == null ? <int>[] : <int>[defaultValue];
    }
    return paramsPart
        .split(';')
        .map((part) {
          if (part.isEmpty) {
            return defaultValue ?? 0;
          }
          return int.tryParse(part) ?? (defaultValue ?? 0);
        })
        .toList(growable: false);
  }

  int _firstParam(String paramsPart, int fallback) {
    final params = _parseParams(paramsPart, defaultValue: fallback);
    return params.isEmpty ? fallback : params.first;
  }
}

Iterable<String> _graphemes(String text) sync* {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final chunk = String.fromCharCode(rune);
    if (buffer.isEmpty) {
      buffer.write(chunk);
      continue;
    }
    if (_isCombiningMark(rune) ||
        rune == 0x200D ||
        _isVariationSelector(rune)) {
      buffer.write(chunk);
      continue;
    }
    yield buffer.toString();
    buffer
      ..clear()
      ..write(chunk);
  }
  if (buffer.isNotEmpty) {
    yield buffer.toString();
  }
}

bool _isVariationSelector(int rune) {
  return (0xFE00 <= rune && rune <= 0xFE0F) ||
      (0xE0100 <= rune && rune <= 0xE01EF);
}

int _cellWidth(String grapheme) {
  if (grapheme.isEmpty) {
    return 0;
  }
  final rune = grapheme.runes.first;
  if (_isCombiningMark(rune)) {
    return 0;
  }
  if (_isWideRune(rune)) {
    return 2;
  }
  return 1;
}

bool _isCombiningMark(int rune) {
  return (0x0300 <= rune && rune <= 0x036F) ||
      (0x1AB0 <= rune && rune <= 0x1AFF) ||
      (0x1DC0 <= rune && rune <= 0x1DFF) ||
      (0x20D0 <= rune && rune <= 0x20FF) ||
      (0xFE20 <= rune && rune <= 0xFE2F);
}

bool _isWideRune(int rune) {
  return (0x1100 <= rune && rune <= 0x115F) ||
      rune == 0x2329 ||
      rune == 0x232A ||
      (0x2E80 <= rune && rune <= 0xA4CF) ||
      (0xAC00 <= rune && rune <= 0xD7A3) ||
      (0xF900 <= rune && rune <= 0xFAFF) ||
      (0xFE10 <= rune && rune <= 0xFE19) ||
      (0xFE30 <= rune && rune <= 0xFE6F) ||
      (0xFF00 <= rune && rune <= 0xFF60) ||
      (0xFFE0 <= rune && rune <= 0xFFE6) ||
      (0x1F300 <= rune && rune <= 0x1FAFF);
}
