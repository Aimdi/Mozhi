import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/translate.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  for (final width in [320.0, 360.0]) {
    testWidgets('scratch $width', (tester) async {
      final harness = TranslateHarness(state: readyState(target: german));
      await harness.pump(tester, size: Size(width, 800), textScale: 2);
      await tester.pumpAndSettle();
      final exception = tester.takeException();
      // ignore: avoid_print
      print('exception: $exception');
      for (final key in [
        'translate_language_bar',
        'translate_options_button',
        'translate_source_button',
        'translate_swap_button',
        'translate_target_button',
        'translate_translate_button',
      ]) {
        final f = find.byKey(Key(key));
        // ignore: avoid_print
        print('$key ${f.evaluate().isEmpty ? '-' : tester.getRect(f)}');
      }
      for (final element in find.byType(RichText).evaluate()) {
        final ro = element.renderObject! as RenderParagraph;
        // ignore: avoid_print
        print(
          'text "${ro.text.toPlainText()}" size=${ro.size} '
          'exceeded=${ro.didExceedMaxLines}',
        );
      }
    });
  }
}
