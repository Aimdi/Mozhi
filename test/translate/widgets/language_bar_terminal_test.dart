import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';

import '../../helpers/terminal_font.dart';
import '../helpers/helpers.dart';

void main() {
  setUpAll(() async {
    registerTranslateFallbacks();
    await loadTerminalFont();
  });

  group('LanguageBar in the terminal look', () {
    /// The terminal bar on a 390 dp phone (its cells as on the translate
    /// tab) in [locale].
    Future<void> pumpBar(
      WidgetTester tester,
      TranslateState state, {
      Locale locale = const Locale('de'),
      double width = 358,
    }) async {
      final harness = TranslateHarness(state: state);
      await harness.pump(
        tester,
        size: const Size(390, 844),
        locale: locale,
        theme: terminalTestTheme(),
        child: Center(
          child: SizedBox(width: width, child: const LanguageBar()),
        ),
      );
      await tester.pump();
    }

    Finder inButton(String key, Finder finder) =>
        find.descendant(of: find.byKey(Key(key)), matching: finder);

    Finder glyph(String text) => find.byWidgetPredicate(
      (widget) => widget is TerminalGlyph && widget.text == text,
    );

    testWidgets('prefers the name to the flag', (tester) async {
      await pumpBar(tester, readyState(source: english));

      // "--to Französisch" is too wide: the name alone, not "--to fr".
      expect(
        inButton('translate_target_button', find.text('Französisch')),
        findsOneWidget,
      );
      expect(
        inButton('translate_target_button', find.text('fr')),
        findsNothing,
      );
      expect(inButton('translate_target_button', glyph('--to')), findsNothing);
      // The short name keeps its flag.
      expect(
        inButton('translate_source_button', find.text('Englisch')),
        findsOneWidget,
      );
      expect(
        inButton('translate_source_button', glyph('--from')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('names a detected language rather than its code', (
      tester,
    ) async {
      await pumpBar(tester, translatedState());

      expect(
        inButton('translate_source_button', find.text('Englisch')),
        findsOneWidget,
      );
      expect(
        inButton('translate_source_button', find.text('en')),
        findsNothing,
      );
      expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
    });

    testWidgets('keeps the flag before "Auto" for detection', (tester) async {
      // "Detect language" would fit on its own, but not after the flag.
      await pumpBar(tester, readyState(), locale: const Locale('en'));

      expect(
        inButton('translate_source_button', glyph('--from')),
        findsOneWidget,
      );
      expect(
        inButton('translate_source_button', find.text('Auto')),
        findsOneWidget,
      );
      expect(find.text('Detect language'), findsNothing);
    });

    testWidgets('falls back to the code with the flag, then without', (
      tester,
    ) async {
      await pumpBar(tester, readyState(source: english), width: 220);
      expect(
        inButton('translate_target_button', find.text('fr')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
