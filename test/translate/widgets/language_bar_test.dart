import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

/// [finder] inside the language picker.
Finder _inPicker(Finder finder) =>
    find.descendant(of: find.byType(LanguagePickerSheet), matching: finder);

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

    testWidgets('flags a detection the engine is unsure about', (tester) async {
      // Two words: only the engine's second detection says it is unsure,
      // and the bar agrees with the chips under the translation.
      final harness = TranslateHarness(
        state: translatedState(
          input: 'Bank Gift',
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Banque cadeau',
            detectedSource: 'en',
            detectionUncertain: true,
            detectedAlternatives: ['de'],
          ),
        ),
      );
      await harness.pump(tester, child: const LanguageBar());
      expect(
        find.bySemanticsLabel('Source language: Detected: English?'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
    });

    testWidgets('updates when only the engine verdict changes', (tester) async {
      const certain = TranslationResult(
        engineId: 'mozhi:deepl',
        engineName: 'DeepL',
        text: 'Banque cadeau',
        detectedSource: 'en',
      );
      final initial = translatedState(input: 'Bank Gift', result: certain);
      final harness = TranslateHarness(state: initial);
      final states = StreamController<TranslateState>.broadcast();
      addTearDown(states.close);
      when(() => harness.translate.stream).thenAnswer((_) => states.stream);
      await harness.pump(tester, child: const LanguageBar());
      expect(find.byIcon(Icons.help_outline), findsNothing);

      final unsure = translatedState(
        input: 'Bank Gift',
        result: certain.copyWith(detectionUncertain: true),
      );
      harness.setState(unsure);
      states.add(unsure);
      await tester.pump();
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
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

    testWidgets('swapping ticks and turns the icon', (tester) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      await tester.tap(find.byKey(const Key('translate_swap_button')));
      await tester.pump();
      expect(clipboard.haptics, ['HapticFeedbackType.selectionClick']);
      final rotation = tester.widget<AnimatedRotation>(
        find.descendant(
          of: find.byKey(const Key('translate_swap_button')),
          matching: find.byType(AnimatedRotation),
        ),
      );
      expect(rotation.turns, 0.5);
      expect(rotation.duration, const Duration(milliseconds: 250));
    });

    testWidgets('swapped names slide along the bar', (tester) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final initial = readyState(source: english, target: german);
      final harness = TranslateHarness(state: initial);
      whenListen(harness.translate, states.stream, initialState: initial);
      await harness.pump(tester, child: const LanguageBar());
      states.add(readyState(source: german, target: english));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Old and new names during the motion (screen readers hear the new
      // ones: the buttons are labelled).
      expect(find.text('German'), findsNWidgets(2));
      expect(find.text('English'), findsNWidgets(2));
      expect(find.byType(SlideTransition), findsWidgets);
      await tester.pumpAndSettle();
      expect(find.text('German'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.bySemanticsLabel('Source language: German'), findsOneWidget);
    });

    testWidgets('swapped names switch at once with reduced motion', (
      tester,
    ) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final initial = readyState(source: english, target: german);
      final harness = TranslateHarness(state: initial);
      whenListen(harness.translate, states.stream, initialState: initial);
      await harness.pump(
        tester,
        child: const LanguageBar(),
        disableAnimations: true,
      );
      states.add(readyState(source: german, target: english));
      await tester.pump();
      await tester.pump();
      expect(find.text('German'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
    });

    testWidgets('marks a custom source', (tester) async {
      final harness = TranslateHarness(
        state: readyState(
          engine: claude,
          source: const Language.custom('Gen Z slang'),
        ),
      );
      await harness.pump(tester, child: const LanguageBar());
      expect(find.text('Gen Z slang'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('translate_source_button')),
          matching: find.byIcon(Icons.auto_awesome),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Source language: Gen Z slang'),
        findsOneWidget,
      );
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

    testWidgets('lists the pins the engine offers, numbered on desktop', (
      tester,
    ) async {
      // A pin saved from another engine ("de-DE") is matched like
      // everywhere else; Korean is not offered.
      const germany = Language(code: 'de-DE', name: 'German (Germany)');
      const korean = Language(code: 'ko', name: 'Korean');
      final harness = TranslateHarness(
        settings: const AppSettings(
          pinnedLanguages: [korean, germany, japanese],
        ),
      );
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(1000, 1600),
        platform: TargetPlatform.linux,
      );
      await openTarget(tester);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Korean'), findsNothing);
      final germanShortcut = find.byKey(
        const ValueKey('translate_language_shortcut:de'),
      );
      expect(tester.widget<Text>(germanShortcut).data, 'Alt + 1');
      expect(tester.widget<Text>(germanShortcut).semanticsLabel, 'Alt 1');
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('translate_language_shortcut:ja')),
            )
            .data,
        'Alt + 2',
      );
      // Only the Pinned entries are numbered.
      expect(find.text('Alt + 3'), findsNothing);
      // Unpinning removes the saved pin.
      await tester.tap(find.byTooltip('Unpin German').first);
      verify(() => harness.settings.togglePinnedLanguage(germany)).called(1);
    });

    testWidgets('pins are not numbered on phones or in the source list', (
      tester,
    ) async {
      final harness = TranslateHarness(
        settings: const AppSettings(pinnedLanguages: [german]),
      );
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(800, 1600),
      );
      await openTarget(tester);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Alt + 1'), findsNothing);
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

    testWidgets('source picker offers a custom language for AI engines', (
      tester,
    ) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      // Style suggestions stay in the target list.
      expect(find.text('Styles'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Gen Z slang',
      );
      await tester.pump();
      expect(find.text('Use “Gen Z slang” as custom language'), findsOneWidget);
      expect(
        find.text(
          'AI models can translate from any dialect or style you describe.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('translate_language_custom')));
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.setSource(const Language.custom('Gen Z slang')),
      ).called(1);
    });

    testWidgets('submitting an unknown source query picks it as custom', (
      tester,
    ) async {
      final harness = TranslateHarness(state: readyState(engine: claude));
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Shakespearean English',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.setSource(
          const Language.custom('Shakespearean English'),
        ),
      ).called(1);
    });

    testWidgets('source picker has no custom language for Mozhi engines', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'Gen Z slang',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.byKey(const Key('translate_language_custom')), findsNothing);
      expect(find.text('No languages match “Gen Z slang”'), findsOneWidget);
      verifyNever(() => harness.translate.setSource(any()));
    });

    testWidgets('source picker lists recent custom languages for AI', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState(
          engine: claude,
          source: const Language.custom('Gen Z slang'),
        ),
        settings: const AppSettings(
          recentLanguages: [Language.custom('Gen Z slang')],
        ),
      );
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);
      // The current custom source is selected.
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('dismissing does not change anything', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openSource(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      verifyNever(() => harness.translate.setSource(any()));
    });

    testWidgets('is full screen on phones', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(360, 740),
      );
      await openTarget(tester);
      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(dialog.insetPadding, EdgeInsets.zero);
      expect(
        tester.getSize(find.byType(LanguagePickerSheet)),
        const Size(360, 740),
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(LanguagePickerSheet), findsNothing);
      verifyNever(() => harness.translate.setTarget(any()));
    });

    testWidgets('is a dialog on wide windows', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(1200, 900),
      );
      await openTarget(tester);
      final size = tester.getSize(find.byType(LanguagePickerSheet));
      expect(size.width, lessThanOrEqualTo(languagePickerDialogSize.width));
      expect(size.height, lessThanOrEqualTo(languagePickerDialogSize.height));
      // Tapping outside closes it.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(LanguagePickerSheet), findsNothing);
    });

    testWidgets('finds languages without their diacritics', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'francais',
      );
      await tester.pump();
      expect(find.text('Français'), findsOneWidget);
      expect(find.text('Deutsch'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      verify(() => harness.translate.setTarget(french)).called(1);
    });

    testWidgets('lists the detected language in the source picker', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(800, 1600),
      );
      await openSource(tester);
      final header = find.byKey(
        const Key('translate_language_section_detected'),
      );
      expect(header, findsOneWidget);
      expect(find.text('Detected'), findsOneWidget);
      // Picking it sets the source explicitly.
      final detected = _inPicker(find.text('English')).first;
      expect(
        tester.getTopLeft(detected).dy,
        greaterThan(tester.getTopLeft(header).dy),
      );
      await tester.tap(detected);
      await tester.pumpAndSettle();
      verify(() => harness.translate.setSource(english)).called(1);
    });

    testWidgets('has no detected section in the target picker', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const LanguageBar());
      await openTarget(tester);
      expect(
        find.byKey(const Key('translate_language_section_detected')),
        findsNothing,
      );
    });

    testWidgets('lists other likely languages of an uncertain detection', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: translatedState(
          input: 'Gift',
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Cadeau',
            detectedSource: 'en',
            detectionUncertain: true,
            detectedAlternatives: ['de'],
          ),
        ),
      );
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(800, 1600),
      );
      await openSource(tester);
      // Detected (English, German), then All languages.
      expect(_inPicker(find.text('English')), findsNWidgets(2));
      expect(_inPicker(find.text('German')), findsNWidgets(2));
    });

    testWidgets('marks and lists the languages that work offline', (
      tester,
    ) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const LanguageBar(),
        size: const Size(800, 1600),
        offline: FakeOfflineTranslator(downloaded: {'de'}),
      );
      await openTarget(tester);
      expect(
        find.byKey(const Key('translate_language_section_downloaded')),
        findsOneWidget,
      );
      expect(find.text('Downloaded (offline)'), findsOneWidget);
      // German and English (the pivot) under Downloaded and All.
      expect(
        find.byKey(const ValueKey('translate_language_offline:de')),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('translate_language_offline:en')),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('translate_language_offline:fr')),
        findsNothing,
      );
      expect(find.bySemanticsLabel(RegExp('Works offline')), findsWidgets);
    });

    testWidgets('marks nothing while only English is on the device', (
      tester,
    ) async {
      for (final offline in [
        FakeOfflineTranslator(),
        FakeOfflineTranslator(isAvailable: false, downloaded: {'de'}),
        FakeOfflineTranslator(downloaded: {'de'}, fails: true),
      ]) {
        final harness = TranslateHarness();
        await harness.pump(
          tester,
          child: const LanguageBar(),
          offline: offline,
        );
        await openTarget(tester);
        expect(
          find.byKey(const Key('translate_language_section_downloaded')),
          findsNothing,
        );
        expect(find.byTooltip('Works offline'), findsNothing);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
      }
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
