import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

void main() {
  setUpAll(registerTranslateFallbacks);

  group('LanguageBar', () {
    testWidgets('shows "Detect language" before anything is detected', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      expect(find.text('Detect language'), findsOneWidget);
      expect(find.text('French'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Source language: Detect language'),
        findsOneWidget,
      );
    });

    testWidgets('shows the detected language', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      expect(find.text('English'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Source language: Detected: English'),
        findsOneWidget,
      );
    });

    testWidgets('shows the selected source language', (tester) async {
      final harness = TranslateHarness(state: readyState(source: german));
      await harness.pump(tester, child: const LanguageBar());
      expect(find.text('German'), findsOneWidget);
    });

    testWidgets('swap calls swap when allowed', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      await tester.tap(find.byTooltip('Swap languages'));
      verify(harness.translate.swap).called(1);
    });

    testWidgets('swap is disabled for a custom target', (tester) async {
      final harness = TranslateHarness(
        state: readyState(
          engine: claude,
          target: const Language.custom('Pirate speak'),
        ),
      );
      await harness.pump(tester, child: const LanguageBar());
      final swap = tester.widget<IconButton>(
        find.byKey(const Key('translate_swap_button')),
      );
      expect(swap.onPressed, isNull);
      expect(find.text('Pirate speak'), findsOneWidget);
    });
  });

  group('LanguagePickerSheet', () {
    Future<void> openTarget(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('translate_target_button')));
      await tester.pumpAndSettle();
    }

    Future<void> openSource(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('translate_source_button')));
      await tester.pumpAndSettle();
    }

    testWidgets('lists all languages with native names', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      expect(find.text('Translate to'), findsOneWidget);
      expect(find.text('All languages'), findsOneWidget);
      expect(find.text('Deutsch'), findsOneWidget);
      expect(find.text('日本語'), findsOneWidget);
      // AI styles are not offered for Mozhi engines.
      expect(find.text('Styles'), findsNothing);
    });

    testWidgets('search filters and picking sets the target', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'deu',
      );
      await tester.pump();
      expect(find.text('German'), findsOneWidget);
      expect(find.text('Japanese'), findsNothing);
      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.setTarget(german)).called(1);
      expect(find.text('Translate to'), findsNothing);
    });

    testWidgets('submitting the search picks the first match', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'ja',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      verify(() => harness.translate.setTarget(japanese)).called(1);
    });

    testWidgets('shows no results for Mozhi engines', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Klingon',
      );
      await tester.pump();
      expect(find.text('No languages match “Klingon”'), findsOneWidget);
      expect(find.byKey(const Key('translate_language_custom')), findsNothing);
    });

    testWidgets('offers a custom language for AI engines', (tester) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Yoda speak',
      );
      await tester.pump();
      expect(find.text('Use “Yoda speak” as custom language'), findsOneWidget);
      await tester.tap(find.byKey(const Key('translate_language_custom')));
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.setTarget(const Language.custom('Yoda speak')),
      ).called(1);
    });

    testWidgets('submitting an unknown query picks it as custom (AI)', (
      tester,
    ) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Valley girl',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.setTarget(const Language.custom('Valley girl')),
      ).called(1);
    });

    testWidgets('offers style suggestions for AI engines', (tester) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      expect(find.text('Styles'), findsOneWidget);
      await tester.tap(find.text('LinkedIn Speak'));
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.setTarget(
          const Language.custom('LinkedIn Speak'),
        ),
      ).called(1);
    });

    testWidgets('search also filters styles', (tester) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'pirate',
      );
      await tester.pump();
      expect(find.text('Pirate speak'), findsOneWidget);
      expect(find.text('LinkedIn Speak'), findsNothing);
      expect(find.text('Use “pirate” as custom language'), findsOneWidget);
    });

    testWidgets('shows recent and pinned sections', (tester) async {
      final harness = TranslateHarness(
        settings: const AppSettings(
          recentLanguages: [german, Language.custom('Pirate speak')],
          pinnedLanguages: [japanese],
        ),
      );
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(800, 1600),
      );
      await openTarget(tester);
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('German'), findsNWidgets(2));
      expect(find.text('Japanese'), findsNWidgets(2));
      // Custom recents are hidden for Mozhi engines.
      expect(find.text('Pirate speak'), findsNothing);
      expect(find.byTooltip('Unpin Japanese'), findsNWidgets(2));
    });

    testWidgets('pin button and long press toggle pins', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.tap(find.byTooltip('Pin French'));
      verify(() => harness.settings.togglePinnedLanguage(french)).called(1);
      await tester.longPress(find.text('German'));
      verify(() => harness.settings.togglePinnedLanguage(german)).called(1);
    });

    testWidgets('source picker starts with detect language', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      expect(find.text('Translate from'), findsOneWidget);
      expect(find.byKey(const Key('translate_language_auto')), findsOneWidget);
      expect(find.text('Detected: English'), findsOneWidget);
      // No styles in the source list, even for AI engines.
      expect(find.text('Styles'), findsNothing);
      await tester.tap(find.byKey(const Key('translate_language_auto')));
      await tester.pumpAndSettle();
      verify(() => harness.translate.setSource(Language.auto)).called(1);
    });

    testWidgets('source picker sets a source language', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      await tester.tap(find.text('French').last);
      await tester.pumpAndSettle();
      verify(() => harness.translate.setSource(french)).called(1);
    });

    testWidgets('dismissing does not change anything', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      verifyNever(() => harness.translate.setSource(any()));
    });

    testWidgets('clear button resets the search', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'xyz',
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Clear'));
      await tester.pump();
      expect(find.text('All languages'), findsOneWidget);
    });
  });
}
