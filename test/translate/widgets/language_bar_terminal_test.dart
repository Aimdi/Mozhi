import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/terminal_font.dart';
import '../helpers/helpers.dart';

void main() {
  setUpAll(() async {
    registerTranslateFallbacks();
    await loadTerminalFont();
  });

  group('planTerminalLanguagePair', () {
    // Name, code: flagged and plain widths.
    const source = [
      (flagged: 150.0, plain: 90.0),
      (flagged: 100.0, plain: 50.0),
    ];
    const target = [
      (flagged: 200.0, plain: 140.0),
      (flagged: 110.0, plain: 60.0),
    ];

    test('both names with their flags where they fit, halves each', () {
      final plan = planTerminalLanguagePair(
        width: 400,
        source: source,
        target: target,
      );
      expect(plan, (
        source: (form: 0, flagged: true),
        target: (form: 0, flagged: true),
        sourceWidth: 200.0,
        targetWidth: 200.0,
      ));
    });

    test('a short cell gives its room to a long one', () {
      final plan = planTerminalLanguagePair(
        width: 360,
        source: source,
        target: target,
      );
      expect(plan?.sourceWidth, 150);
      expect(plan?.targetWidth, 210);
      expect(plan?.target, (form: 0, flagged: true));
    });

    test('drops both flags before any name', () {
      final plan = planTerminalLanguagePair(
        width: 300,
        source: source,
        target: target,
      );
      expect(plan?.source, (form: 0, flagged: false));
      expect(plan?.target, (form: 0, flagged: false));
      expect(plan!.sourceWidth + plan.targetWidth, 300);
    });

    test("gives up the source's name before the target's", () {
      final plan = planTerminalLanguagePair(
        width: 200,
        source: source,
        target: target,
      );
      expect(plan?.source, (form: 1, flagged: false));
      expect(plan?.target, (form: 0, flagged: false));
    });

    test("then the target's name", () {
      final plan = planTerminalLanguagePair(
        width: 160,
        source: source,
        target: target,
      );
      expect(plan?.source, (form: 0, flagged: false));
      expect(plan?.target, (form: 1, flagged: false));
    });

    test('tries every flagged source form first for detection', () {
      final plan = planTerminalLanguagePair(
        width: 300,
        source: source,
        target: target,
        sourceFlagsFirst: true,
      );
      expect(plan?.source, (form: 1, flagged: true));
      expect(plan?.target, (form: 0, flagged: true));
    });

    test('is null when nothing fits', () {
      expect(
        planTerminalLanguagePair(width: 80, source: source, target: target),
        isNull,
      );
    });
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

    testWidgets('drops both flags together before a name', (tester) async {
      await pumpBar(tester, readyState(source: english));

      // "--from Englisch" | "--to Französisch" is too wide: both names
      // without their flags, not one flag alone and never "--to fr".
      expect(
        inButton('translate_target_button', find.text('Französisch')),
        findsOneWidget,
      );
      expect(
        inButton('translate_target_button', find.text('fr')),
        findsNothing,
      );
      expect(inButton('translate_target_button', glyph('--to')), findsNothing);
      expect(
        inButton('translate_source_button', find.text('Englisch')),
        findsOneWidget,
      );
      expect(
        inButton('translate_source_button', glyph('--from')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('names a long target instead of its code, the short source '
        'giving it room', (tester) async {
      const portuguese = Language(code: 'pt-BR', name: 'Portuguese (Brazil)');
      for (final locale in const [Locale('en'), Locale('de')]) {
        await pumpBar(
          tester,
          translatedState().copyWith(target: portuguese),
          locale: locale,
        );
        final name = locale.languageCode == 'en'
            ? 'Portuguese (Brazil)'
            : 'Portugiesisch (Brasilien)';
        expect(
          inButton('translate_target_button', find.text(name)),
          findsOneWidget,
          reason: '$locale',
        );
        expect(find.text('pt-br'), findsNothing, reason: '$locale');
        expect(
          tester
              .getSize(find.byKey(const Key('translate_target_button')))
              .width,
          greaterThan(
            tester
                .getSize(find.byKey(const Key('translate_source_button')))
                .width,
          ),
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('keeps the flags on both cells or on neither', (tester) async {
      await pumpBar(tester, readyState());

      // "--from ✨ Auto" | "--to Französisch", not "Französisch" alone.
      expect(
        inButton('translate_source_button', glyph('--from')),
        findsOneWidget,
      );
      expect(
        inButton('translate_target_button', glyph('--to')),
        findsOneWidget,
      );
      expect(
        inButton('translate_target_button', find.text('Französisch')),
        findsOneWidget,
      );
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

    testWidgets("gives up the source's name before the target's", (
      tester,
    ) async {
      await pumpBar(tester, readyState(source: english), width: 220);
      expect(
        inButton('translate_source_button', find.text('en')),
        findsOneWidget,
      );
      expect(
        inButton('translate_target_button', find.text('Französisch')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('falls back to the codes when no name fits', (tester) async {
      await pumpBar(tester, readyState(source: english), width: 150);
      expect(
        inButton('translate_target_button', find.text('fr')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
