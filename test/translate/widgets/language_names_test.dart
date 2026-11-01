import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

/// [finder] inside the language picker.
Finder _inPicker(Finder finder) =>
    find.descendant(of: find.byType(LanguagePickerSheet), matching: finder);

/// The row of [language] in the picker's [section].
Finder _row(String section, Language language) =>
    find.byKey(ValueKey((section, language.code)));

void main() {
  setUpAll(registerTranslateFallbacks);

  const de = Locale('de');

  Future<void> openPicker(
    WidgetTester tester,
    TranslateHarness harness, {
    Locale locale = de,
    bool source = false,
  }) async {
    await harness.pump(
      tester,
      child: const LanguageBar(),
      size: const Size(400, 1600),
      locale: locale,
    );
    await tester.tap(
      find.byKey(
        Key(source ? 'translate_source_button' : 'translate_target_button'),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('language names in the UI language', () {
    group('LanguageBar', () {
      testWidgets('names the languages in German', (tester) async {
        final harness = TranslateHarness(state: readyState(source: english));
        await harness.pump(tester, child: const LanguageBar(), locale: de);
        expect(find.text('Englisch'), findsOneWidget);
        expect(find.text('Französisch'), findsOneWidget);
        expect(find.text('English'), findsNothing);
        expect(find.text('French'), findsNothing);
        expect(
          find.bySemanticsLabel('Zielsprache: Französisch'),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('Ausgangssprache: Englisch'),
          findsOneWidget,
        );
      });

      testWidgets('names a detected language in German', (tester) async {
        final harness = TranslateHarness(state: translatedState());
        await harness.pump(tester, child: const LanguageBar(), locale: de);
        expect(find.text('Englisch'), findsOneWidget);
        expect(find.textContaining('English'), findsNothing);
      });

      testWidgets('names the languages in Japanese', (tester) async {
        final harness = TranslateHarness(state: readyState(source: english));
        await harness.pump(
          tester,
          child: const LanguageBar(),
          locale: const Locale('ja'),
        );
        expect(find.text('英語'), findsOneWidget);
        expect(find.text('フランス語'), findsOneWidget);
      });

      testWidgets('keeps the English names in English', (tester) async {
        final harness = TranslateHarness(state: readyState(source: english));
        await harness.pump(tester, child: const LanguageBar());
        expect(find.text('English'), findsOneWidget);
        expect(find.text('French'), findsOneWidget);
      });

      testWidgets('keeps custom languages as typed', (tester) async {
        final harness = TranslateHarness(
          state: readyState(
            engine: claude,
            target: const Language.custom('Pirate speak'),
          ),
        );
        await harness.pump(tester, child: const LanguageBar(), locale: de);
        expect(find.text('Pirate speak'), findsOneWidget);
      });
    });

    group('LanguagePickerSheet', () {
      testWidgets('lists German names with the native name below', (
        tester,
      ) async {
        await openPicker(tester, TranslateHarness());
        final french = _row('all', languages[1]);
        expect(
          find.descendant(of: french, matching: find.text('Französisch')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: french, matching: find.text('Français')),
          findsOneWidget,
        );
        // "Deutsch" is the German name and the native one: shown once.
        expect(
          find.descendant(
            of: _row('all', german),
            matching: find.text('Deutsch'),
          ),
          findsOneWidget,
        );
        expect(_inPicker(find.text('French')), findsNothing);
      });

      testWidgets('sorts All languages by the German names', (tester) async {
        await openPicker(tester, TranslateHarness());
        double top(Language language) =>
            tester.getTopLeft(_row('all', language)).dy;
        // Deutsch, Englisch, Französisch, Japanisch.
        expect(top(german), lessThan(top(english)));
        expect(top(english), lessThan(top(french)));
        expect(top(french), lessThan(top(japanese)));
      });

      testWidgets('keeps the engine order in English', (tester) async {
        await openPicker(
          tester,
          TranslateHarness(),
          locale: const Locale('en'),
        );
        double top(Language language) =>
            tester.getTopLeft(_row('all', language)).dy;
        expect(top(english), lessThan(top(french)));
        expect(top(french), lessThan(top(german)));
      });

      for (final (query, label) in [
        ('franz', 'the German name'),
        ('Französisch', 'the German name with its umlaut'),
        ('franzosisch', 'the German name without diacritics'),
        ('French', 'the English name'),
        ('Français', 'the native name'),
        ('fr', 'the code'),
      ]) {
        testWidgets('a search finds French by $label', (tester) async {
          await openPicker(tester, TranslateHarness());
          await tester.enterText(
            find.byKey(const Key('translate_language_search')),
            query,
          );
          await tester.pump();
          expect(_row('matches', french), findsOneWidget);
          expect(
            find.descendant(
              of: _row('matches', french),
              matching: find.text('Französisch'),
            ),
            findsOneWidget,
          );
        });
      }

      testWidgets('a search for a German name finds only its language', (
        tester,
      ) async {
        await openPicker(tester, TranslateHarness());
        await tester.enterText(
          find.byKey(const Key('translate_language_search')),
          'japanisch',
        );
        await tester.pump();
        expect(_row('matches', japanese), findsOneWidget);
        expect(_row('matches', french), findsNothing);
        expect(_row('matches', german), findsNothing);
      });
    });
  });

  group('matchLanguages', () {
    String inGerman(Language language) => switch (language.code) {
      'fr' => 'Französisch',
      'de' => 'Deutsch',
      'en' => 'Englisch',
      _ => language.name,
    };

    test('matches the shown name too', () {
      expect(matchLanguages(languages, 'franz', displayName: inGerman), [
        french,
      ]);
      expect(matchLanguages(languages, 'franz'), isEmpty);
      expect(matchLanguages(languages, 'engl', displayName: inGerman), [
        english,
      ]);
    });

    test('ranks a shown name that starts with the query first', () {
      // "Deutsch" starts with "deu"; nothing else contains it.
      expect(matchLanguages(languages, 'deu', displayName: inGerman), [german]);
    });
  });

  group('sortLanguagesByName', () {
    test('sorts by the shown names, ignoring case and diacritics', () {
      const egyptian = Language(code: 'ar-EG', name: 'Arabic (Egyptian)');
      const afrikaans = Language(code: 'af', name: 'Afrikaans');
      const bulgarian = Language(code: 'bg', name: 'Bulgarian');
      String name(Language language) => switch (language.code) {
        'ar-EG' => 'Ägyptisch',
        'bg' => 'bulgarisch',
        _ => language.name,
      };
      expect(sortLanguagesByName([bulgarian, egyptian, afrikaans], name), [
        afrikaans,
        egyptian,
        bulgarian,
      ]);
    });

    test('keeps the order when every name is the English one', () {
      expect(sortLanguagesByName([german, english, french], (l) => l.name), [
        german,
        english,
        french,
      ]);
    });

    test('keeps the order of equal names', () {
      const a = Language(code: 'xa', name: 'Same');
      const b = Language(code: 'xb', name: 'Same');
      expect(sortLanguagesByName([b, a], (_) => 'Gleich'), [b, a]);
    });
  });

  group('languageLabelForms', () {
    test('starts with the given name', () {
      expect(languageLabelForms(german, name: 'Deutsch').first, (
        icon: null,
        text: 'Deutsch',
      ));
      expect(languageLabelForms(german).first, (icon: null, text: 'German'));
    });
  });

  group('LanguageNamesX', () {
    Future<BuildContext> contextIn(WidgetTester tester, Locale locale) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      return captured;
    }

    testWidgets('names languages and codes in the UI language', (tester) async {
      final context = await contextIn(tester, de);
      expect(context.languageName(french), 'Französisch');
      expect(context.languageName(Language.auto), 'Sprache erkennen');
      expect(
        context.languageName(const Language.custom('Pirate speak')),
        'Pirate speak',
      );
      expect(context.languageNameOf('ja'), 'Japanisch');
      expect(context.languageNameOf('qqq'), 'qqq');
      expect(context.languageNamesLocale, 'de');
      expect(localizedLanguageNameFor(context, 'fr', languages), 'Französisch');
      // An engine-only code keeps the engine's name.
      expect(
        localizedLanguageNameFor(context, 'xx', const [
          Language(code: 'xx', name: 'Engine language'),
        ]),
        'Engine language',
      );
    });

    testWidgets('keeps the English names in English', (tester) async {
      final context = await contextIn(tester, const Locale('en'));
      expect(context.languageName(french), 'French');
      expect(context.languageName(Language.auto), 'Detect language');
      expect(context.languageNameOf('ja'), 'Japanese');
    });

    testWidgets('names languages in Japanese', (tester) async {
      final context = await contextIn(tester, const Locale('ja'));
      expect(context.languageName(english), '英語');
      expect(languageNameIn(AppLocalizations.of(context), english), '英語');
    });
  });
}
