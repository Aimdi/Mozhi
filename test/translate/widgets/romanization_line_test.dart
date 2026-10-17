import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';
import 'output_stubs.dart';

const _arabic = Language(code: 'ar', name: 'Arabic', nativeName: 'العربية');

/// "Hello" -> "こんにちは" by Claude (no transliteration of its own).
const _jaResult = TranslationResult(
  engineId: 'ai:claude',
  engineName: 'Claude',
  text: 'こんにちは',
  detectedSource: 'en',
);

/// The same by Google through Mozhi, with Mozhi's transliteration.
const _mozhiResult = TranslationResult(
  engineId: 'mozhi:google',
  engineName: 'Google',
  text: 'こんにちは',
  targetTransliteration: "Kon'nichiwa",
);

TranslateState _japanese({
  TranslationEngine engine = claude,
  TranslationEngine? assistEngine,
  TranslationResult result = _jaResult,
}) => readyState(
  engine: engine,
  assistEngine: assistEngine,
  input: 'Hello',
  result: result,
  target: japanese,
);

const _off = AppSettings(showTransliteration: false);

Finder get _button => find.byKey(const Key('translate_romanize_button'));
Finder get _line => find.byKey(const Key('translate_output_transliteration'));

void main() {
  setUpAll(registerOutputFallbacks);

  group('romanization helpers', () {
    test('romanizationOf prefers the loaded romanization', () {
      final state = _japanese(result: _mozhiResult);
      expect(romanizationOf(state), "Kon'nichiwa");
      expect(
        romanizationOf(state.copyWith(romanization: () => ' Konnichiwa ')),
        'Konnichiwa',
      );
      expect(romanizationOf(_japanese()), isNull);
      expect(romanizationOf(readyState()), isNull);
    });

    test('romanizationAvailable when shown or romanizable', () {
      expect(romanizationAvailable(_japanese()), isTrue);
      expect(romanizationAvailable(_japanese(result: _mozhiResult)), isTrue);
      // Latin output without an AI engine.
      expect(romanizationAvailable(translatedState()), isFalse);
    });

    test('romanizationLocale is the language in the Latin script', () {
      expect(
        romanizationLocale(japanese),
        const Locale.fromSubtags(languageCode: 'ja', scriptCode: 'Latn'),
      );
      expect(
        romanizationLocale(
          const Language(code: 'zh-TW', name: 'Chinese (Traditional)'),
        ),
        const Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Latn',
          countryCode: 'TW',
        ),
      );
      expect(romanizationLocale(Language.auto), isNull);
      expect(romanizationLocale(const Language.custom('Pirate')), isNull);
    });
  });

  group('romanization', () {
    testWidgets('a loaded romanization is a muted, selectable Latin line', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _japanese().copyWith(
          romanizationStatus: ExtraStatus.ready,
          romanization: () => "Kon'nichiwa",
        ),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      final text = tester.widget<SelectableText>(_line);
      expect(text.textSpan?.toPlainText(), "Kon'nichiwa");
      expect(
        text.textSpan?.locale,
        const Locale.fromSubtags(languageCode: 'ja', scriptCode: 'Latn'),
      );
      expect(text.textDirection, TextDirection.ltr);
      final context = tester.element(_line);
      expect(text.style?.color, Theme.of(context).colorScheme.onSurfaceVariant);
      expect(
        find.descendant(
          of: find.byType(RomanizationLine),
          matching: find.bySemanticsLabel('Romanization'),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Hide romanization'), findsOneWidget);
    });

    testWidgets('stays left to right in right-to-left layouts', (tester) async {
      final harness = TranslateHarness(
        state:
            readyState(
              engine: claude,
              input: 'Hello',
              target: _arabic,
              result: const TranslationResult(
                engineId: 'ai:claude',
                engineName: 'Claude',
                text: 'مرحبا',
              ),
            ).copyWith(
              romanizationStatus: ExtraStatus.ready,
              romanization: () => 'marhaban',
            ),
      );
      stubOutputExtras(harness);
      await harness.pump(
        tester,
        child: const OutputCard(),
        more: true,
        locale: const Locale('ar'),
        themeMode: ThemeMode.dark,
      );
      expect(
        tester.widget<SelectableText>(_line).textDirection,
        TextDirection.ltr,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Show romanization" loads it on demand', (tester) async {
      final harness = TranslateHarness(state: _japanese());
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      expect(_line, findsNothing);
      expect(find.byTooltip('Show romanization'), findsOneWidget);
      expect(tester.widget<TranslateToolChip>(_button).selected, isFalse);
      await tester.tap(_button);
      await tester.pump();
      verify(harness.translate.loadRomanization).called(1);
    });

    testWidgets('is not loaded again while it is loading', (tester) async {
      final harness = TranslateHarness(
        state: _japanese().copyWith(romanizationStatus: ExtraStatus.loading),
        settings: _off,
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      // Hidden by the setting until asked for.
      expect(
        find.byKey(const Key('translate_romanization_progress')),
        findsNothing,
      );
      await tester.tap(_button);
      await tester.pump();
      verifyNever(harness.translate.loadRomanization);
      expect(
        find.byKey(const Key('translate_romanization_progress')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Romanizing…'), findsOneWidget);
      expect(find.byTooltip('Hide romanization'), findsOneWidget);
    });

    testWidgets('shows errors with retry', (tester) async {
      final harness = TranslateHarness(
        state: _japanese().copyWith(
          romanizationStatus: ExtraStatus.failure,
          romanizationError: () => const LlmApiException('x', statusCode: 429),
        ),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      expect(
        find.byKey(const Key('translate_romanization_error')),
        findsOneWidget,
      );
      expect(find.textContaining('Too many requests'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      verify(harness.translate.loadRomanization).called(1);
    });

    testWidgets('a failed romanization is tried again from the button', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _japanese().copyWith(
          romanizationStatus: ExtraStatus.failure,
          romanizationError: () => const LlmApiException('x', statusCode: 500),
        ),
        settings: _off,
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(_button);
      await tester.pump();
      verify(harness.translate.loadRomanization).called(1);
    });

    testWidgets('can be hidden and shown again without a request', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _japanese(engine: google, result: _mozhiResult),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      expect(find.text("Kon'nichiwa"), findsOneWidget);
      expect(tester.widget<TranslateToolChip>(_button).selected, isTrue);

      await tester.tap(_button);
      await tester.pump();
      expect(find.text("Kon'nichiwa"), findsNothing);
      expect(find.byTooltip('Show romanization'), findsOneWidget);

      await tester.tap(_button);
      await tester.pump();
      expect(find.text("Kon'nichiwa"), findsOneWidget);
      verifyNever(harness.translate.loadRomanization);
    });

    testWidgets('an empty romanization shows nothing', (tester) async {
      final harness = TranslateHarness(
        state: _japanese().copyWith(
          romanizationStatus: ExtraStatus.ready,
          romanization: () => ' ',
        ),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      expect(_line, findsNothing);
      expect(
        find.byKey(const Key('translate_romanization_progress')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('translate_romanization_error')),
        findsNothing,
      );
    });

    testWidgets('a romanization that was asked for loads once it is idle', (
      tester,
    ) async {
      final initial = _japanese().copyWith(
        romanizationStatus: ExtraStatus.loading,
      );
      final harness = TranslateHarness(state: initial, settings: _off);
      stubOutputExtras(harness);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(_button);
      await tester.pump();
      verifyNever(harness.translate.loadRomanization);
      // E.g. the request was cancelled: same result, idle again.
      final idle = initial.copyWith(romanizationStatus: ExtraStatus.idle);
      when(() => harness.translate.state).thenReturn(idle);
      controller.add(idle);
      await tester.pump();
      verify(harness.translate.loadRomanization).called(1);
    });

    testWidgets('is not offered for Latin output without an AI engine', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      expect(_button, findsNothing);
    });

    testWidgets('is not offered while streaming', (tester) async {
      final harness = TranslateHarness(
        state: _japanese(
          result: const TranslationResult(
            engineId: 'ai:claude',
            engineName: 'Claude',
            text: 'こんに',
            isComplete: false,
          ),
        ).copyWith(status: TranslateStatus.translating),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard(), more: true);
      expect(_button, findsNothing);
    });

    testWidgets('announces a romanization that was asked for', (tester) async {
      final initial = _japanese();
      final harness = TranslateHarness(state: initial);
      stubOutputExtras(harness);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(
        tester,
        child: const OutputCard(),
        more: true,
        supportsAnnounce: true,
      );
      await tester.tap(_button);
      await tester.pump();
      final loading = initial.copyWith(romanizationStatus: ExtraStatus.loading);
      when(() => harness.translate.state).thenReturn(loading);
      controller.add(loading);
      await tester.pump();
      final loaded = initial.copyWith(
        romanizationStatus: ExtraStatus.ready,
        romanization: () => "Kon'nichiwa",
      );
      when(() => harness.translate.state).thenReturn(loaded);
      controller.add(loaded);
      await tester.pump();
      expect(find.text("Kon'nichiwa"), findsOneWidget);
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Romanization ready'),
      ]);
    });

    testWidgets('automatic romanizations are not announced', (tester) async {
      final initial = _japanese(engine: google, result: _mozhiResult);
      final harness = TranslateHarness(state: initial);
      stubOutputExtras(harness);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(
        tester,
        child: const OutputCard(),
        more: true,
        supportsAnnounce: true,
      );
      final loaded = initial.copyWith(
        romanizationStatus: ExtraStatus.ready,
        romanization: () => 'Konnichiwa',
      );
      when(() => harness.translate.state).thenReturn(loaded);
      controller.add(loaded);
      await tester.pump();
      expect(find.text('Konnichiwa'), findsOneWidget);
      expect(tester.takeAnnouncements(), isEmpty);
    });

    testWidgets('a romanization that was asked for reloads with new results', (
      tester,
    ) async {
      final initial = _japanese();
      final harness = TranslateHarness(state: initial);
      stubOutputExtras(harness);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(_button);
      await tester.pump();
      verify(harness.translate.loadRomanization).called(1);

      // The next translation arrives (romanization reset to idle).
      final next = readyState(
        engine: claude,
        input: 'Good night',
        target: japanese,
        result: const TranslationResult(
          engineId: 'ai:claude',
          engineName: 'Claude',
          text: 'おやすみなさい',
        ),
      );
      when(() => harness.translate.state).thenReturn(next);
      controller.add(next);
      await tester.pump();
      verify(harness.translate.loadRomanization).called(1);
    });

    testWidgets('a romanization that was asked for is not paid for again '
        'after an instant translation', (tester) async {
      final initial = _japanese();
      final harness = TranslateHarness(state: initial, settings: _off);
      stubOutputExtras(harness);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.tap(_button);
      await tester.pump();
      verify(harness.translate.loadRomanization).called(1);

      final next = readyState(
        engine: claude,
        input: 'Good night',
        target: japanese,
        result: const TranslationResult(
          engineId: 'ai:claude',
          engineName: 'Claude',
          text: 'おやすみなさい',
        ),
      ).copyWith(instantResult: true);
      when(() => harness.translate.state).thenReturn(next);
      controller.add(next);
      await tester.pump();
      verifyNever(harness.translate.loadRomanization);
      // The button offers it again.
      expect(find.byTooltip('Show romanization'), findsOneWidget);
    });

    testWidgets('a reloaded romanization is not announced again', (
      tester,
    ) async {
      final initial = _japanese();
      final harness = TranslateHarness(state: initial);
      stubOutputExtras(harness);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(
        tester,
        child: const OutputCard(),
        more: true,
        supportsAnnounce: true,
      );
      await tester.tap(_button);
      await tester.pump();
      controller.add(
        initial.copyWith(
          romanizationStatus: ExtraStatus.ready,
          romanization: () => "Kon'nichiwa",
        ),
      );
      await tester.pump();
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Romanization ready'),
      ]);

      // The next translation (asked for) is romanized on its own: only the
      // translation itself is announced.
      const nextResult = TranslationResult(
        engineId: 'ai:claude',
        engineName: 'Claude',
        text: 'おやすみなさい',
      );
      final next = readyState(
        engine: claude,
        input: 'Good night',
        target: japanese,
        result: nextResult,
      );
      controller.add(next);
      await tester.pump();
      verify(harness.translate.loadRomanization).called(2);
      controller.add(
        next.copyWith(
          romanizationStatus: ExtraStatus.ready,
          romanization: () => 'Oyasuminasai',
        ),
      );
      await tester.pump();
      expect(find.text('Oyasuminasai'), findsOneWidget);
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        isNot(contains('Romanization ready')),
      );
    });

    testWidgets('automatic romanizations do not reload on their own', (
      tester,
    ) async {
      final initial = _japanese();
      final harness = TranslateHarness(state: initial);
      stubOutputExtras(harness);
      whenListen(
        harness.translate,
        Stream.value(
          initial.copyWith(result: () => _jaResult.copyWith(text: 'やあ')),
        ),
        initialState: initial,
      );
      await harness.pump(tester, child: const OutputCard(), more: true);
      await tester.pump();
      verifyNever(harness.translate.loadRomanization);
    });
  });
}
