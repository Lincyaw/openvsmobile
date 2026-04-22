import 'package:flutter_test/flutter_test.dart';
import 'package:vscode_mobile/theme/monospace_text.dart';

void main() {
  test('monospace text styles include CJK-friendly fallback fonts', () {
    final style = monospaceTextStyle(fontSize: 13);

    expect(style.fontFamily, 'monospace');
    expect(style.fontFamilyFallback, isNotNull);
    expect(style.fontFamilyFallback, contains('Noto Sans CJK SC'));
    expect(style.fontFamilyFallback, contains('Noto Sans SC'));
    expect(style.fontFamilyFallback, contains('PingFang SC'));
  });
}
