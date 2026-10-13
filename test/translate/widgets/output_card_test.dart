import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _insight = WordInsight(
  sourceText: 'world',
  targetText: 'le monde',
  explanation: '"Monde" also means "people" in casual French.',
  variations: [Alternative(text: 'la terre', explanation: 'more poetic')],
);

/// "chat" occurs twice; the insight is about the second one.
const _catSource = 'The cat sleeps. The black cat eats.';
const _catOutput = 'Le chat dort. Le chat noir mange.';
const _blackCat = WordInsight(
  sourceText: 'black cat',
  targetText: 'chat',
  explanation: 'The black one.',
  variations: [Alternative(text: 'matou')],
);

TranslateState _cats() => translatedState(
  assistEngine: claude,
  input: _catSource,
  result: const TranslationResult(
    engineId: 'mozhi:deepl',
    engineName: 'DeepL',
    text: _catOutput,
  ),
).copyWith(insightsStatus: ExtraStatus.ready, insights: const [_blackCat]);

/// "Hello world" -> "Bonjour le monde", after the input was edited.
TranslateState _stale({TranslateStatus? status}) =>
    translatedState(assistEngine: claude).copyWith(
      input: 'Hello there',
      resultInput: () => 'Hello world',
      status: status,
    );

/// Selects [start, end) of the output text and opens the selection toolbar.
Future<void> _select(WidgetTester tester, int start, int end) async {
  final editable = tester.state<EditableTextState>(
    find.descendant(
      of: find.byKey(const Key('translate_output_text')),
      matching: find.byType(EditableText),
    ),
  );
  editable.userUpdateTextEditingValue(
    editable.textEditingValue.copyWith(
      selection: TextSelection(baseOffset: start, extentOffset: end),
    ),
    SelectionChangedCause.longPress,
  );
  await tester.pump();
  expect(editable.showToolbar(), isTrue);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(registerTranslateFallbacks);

  group('OutputCard', () {
    testWidgets('shows a hint when idle', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('Translation'), findsOneWidget);
      expect(find.byKey(const Key('translate_output_progress')), findsNothing);
      expect(find.byTooltip('Copy'), findsNothing);
    });

    testWidgets('shows progress while translating', (tester) async {
      final harness = TranslateHarness(
        state: readyState(input: 'Hi', status: TranslateStatus.translating),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('Translating…'), findsOneWidget);
      expect(
        find.byKey(const Key('translate_output_progress')),
        findsOneWidget,
      );
    });

    testWidgets('streams partial output with progress', (tester) async {
      final harness = TranslateHarness(
        state: readyState(
          engine: claude,
          input: 'Hello world',
          status: TranslateStatus.translating,
          result: const TranslationResult(
            engineId: 'ai:claude',
            engineName: 'Claude',
            text: 'Bonjour',
            isComplete: false,
          ),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('Bonjour'), findsOneWidget);
      expect(
        find.byKey(const Key('translate_output_progress')),
        findsOneWidget,
      );
      // No footer until the result is complete.
      expect(find.byKey(const Key('translate_output_footer')), findsNothing);
    });

    testWidgets('shows the result with footer and detected language', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('Bonjour le monde'), findsOneWidget);
      expect(find.text('DeepL · 0.8 s'), findsOneWidget);
      expect(find.text('Detected: English'), findsOneWidget);
    });

    testWidgets('hides the detected chip when the source is explicit', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState(
          source: english,
          input: 'Hello world',
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Bonjour le monde',
          ),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.byKey(const Key('translate_detected_chip')), findsNothing);
      expect(find.text('DeepL'), findsOneWidget);
    });

    testWidgets('shows the target transliteration when enabled', (
      tester,
    ) async {
      const result = TranslationResult(
        engineId: 'mozhi:google',
        engineName: 'Google',
        text: 'こんにちは',
        targetTransliteration: "Kon'nichiwa",
      );
      final harness = TranslateHarness(
        state: translatedState(input: 'Hello', result: result),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.text("Kon'nichiwa"), findsOneWidget);
    });

    testWidgets('hides the transliteration when disabled', (tester) async {
      const result = TranslationResult(
        engineId: 'mozhi:google',
        engineName: 'Google',
        text: 'こんにちは',
        targetTransliteration: "Kon'nichiwa",
      );
      final harness = TranslateHarness(
        state: translatedState(input: 'Hello', result: result),
        settings: const AppSettings(showTransliteration: false),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.text("Kon'nichiwa"), findsNothing);
    });

    testWidgets('shows a friendly error with retry', (tester) async {
      final harness = TranslateHarness(
        state: readyState(input: 'Hello').copyWith(
          status: TranslateStatus.failure,
          error: () => const MozhiApiException('Connection refused'),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(
        find.textContaining("Couldn't reach the Mozhi instance"),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry'));
      verify(harness.translate.translate).called(1);
      await tester.tap(find.text('Manage instances'));
      verify(() => harness.router.go('/settings/instances')).called(1);
    });

    testWidgets('auth errors point to the API key', (tester) async {
      final harness = TranslateHarness(
        state: readyState(engine: claude, input: 'Hello').copyWith(
          status: TranslateStatus.failure,
          error: () => const LlmApiException('invalid key', statusCode: 401),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.textContaining('Check the API key'), findsOneWidget);
      await tester.tap(find.text('AI providers'));
      verify(() => harness.router.go('/settings/providers')).called(1);
    });

    testWidgets('copy copies the translation', (tester) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.byTooltip('Copy'));
      await tester.pump();
      expect(clipboard.copied, 'Bonjour le monde');
      expect(find.text('Copied to clipboard'), findsOneWidget);
    });

    testWidgets('share shares the translation', (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return 'dev.fluttercommunity.plus/share/success';
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.byTooltip('Share'));
      await tester.pump();
      expect(calls, hasLength(1));
      expect((calls.single.arguments as Map)['text'], 'Bonjour le monde');
    });

    testWidgets('listen reads the translation in the target language', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.byTooltip('Listen'));
      verify(
        () => harness.speech.toggle(
          id: 'target',
          text: 'Bonjour le monde',
          languageCode: 'fr',
        ),
      ).called(1);
    });

    group('favourite', () {
      testWidgets('adds a favourite history entry when none exists', (
        tester,
      ) async {
        final harness = TranslateHarness(state: translatedState());
        await harness.pump(tester, child: const OutputCard());
        await tester.tap(find.byTooltip('Add to favourites'));
        final entry =
            verify(() => harness.history.add(captureAny())).captured.single
                as HistoryEntry;
        expect(entry.text, 'Hello world');
        expect(entry.translation, 'Bonjour le monde');
        expect(entry.isFavorite, isTrue);
        expect(entry.engineId, 'mozhi:deepl');
        expect(entry.target, french);
        expect(entry.detectedSource, 'en');
      });

      testWidgets('toggles the newest matching entry', (tester) async {
        HistoryEntry entry(String id, {bool favorite = false}) => HistoryEntry(
          id: id,
          text: 'Hello world',
          translation: 'Bonjour le monde',
          source: Language.auto,
          target: french,
          engineId: 'mozhi:deepl',
          engineName: 'DeepL',
          createdAt: DateTime(2026),
          isFavorite: favorite,
        );
        final harness = TranslateHarness(
          state: translatedState(),
          history: HistoryState(
            status: HistoryStatus.ready,
            entries: [entry('new', favorite: true), entry('old')],
          ),
        );
        await harness.pump(tester, child: const OutputCard());
        expect(find.byTooltip('Remove from favourites'), findsOneWidget);
        await tester.tap(find.byTooltip('Remove from favourites'));
        verify(() => harness.history.toggleFavorite('new')).called(1);
        verifyNever(() => harness.history.add(any()));
      });
    });

    group('insights', () {
      testWidgets('are not offered without an AI engine', (tester) async {
        final harness = TranslateHarness(state: translatedState());
        await harness.pump(tester, child: const OutputCard());
        expect(find.byTooltip('Insights'), findsNothing);
      });

      testWidgets('toggle loads insights', (tester) async {
        final harness = TranslateHarness(
          state: translatedState(assistEngine: claude),
        );
        await harness.pump(tester, child: const OutputCard());
        await tester.tap(find.byTooltip('Insights'));
        await tester.pump();
        verify(harness.translate.loadInsights).called(1);
        expect(find.byTooltip('Hide insights'), findsOneWidget);
      });

      testWidgets('show progress and empty states', (tester) async {
        final harness = TranslateHarness(
          state: translatedState(assistEngine: claude)
              .copyWith(insightsStatus: ExtraStatus.loading),
        );
        await harness.pump(tester, child: const OutputCard());
        await tester.tap(find.byTooltip('Insights'));
        await tester.pump();
        expect(
          find.byKey(const Key('translate_insights_progress')),
          findsOneWidget,
        );
        verifyNever(harness.translate.loadInsights);
      });

      testWidgets('show a message when there are none', (tester) async {
        final harness = TranslateHarness(
          state: translatedState(assistEngine: claude)
              .copyWith(insightsStatus: ExtraStatus.ready),
        );
        await harness.pump(tester, child: const OutputCard());
        await tester.tap(find.byTooltip('Insights'));
        await tester.pump();
        expect(find.text('No insights for this translation.'), findsOneWidget);
      });

      testWidgets('underlined spans open a sheet; variations apply', (
        tester,
      ) async {
        final harness = TranslateHarness(
          state: translatedState(assistEngine: claude).copyWith(
            insightsStatus: ExtraStatus.ready,
            insights: const [_insight],
          ),
        );
        await harness.pump(tester, child: const OutputCard());
        expect(find.byKey(const Key('translate_insight_text')), findsNothing);
        await tester.tap(find.byTooltip('Insights'));
        await tester.pump();
        expect(find.byKey(const Key('translate_insight_text')), findsOneWidget);

        // The first match is the underlined span in the output text (the
        // insight chips below repeat the phrase).
        await tester.tapOnText(find.textRange.ofSubstring('le monde').first);
        await tester.pumpAndSettle();
        expect(find.text('Nuance'), findsOneWidget);
        expect(find.text(_insight.explanation), findsOneWidget);
        expect(find.text('Other ways to say it'), findsOneWidget);

        await tester.tap(find.text('la terre'));
        await tester.pumpAndSettle();
        // The tapped highlight starts at 8.
        verify(
          () =>
              harness.translate.applyVariation(_insight, 'la terre', offset: 8),
        ).called(1);
        expect(find.text('Other ways to say it'), findsNothing);
      });

      testWidgets('underline the occurrence the insight refers to', (
        tester,
      ) async {
        final harness = TranslateHarness(state: _cats());
        await harness.pump(tester, child: const OutputCard());
        await tester.tap(find.byTooltip('Insights'));
        await tester.pump();

        // The first "chat" is plain text.
        await tester.tapOnText(find.textRange.ofSubstring('chat').first);
        await tester.pumpAndSettle();
        expect(find.text('The black one.'), findsNothing);

        await tester.tapOnText(find.textRange.ofSubstring('chat').at(1));
        await tester.pumpAndSettle();
        expect(find.text('The black one.'), findsOneWidget);
        await tester.tap(find.text('matou'));
        await tester.pumpAndSettle();
        verify(
          () =>
              harness.translate.applyVariation(_blackCat, 'matou', offset: 17),
        ).called(1);
      });

      testWidgets('chips apply variations at the located occurrence', (
        tester,
      ) async {
        final harness = TranslateHarness(state: _cats());
        await harness.pump(tester, child: const OutputCard());
        await tester.tap(find.byTooltip('Insights'));
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('translate_insight_chip:0')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('matou'));
        await tester.pumpAndSettle();
        verify(
          () =>
              harness.translate.applyVariation(_blackCat, 'matou', offset: 17),
        ).called(1);
      });

      testWidgets('are not offered for an out-of-date translation', (
        tester,
      ) async {
        final harness = TranslateHarness(state: _stale());
        await harness.pump(tester, child: const OutputCard());
        final button = tester.widget<IconButton>(
          find.byKey(const Key('translate_insights_button')),
        );
        expect(button.onPressed, isNull);
      });

      testWidgets('reload after the next translation completes', (
        tester,
      ) async {
        final controller = StreamController<TranslateState>.broadcast();
        addTearDown(controller.close);
        final initial = translatedState(assistEngine: claude)
            .copyWith(insightsStatus: ExtraStatus.ready);
        final harness = TranslateHarness(state: initial);
        when(() => harness.translate.stream)
            .thenAnswer((_) => controller.stream);
        await harness.pump(tester, child: const OutputCard());
        await tester.tap(find.byTooltip('Insights'));
        await tester.pump();

        controller.add(
          initial.copyWith(
            status: TranslateStatus.translating,
            insightsStatus: ExtraStatus.idle,
          ),
        );
        await tester.pump();
        verifyNever(harness.translate.loadInsights);
        controller.add(initial.copyWith(insightsStatus: ExtraStatus.idle));
        await tester.pump();
        verify(harness.translate.loadInsights).called(1);
      });
    });
  });

  group('out-of-date translation', () {
    double opacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find.byKey(const Key('translate_output_opacity')),
        )
        .opacity;

    String? hint(WidgetTester tester) => tester
        .getSemantics(find.byKey(const Key('translate_output_semantics')))
        .hint;

    testWidgets('a current translation is shown as is', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      expect(opacity(tester), 1);
      expect(hint(tester), isEmpty);
      handle.dispose();
    });

    testWidgets('is dimmed and described as out of date', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: _stale());
      await harness.pump(tester, child: const OutputCard());
      await tester.pumpAndSettle();
      expect(opacity(tester), staleOutputOpacity);
      expect(hint(tester), 'Out of date — translate again');
      expect(find.text('Bonjour le monde'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('stays dimmed without the hint while translating again', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(
        state: _stale(status: TranslateStatus.translating),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(opacity(tester), staleOutputOpacity);
      expect(hint(tester), isEmpty);
      handle.dispose();
    });

    testWidgets('dims without animation when motion is reduced', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _stale());
      await harness.pump(
        tester,
        child: const OutputCard(),
        disableAnimations: true,
      );
      final widget = tester.widget<AnimatedOpacity>(
        find.byKey(const Key('translate_output_opacity')),
      );
      expect(widget.duration, Duration.zero);
    });

    testWidgets('favourites the text the translation was made for', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _stale());
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.byTooltip('Add to favourites'));
      final entry =
          verify(() => harness.history.add(captureAny())).captured.single
              as HistoryEntry;
      expect(entry.text, 'Hello world');
      expect(entry.translation, 'Bonjour le monde');
    });
  });

  group('alternatives for a selection', () {
    const alternatives = AlternativeTranslations(
      description: '',
      alternatives: [Alternative(text: "l'univers", explanation: 'grander')],
    );

    testWidgets('are offered in the selection toolbar', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(assistEngine: claude),
      );
      await harness.pump(tester, child: const OutputCard());
      // " monde": the leading space is not part of the span.
      await _select(tester, 10, 16);
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(find.text('Alternatives'));
      await tester.pumpAndSettle();
      verify(
        () => harness.translate.loadAlternatives(span: 'monde', spanStart: 11),
      ).called(1);
      expect(
        find.byKey(const Key('translate_span_alternatives_sheet')),
        findsOneWidget,
      );
    });

    testWidgets('can be used from the sheet', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(assistEngine: claude).copyWith(
          alternativesStatus: ExtraStatus.ready,
          alternatives: () => alternatives,
          alternativesSpan: () => 'monde',
          alternativesSpanStart: () => 11,
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      await _select(tester, 11, 16);
      await tester.tap(find.text('Alternatives'));
      await tester.pumpAndSettle();
      expect(find.text('Alternatives for “monde”'), findsOneWidget);
      await tester.tap(find.text("l'univers"));
      await tester.pumpAndSettle();
      verify(() => harness.translate.useAlternative("l'univers")).called(1);
      expect(
        find.byKey(const Key('translate_span_alternatives_sheet')),
        findsNothing,
      );
    });

    testWidgets('are not offered without an AI engine', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      await _select(tester, 11, 16);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Alternatives'), findsNothing);
    });

    testWidgets('are not offered for an out-of-date translation', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _stale());
      await harness.pump(tester, child: const OutputCard());
      await _select(tester, 11, 16);
      expect(find.text('Alternatives'), findsNothing);
    });

    testWidgets('are not offered for blank selections', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(assistEngine: claude),
      );
      await harness.pump(tester, child: const OutputCard());
      await _select(tester, 7, 8);
      expect(find.text('Alternatives'), findsNothing);
    });
  });

  group('describeTranslateError', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('maps errors to readable text', () {
      String message(Object? error) =>
          describeTranslateError(l10n, error).message;
      expect(
        message(const LlmRefusalException('no')),
        l10n.translateErrorRefused,
      );
      expect(
        message(const LlmApiException('x', statusCode: 403)),
        l10n.translateErrorAuth,
      );
      expect(
        message(const LlmApiException('x', statusCode: 429)),
        l10n.translateErrorRateLimited,
      );
      expect(
        message(const LlmApiException('x', statusCode: 404)),
        l10n.translateErrorModelNotFound,
      );
      expect(
        message(const LlmApiException('x')),
        l10n.translateErrorUnreachableProvider,
      );
      expect(
        message(const LlmApiException('x', statusCode: 500)),
        l10n.translateErrorProvider('500'),
      );
      expect(
        message(const MozhiApiException('x')),
        l10n.translateErrorUnreachableInstance,
      );
      expect(
        message(const MozhiApiException('x', statusCode: 429)),
        l10n.translateErrorRateLimited,
      );
      expect(
        message(const MozhiApiException('x', statusCode: 502)),
        l10n.translateErrorInstance('502'),
      );
      expect(message(TimeoutException('x')), l10n.translateErrorTimeout);
      expect(message(StateError('x')), l10n.translateErrorGeneric);
      expect(message(null), l10n.translateErrorGeneric);
    });

    test('suggests where to fix the problem', () {
      expect(
        describeTranslateError(l10n, const MozhiApiException('x')).fix,
        TranslateErrorFix.instances,
      );
      expect(
        describeTranslateError(
          l10n,
          const LlmApiException('x', statusCode: 401),
        ).fix,
        TranslateErrorFix.providers,
      );
      expect(
        describeTranslateError(l10n, const LlmRefusalException('x')).fix,
        TranslateErrorFix.none,
      );
    });
  });
}
