import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/view/dictionary_page.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool meta = false,
  bool shift = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

Future<void> _pressAlt(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
}

Future<void> _focusInput(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('translate_input_field')));
  await tester.pump();
}

void main() {
  setUpAll(registerTranslateFallbacks);

  group('keyboard shortcuts', () {
    testWidgets('Ctrl+Shift+C copies the translation', (tester) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      await _focusInput(tester);
      await _press(tester, LogicalKeyboardKey.keyC, control: true, shift: true);
      await tester.pump();
      expect(clipboard.copied, 'Bonjour le monde');
      expect(find.text('Copied to clipboard'), findsOneWidget);
    });

    testWidgets('Cmd+Shift+C does nothing without a translation', (
      tester,
    ) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(state: readyState(input: 'Hi'));
      await harness.pump(tester);
      await _focusInput(tester);
      await _press(tester, LogicalKeyboardKey.keyC, meta: true, shift: true);
      await tester.pump();
      expect(clipboard.copied, isNull);
    });

    testWidgets('Ctrl+L opens the target picker ready to type', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      await _focusInput(tester);
      await _press(tester, LogicalKeyboardKey.keyL, control: true);
      await tester.pumpAndSettle();
      expect(find.text('Translate to'), findsOneWidget);
      final search = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('translate_language_search')),
          matching: find.byType(EditableText),
        ),
      );
      expect(search.focusNode.hasFocus, isTrue);

      // Type to filter, Enter picks the first match.
      await tester.enterText(
        find.byKey(const Key('translate_language_search')),
        'germ',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      verify(() => harness.translate.setTarget(german)).called(1);
    });

    testWidgets('Cmd+Shift+L opens the source picker', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      await _focusInput(tester);
      await _press(tester, LogicalKeyboardKey.keyL, meta: true, shift: true);
      await tester.pumpAndSettle();
      expect(find.text('Translate from'), findsOneWidget);
    });

    testWidgets('Ctrl+L does nothing without engines', (tester) async {
      final harness = TranslateHarness(
        state: const TranslateState(enginesStatus: EnginesStatus.failure),
      );
      await harness.pump(tester);
      await _press(tester, LogicalKeyboardKey.keyL, control: true);
      await tester.pumpAndSettle();
      expect(find.byType(LanguagePickerSheet), findsNothing);
    });

    testWidgets('Esc clears a focused, non-empty input', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      await _focusInput(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      verify(harness.translate.clear).called(1);
    });

    testWidgets('Esc does nothing when the input is empty', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester);
      await _focusInput(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      verifyNever(harness.translate.clear);
    });

    testWidgets('Ctrl+/ shows the cheat sheet, even while typing', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      await _focusInput(tester);
      await _press(tester, LogicalKeyboardKey.slash, control: true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('translate_shortcuts_dialog')),
        findsOneWidget,
      );
      expect(find.text('Ctrl + Shift + C'), findsOneWidget);
      expect(find.text('Copy the translation'), findsOneWidget);
      expect(find.text('? or Ctrl + /'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate_shortcuts_dialog')), findsNothing);
    });

    testWidgets('? shows the cheat sheet outside text fields', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      // Nothing typed into: the screen itself has focus.
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('translate_shortcuts_dialog')),
        findsOneWidget,
      );
    });

    testWidgets('? is typed, not handled, inside the input', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      await _focusInput(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final handled = await tester.sendKeyEvent(
        LogicalKeyboardKey.slash,
        character: '?',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(handled, isFalse);
      expect(find.byKey(const Key('translate_shortcuts_dialog')), findsNothing);
    });

    testWidgets('the cheat sheet uses ⌘ on Apple platforms', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: const TranslateShortcutsDialog(),
        platform: TargetPlatform.macOS,
      );
      expect(find.text('⌘ + Enter'), findsOneWidget);
      expect(find.text('⌘ + L'), findsOneWidget);
      expect(find.text('Esc'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('⌘ + Shift + L')).semanticsLabel,
        'Command Shift L',
      );
    });

    test('lists every shortcut', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final rows = translateShortcutHelp(l10n, command: false);
      expect(rows.map((r) => r.keys), [
        'Ctrl + Enter',
        'Ctrl + Shift + S',
        'Ctrl + Shift + C',
        'Ctrl + L',
        'Ctrl + Shift + L',
        'Esc',
        'Alt + 1…9',
        '? or Ctrl + /',
      ]);
      expect(rows[6].keysSemantics, 'Alt 1 to 9');
      expect(rows[6].description, 'Translate into pinned language 1 to 9');
      expect(rows.last.keysSemantics, '? or Control /');
      final apple = translateShortcutHelp(l10n, command: true);
      expect(apple[6].keys, '⌥ + 1…9');
      expect(apple[6].keysSemantics, 'Option 1 to 9');
      expect(shortcutUsesCommandKey(TargetPlatform.iOS), isTrue);
      expect(shortcutUsesCommandKey(TargetPlatform.android), isFalse);
    });
  });

  group('pinned target shortcuts', () {
    const pinned = AppSettings(pinnedLanguages: [german, japanese]);

    testWidgets('Alt+1 and Alt+2 pick the pinned targets', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(),
        settings: pinned,
      );
      await harness.pump(tester);
      await _focusInput(tester);
      await _pressAlt(tester, LogicalKeyboardKey.digit1);
      verify(() => harness.translate.selectPinnedTarget(0)).called(1);
      await _pressAlt(tester, LogicalKeyboardKey.digit2);
      verify(() => harness.translate.selectPinnedTarget(1)).called(1);
    });

    testWidgets('every digit up to 9 is bound', (tester) async {
      final digits = [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit5,
        LogicalKeyboardKey.digit6,
        LogicalKeyboardKey.digit7,
        LogicalKeyboardKey.digit8,
        LogicalKeyboardKey.digit9,
      ];
      for (final (index, digit) in digits.indexed) {
        final bound = TranslateView.shortcuts.entries.where(
          (entry) =>
              entry.key is SingleActivator &&
              (entry.key as SingleActivator).trigger == digit &&
              (entry.key as SingleActivator).alt,
        );
        expect(
          bound.single.value,
          isA<SelectPinnedTargetIntent>().having(
            (intent) => intent.index,
            'index',
            index,
          ),
        );
      }
      expect(translatePinnedShortcutCount, digits.length);
    });

    testWidgets('number the pins the engine offers, as the picker does', (
      tester,
    ) async {
      // DeepL here lists no Korean: German is pin 1.
      const korean = Language(code: 'ko', name: 'Korean');
      final harness = TranslateHarness(
        state: translatedState(),
        settings: const AppSettings(pinnedLanguages: [korean, german]),
      );
      await harness.pump(tester);
      await _focusInput(tester);
      await _pressAlt(tester, LogicalKeyboardKey.digit1);
      verify(() => harness.translate.selectPinnedTarget(0)).called(1);
      // There is no second usable pin: the key is not swallowed.
      await _pressAlt(tester, LogicalKeyboardKey.digit2);
      verifyNever(() => harness.translate.selectPinnedTarget(any()));
    });

    testWidgets('announce the picked language, also when pressed again', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: translatedState(),
        settings: pinned,
      );
      when(() => harness.translate.selectPinnedTarget(any())).thenAnswer((_) {
        harness.setState(translatedState().copyWith(target: german));
      });
      await harness.pump(tester, supportsAnnounce: true);
      await _focusInput(tester);
      await _pressAlt(tester, LogicalKeyboardKey.digit1);
      await tester.pump();
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Translating into German'),
      ]);
      await _pressAlt(tester, LogicalKeyboardKey.digit1);
      await tester.pump();
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Translating into German'),
      ]);
    });

    test('browsers get Ctrl/Cmd+Alt+digit instead of Alt+digit', () {
      expect(TranslateView.shortcutsFor(web: false), TranslateView.shortcuts);
      final web = TranslateView.shortcutsFor(web: true);
      final pinned = web.entries
          .where((entry) => entry.value is SelectPinnedTargetIntent)
          .map((entry) => entry.key as SingleActivator)
          .toList();
      expect(pinned, hasLength(2 * translatePinnedShortcutCount));
      expect(pinned.every((activator) => activator.alt), isTrue);
      expect(
        pinned.every((activator) => activator.control != activator.meta),
        isTrue,
      );
      final first = web.entries.firstWhere(
        (entry) =>
            entry.key is SingleActivator &&
            (entry.key as SingleActivator).trigger ==
                LogicalKeyboardKey.digit1 &&
            (entry.key as SingleActivator).control,
      );
      expect((first.value as SelectPinnedTargetIntent).index, 0);
      // The other shortcuts are the same.
      expect(
        web.length,
        TranslateView.shortcuts.length + translatePinnedShortcutCount,
      );
    });

    test('pin shortcuts are shown per platform', () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(translatePinnedShortcut(0, command: false, web: false), (
        keys: 'Alt + 1',
        keysSemantics: 'Alt 1',
      ));
      expect(translatePinnedShortcut(8, command: true, web: false), (
        keys: '⌥ + 9',
        keysSemantics: 'Option 9',
      ));
      expect(translatePinnedShortcut(1, command: false, web: true), (
        keys: 'Ctrl + Alt + 2',
        keysSemantics: 'Control Alt 2',
      ));
      expect(translatePinnedShortcut(2, command: true, web: true), (
        keys: '⌘ + ⌥ + 3',
        keysSemantics: 'Command Option 3',
      ));
      expect(translatePinnedShortcut(9, command: false), isNull);
      expect(translatePinnedShortcut(-1, command: false), isNull);

      final web = translateShortcutHelp(l10n, command: false, web: true);
      expect(web[6].keys, 'Ctrl + Alt + 1…9');
      expect(web[6].keysSemantics, 'Control Alt 1 to 9');
      final appleWeb = translateShortcutHelp(l10n, command: true, web: true);
      expect(appleWeb[6].keys, '⌘ + ⌥ + 1…9');
      expect(showsShortcutHints(TargetPlatform.linux), isTrue);
      expect(showsShortcutHints(TargetPlatform.android), isFalse);
    });

    testWidgets('a missing pin lets the key through', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(),
        settings: pinned,
      );
      await harness.pump(tester);
      await _focusInput(tester);
      await _pressAlt(tester, LogicalKeyboardKey.digit3);
      verifyNever(() => harness.translate.selectPinnedTarget(any()));
    });

    testWidgets('does nothing without engines', (tester) async {
      final harness = TranslateHarness(
        state: const TranslateState(enginesStatus: EnginesStatus.failure),
        settings: pinned,
      );
      await harness.pump(tester);
      await _pressAlt(tester, LogicalKeyboardKey.digit1);
      verifyNever(() => harness.translate.selectPinnedTarget(any()));
    });

    testWidgets('Option+digit types in text fields on macOS', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(),
        settings: pinned,
      );
      await harness.pump(tester, platform: TargetPlatform.macOS);
      // Outside text fields it picks the pin.
      await tester.pump();
      await _pressAlt(tester, LogicalKeyboardKey.digit1);
      verify(() => harness.translate.selectPinnedTarget(0)).called(1);

      await _focusInput(tester);
      await _pressAlt(tester, LogicalKeyboardKey.digit1);
      verifyNever(() => harness.translate.selectPinnedTarget(any()));
    });

    testWidgets('the cheat sheet lists them', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keyboard shortcuts'));
      await tester.pumpAndSettle();
      expect(find.text('Alt + 1…9'), findsOneWidget);
      expect(
        find.text('Translate into pinned language 1 to 9'),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.text('Alt + 1…9')).semanticsLabel,
        'Alt 1 to 9',
      );
    });
  });

  group('More tools menu', () {
    for (final (label, route) in [
      ('Image (camera)', '/image'),
      ('Documents', '/documents'),
      ('Web page', '/web'),
      ('Conversation', '/conversation'),
    ]) {
      testWidgets('$label opens $route', (tester) async {
        final harness = TranslateHarness(state: translatedState());
        await harness.pump(tester);
        await tester.tap(find.byTooltip('More tools'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        verify(() => harness.router.push<void>(route)).called(1);
      });
    }

    Future<void> openTool(WidgetTester tester, String label) async {
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('Dictionary looks up a short input', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(input: '  Hello world '),
      );
      await harness.pump(tester);
      await openTool(tester, 'Dictionary');
      verify(
        () => harness.router.push<void>(
          '/dictionary?word=Hello+world&from=en&to=fr',
          extra: DictionaryLaunch.lookUp,
        ),
      ).called(1);
    });

    testWidgets('Dictionary opens empty for longer text', (tester) async {
      final harness = TranslateHarness(
        state: readyState(
          input: 'One two three four',
          source: german,
          target: const Language.custom('Pirate speak'),
          engine: claude,
        ),
      );
      await harness.pump(tester);
      await openTool(tester, 'Dictionary');
      verify(() => harness.router.push<void>('/dictionary?from=de')).called(1);
    });

    test('translateDictionaryLocation', () {
      expect(
        translateDictionaryLocation(readyState(input: 'gato')),
        '/dictionary?word=gato&from=auto&to=fr',
      );
      expect(
        translateDictionaryLocation(translatedState(input: 'Hola')),
        '/dictionary?word=Hola&from=en&to=fr',
      );
      // A stale detection is not used.
      expect(
        translateDictionaryLocation(
          translatedState(input: 'Hola')
              .copyWith(resultInput: () => 'Hello world'),
        ),
        '/dictionary?word=Hola&from=auto&to=fr',
      );
      expect(
        translateDictionaryLocation(
          readyState(
            input: 'x',
            engine: claude,
            source: const Language.custom('Gen Z slang'),
          ),
        ),
        '/dictionary?word=x&to=fr',
      );
      final long = 'a' * (TranslateCubit.maxDictionaryWordLength + 1);
      expect(translateDictionaryWord(readyState(input: long)), isNull);
      expect(translateDictionaryWord(readyState()), isNull);
    });

    testWidgets('Recent language pairs opens the pairs', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(),
        settings: const AppSettings(
          recentPairs: [LanguagePair(source: german, target: english)],
        ),
      );
      await harness.pump(tester);
      await openTool(tester, 'Recent language pairs');
      expect(find.byType(RecentPairsSheet), findsOneWidget);
      await tester.tap(find.text('\u2068German\u2069 → \u2068English\u2069'));
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.applyLanguagePair(
          const LanguagePair(source: german, target: english),
        ),
      ).called(1);
    });

    testWidgets('Recent language pairs needs engines', (tester) async {
      final harness = TranslateHarness(
        state: const TranslateState(enginesStatus: EnginesStatus.failure),
      );
      await harness.pump(tester);
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      expect(find.text('Recent language pairs'), findsNothing);
      expect(find.text('Dictionary'), findsOneWidget);
      expect(find.text('Keyboard shortcuts'), findsOneWidget);
    });

    testWidgets('lists the keyboard shortcuts', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester);
      await tester.tap(find.byKey(const Key('translate_more_tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keyboard shortcuts'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('translate_shortcuts_dialog')),
        findsOneWidget,
      );
    });

    testWidgets('is available without engines too', (tester) async {
      final harness = TranslateHarness(
        state: const TranslateState(enginesStatus: EnginesStatus.failure),
      );
      await harness.pump(tester);
      expect(find.byTooltip('More tools'), findsOneWidget);
    });

    testWidgets('fits a 320 dp app bar at 200 % text', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(engine: claude).copyWith(
          options: const TranslationOptions(
            formality: Formality.more,
            context: 'landlord',
          ),
        ),
      );
      await harness.pump(tester, size: const Size(320, 640), textScale: 2);
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('More tools'), findsOneWidget);
      expect(find.byType(InputChip), findsNWidgets(2));
    });
  });

  group('offline engines', () {
    const offline = TranslationEngine(
      id: 'offline:mlkit',
      kind: EngineKind.mozhi,
      name: 'On-device',
      isLocal: true,
    );

    testWidgets('the output footer shows the offline badge', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(
          result: const TranslationResult(
            engineId: 'offline:mlkit',
            engineName: 'On-device',
            text: 'Bonjour',
          ),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('Offline'), findsOneWidget);
    });

    testWidgets('the engine sheet lists them on their own', (tester) async {
      final harness = TranslateHarness(
        state: readyState().copyWith(engines: const [deepl, offline]),
      );
      await harness.pump(tester, child: const EngineSelectorButton());
      await tester.tap(find.byKey(const Key('translate_engine_selector')));
      await tester.pumpAndSettle();
      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('On-device'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.byIcon(Icons.offline_bolt_outlined), findsWidgets);
      expect(isOnDeviceEngine(offline), isTrue);
      expect(isOnDeviceEngine(deepl), isFalse);
    });

    testWidgets('a missing model links to the offline page', (tester) async {
      final harness = TranslateHarness(
        state: readyState(engine: offline, input: 'Hello').copyWith(
          status: TranslateStatus.failure,
          error: () => const OfflineModelMissingException(['fr']),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.text('Download languages'));
      verify(() => harness.router.push<void>('/settings/offline')).called(1);
    });
  });

  group('detected language chip', () {
    testWidgets('opens the source picker', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.byKey(const Key('translate_detected_chip')));
      await tester.pumpAndSettle();
      expect(find.text('Translate from'), findsOneWidget);
      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();
      verify(() => harness.translate.setSource(german)).called(1);
    });

    testWidgets('marks an uncertain detection', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(
          input: 'Bank',
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Banque',
            detectedSource: 'de',
          ),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('Detected: German?'), findsOneWidget);
      expect(
        find.byTooltip(
          'Short texts are hard to detect. Choose the source language if '
          'this is wrong.',
        ),
        findsOneWidget,
      );
    });

    test('detectionIsUncertain', () {
      TranslateState state(String input, {String? detected = 'de'}) =>
          translatedState(
            input: input,
            result: TranslationResult(
              engineId: 'x',
              engineName: 'x',
              text: 'x',
              detectedSource: detected,
            ),
          );
      expect(detectionIsUncertain(state('Gift')), isTrue);
      expect(detectionIsUncertain(state('Gift ist')), isFalse);
      expect(detectionIsUncertain(state('Donaudampfschiff')), isFalse);
      expect(detectionIsUncertain(state('안녕')), isFalse);
      expect(detectionIsUncertain(state('Gift', detected: null)), isFalse);
      expect(detectionIsUncertain(state(' ')), isFalse);
      expect(
        detectionIsUncertain(state('Gift').copyWith(source: german)),
        isFalse,
      );
    });
  });
}
