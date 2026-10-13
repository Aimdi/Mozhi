import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/proofread_helpers.dart';

void main() {
  late MockProofreadCubit cubit;
  late MockTranslateCubit translateCubit;
  late MockGoRouter router;

  setUpAll(() {
    registerFallbackValue(openAiEngine);
    registerFallbackValue(WritingStyle.general);
    registerFallbackValue(CorrectionLevel.standard);
    registerFallbackValue(Formality.automatic);
  });

  setUp(() {
    cubit = MockProofreadCubit();
    translateCubit = MockTranslateCubit();
    router = MockGoRouter();
    stubProofreadCubit(cubit);
  });

  Future<void> pumpView(
    WidgetTester tester,
    ProofreadState state, {
    Stream<ProofreadState>? stream,
    TranslateState translateState = readyTranslateState,
    Stream<TranslateState>? translateStream,
    Size size = const Size(800, 2400),
    ThemeData? theme,
  }) async {
    setSurface(tester, size);
    whenListen(
      cubit,
      stream ?? const Stream<ProofreadState>.empty(),
      initialState: state,
    );
    whenListen(
      translateCubit,
      translateStream ?? const Stream<TranslateState>.empty(),
      initialState: translateState,
    );
    await tester.pumpProofread(
      const ProofreadView(),
      translateCubit: translateCubit,
      proofreadCubit: cubit,
      router: router,
      theme: theme,
    );
  }

  group('ProofreadView', () {
    group('empty state', () {
      testWidgets('explains that an AI provider is needed', (tester) async {
        await pumpView(tester, const ProofreadState());
        expect(find.text('Proofreading needs an AI provider'), findsOneWidget);
        expect(find.byType(ProofreadInputCard), findsNothing);

        await tester.tap(find.text('Add AI provider'));
        verify(() => router.go('/settings/providers')).called(1);
      });

      testWidgets('shows a spinner while engines load', (tester) async {
        await pumpView(
          tester,
          const ProofreadState(),
          translateState: const TranslateState(
            enginesStatus: EnginesStatus.loading,
          ),
        );
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byType(ProofreadEmptyState), findsNothing);
      });
    });

    testWidgets('syncs engines from the translate cubit', (tester) async {
      const updated = TranslateState(
        enginesStatus: EnginesStatus.ready,
        engines: [googleEngine, openAiEngine, ollamaEngine],
        assistEngine: ollamaEngine,
      );
      await pumpView(
        tester,
        readyState,
        translateStream: Stream.value(updated),
      );
      await tester.pump();
      verify(() => cubit.setEngines(updated.engines, preferred: ollamaEngine))
          .called(1);
    });

    group('input', () {
      testWidgets('shows the input and forwards typing', (tester) async {
        await pumpView(tester, readyState.copyWith(input: 'Hello'));
        expect(find.text('Hello'), findsOneWidget);
        expect(find.text('5 characters'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('proofread_input')),
          'Hello wrold',
        );
        verify(() => cubit.setInput('Hello wrold')).called(1);
      });

      testWidgets('follows external input changes', (tester) async {
        final controller = StreamController<ProofreadState>();
        addTearDown(controller.close);
        await pumpView(tester, readyState, stream: controller.stream);
        controller.add(readyState.copyWith(input: 'From outside'));
        await tester.pump();
        final field = tester.widget<TextField>(
          find.byKey(const Key('proofread_input')),
        );
        expect(field.controller!.text, 'From outside');
        expect(find.text('1 character'), findsNothing);
      });

      testWidgets('pastes from the clipboard', (tester) async {
        FakeClipboard()
          ..clipboardText = 'pasted'
          ..install(tester);
        await pumpView(tester, readyState);
        await tester.tap(find.byTooltip('Paste'));
        await tester.pump();
        verify(() => cubit.setInput('pasted')).called(1);
      });

      testWidgets('ignores an empty clipboard', (tester) async {
        FakeClipboard().install(tester);
        await pumpView(tester, readyState);
        await tester.tap(find.byTooltip('Paste'));
        await tester.pump();
        verifyNever(() => cubit.setInput(any()));
      });

      testWidgets('clears the input', (tester) async {
        await pumpView(tester, readyState.copyWith(input: 'x'));
        expect(find.text('1 character'), findsOneWidget);
        await tester.tap(find.byTooltip('Clear'));
        verify(() => cubit.clear()).called(1);
      });

      testWidgets('hides the clear button for empty input', (tester) async {
        await pumpView(tester, readyState);
        expect(find.byTooltip('Clear'), findsNothing);
      });

      testWidgets('Ctrl+Enter proofreads', (tester) async {
        await pumpView(tester, readyState.copyWith(input: 'text'));
        await tester.tap(find.byKey(const Key('proofread_input')));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        verify(() => cubit.proofread()).called(1);
      });

      testWidgets('Ctrl+Enter does nothing when not ready', (tester) async {
        await pumpView(tester, readyState);
        await tester.tap(find.byKey(const Key('proofread_input')));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        verifyNever(() => cubit.proofread());
      });
    });

    group('proofread button', () {
      FilledButton button(WidgetTester tester) => tester.widget<FilledButton>(
        find.byKey(const Key('proofread_button')),
      );

      testWidgets('is disabled without input', (tester) async {
        await pumpView(tester, readyState);
        expect(button(tester).onPressed, isNull);
      });

      testWidgets('proofreads on tap', (tester) async {
        await pumpView(tester, readyState.copyWith(input: 'text'));
        await tester.tap(find.byKey(const Key('proofread_button')));
        verify(() => cubit.proofread()).called(1);
      });

      testWidgets('shows progress while loading', (tester) async {
        await pumpView(
          tester,
          readyState.copyWith(input: 'text', status: ProofreadStatus.loading),
        );
        expect(find.text('Checking…'), findsOneWidget);
        expect(find.text('Checking your text…'), findsOneWidget);
        expect(button(tester).onPressed, isNull);
      });
    });

    group('controls', () {
      testWidgets('changes the writing style', (tester) async {
        await pumpView(tester, readyState);
        expect(find.textContaining('General'), findsOneWidget);
        await tester.tap(find.byKey(const Key('proofread_style_menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Academic'));
        await tester.pumpAndSettle();
        verify(() => cubit.setStyle(WritingStyle.academic)).called(1);
      });

      testWidgets('changes the formality', (tester) async {
        await pumpView(tester, readyState);
        await tester.tap(find.byKey(const Key('proofread_formality_menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Less formal'));
        await tester.pumpAndSettle();
        verify(() => cubit.setFormality(Formality.less)).called(1);
      });

      testWidgets('menu button toggles its menu', (tester) async {
        await pumpView(tester, readyState);
        await tester.tap(find.byKey(const Key('proofread_formality_menu')));
        await tester.pumpAndSettle();
        expect(find.text('Prefer informal'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('proofread_formality_menu')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(find.text('Prefer informal'), findsNothing);
      });

      testWidgets('changes the correction level', (tester) async {
        await pumpView(tester, readyState);
        await tester.tap(find.text('Comprehensive'));
        verify(() => cubit.setLevel(CorrectionLevel.comprehensive)).called(1);
      });

      testWidgets('hides the engine picker for a single engine', (
        tester,
      ) async {
        await pumpView(tester, readyState);
        expect(find.byKey(const Key('proofread_engine_menu')), findsNothing);
      });

      testWidgets('picks among several AI engines', (tester) async {
        await pumpView(
          tester,
          readyState.copyWith(availableEngines: [openAiEngine, ollamaEngine]),
        );
        await tester.tap(find.byKey(const Key('proofread_engine_menu')));
        await tester.pumpAndSettle();
        expect(find.text('llama3'), findsOneWidget);
        expect(find.byTooltip('Runs locally'), findsOneWidget);
        await tester.tap(find.text('Ollama'));
        await tester.pumpAndSettle();
        verify(() => cubit.setEngine(ollamaEngine)).called(1);
      });

      testWidgets('adds and removes context', (tester) async {
        await pumpView(tester, readyState);
        expect(find.byKey(const Key('proofread_context')), findsNothing);
        await tester.tap(find.text('Add context'));
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('proofread_context')),
          'cover letter',
        );
        verify(() => cubit.setContext('cover letter')).called(1);

        await tester.tap(find.byTooltip('Clear'));
        await tester.pump();
        verify(() => cubit.setContext('')).called(1);
        expect(find.byKey(const Key('proofread_context')), findsNothing);
      });

      testWidgets('shows existing context', (tester) async {
        await pumpView(tester, readyState.copyWith(context: 'thesis'));
        expect(find.text('thesis'), findsOneWidget);
        expect(find.text('Add context'), findsNothing);
      });
    });

    group('result', () {
      testWidgets('shows the diff, summary and edits', (tester) async {
        await pumpView(tester, successState());
        expect(find.text('Corrected text'), findsOneWidget);
        expect(find.byKey(const Key('proofread_diff')), findsOneWidget);
        expect(find.text('Fixed agreement and articles.'), findsOneWidget);
        expect(find.text('Suggested edits'), findsOneWidget);
        expect(find.text('3 of 3 applied'), findsOneWidget);
        expect(find.text('Grammar'), findsOneWidget);
        expect(find.text('Word choice'), findsOneWidget);
        expect(find.text('Fact check'), findsOneWidget);
        expect(find.text('Subject-verb agreement.'), findsOneWidget);
        expect(find.byType(ProofreadEditTile), findsNWidgets(3));
      });

      testWidgets('toggles, accepts and rejects edits', (tester) async {
        await pumpView(tester, successState(accepted: {0}));
        expect(find.text('1 of 3 applied'), findsOneWidget);

        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('proofread_edit_1')),
            matching: find.byType(Checkbox),
          ),
        );
        verify(() => cubit.toggleEdit(1)).called(1);

        await tester.tap(find.text('Accept all'));
        verify(() => cubit.acceptAll()).called(1);
        await tester.tap(find.text('Reject all'));
        verify(() => cubit.rejectAll()).called(1);
      });

      testWidgets('disables accept all when everything is applied', (
        tester,
      ) async {
        await pumpView(tester, successState());
        final accept = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Accept all'),
        );
        expect(accept.onPressed, isNull);
      });

      testWidgets('disables reject all when nothing is applied', (
        tester,
      ) async {
        await pumpView(tester, successState(accepted: {}));
        final reject = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Reject all'),
        );
        expect(reject.onPressed, isNull);
      });

      testWidgets('hides changes to show the clean output', (tester) async {
        await pumpView(tester, successState(accepted: {0}));
        await tester.tap(find.byTooltip('Hide changes'));
        await tester.pump();
        expect(find.byKey(const Key('proofread_diff')), findsNothing);
        expect(find.text('I have a apple and a orange.'), findsOneWidget);

        await tester.tap(find.byTooltip('Show changes'));
        await tester.pump();
        expect(find.byKey(const Key('proofread_diff')), findsOneWidget);
      });

      testWidgets('highlights accepted edits in the diff', (tester) async {
        await pumpView(tester, successState(accepted: {0}));
        final spans = _diffSpans(tester);
        final colors = ProofreadDiffColors.of(
          tester.element(find.byKey(const Key('proofread_diff'))),
        );
        final removed = spans.singleWhere((s) => s.text == 'has');
        final inserted = spans.singleWhere((s) => s.text == 'have');
        expect(removed.style, colors.removedStyle);
        expect(removed.style!.decoration, TextDecoration.lineThrough);
        expect(removed.semanticsLabel, 'removed: has');
        expect(inserted.style, colors.insertedStyle);
        expect(inserted.semanticsLabel, 'added: have');
        expect(spans.map((s) => s.text).join(), contains('a apple'));
      });

      testWidgets('uses a word diff when correctedText has extra changes', (
        tester,
      ) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(
              correctedText: 'We have an apple.',
              edits: [ProofreadEdit(original: 'has', replacement: 'have')],
            ),
            proofreadInput: 'I has an apple.',
            acceptedEdits: {0},
          ),
        );
        final spans = _diffSpans(tester);
        expect(spans.map((s) => s.text), ['I has', 'We have', ' an apple.']);
        expect(spans.every((s) => s.recognizer == null), isTrue);
      });

      testWidgets('tapping a change opens its details', (tester) async {
        await pumpView(tester, successState(accepted: {0}));
        final removed = _diffSpans(tester).singleWhere((s) => s.text == 'has');
        (removed.recognizer! as TapGestureRecognizer).onTap!();
        await tester.pumpAndSettle();

        expect(find.byType(BottomSheet), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.text('Subject-verb agreement.'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Revert edit'));
        await tester.pumpAndSettle();
        verify(() => cubit.toggleEdit(0)).called(1);
        expect(find.byType(BottomSheet), findsNothing);
      });

      testWidgets('details of a rejected edit offer to apply it', (
        tester,
      ) async {
        await pumpView(tester, successState(accepted: {}));
        final element = tester.element(find.byKey(const Key('proofread_diff')));
        unawaited(showProofreadEditSheet(element, 2));
        await tester.pumpAndSettle();
        expect(find.text('Fact check'), findsNWidgets(2));
        await tester.tap(find.text('Apply edit'));
        await tester.pumpAndSettle();
        verify(() => cubit.toggleEdit(2)).called(1);
      });

      testWidgets('edit sheet ignores invalid indices', (tester) async {
        await pumpView(tester, successState());
        final element = tester.element(find.byKey(const Key('proofread_diff')));
        await showProofreadEditSheet(element, 9);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
      });

      testWidgets('copies the output', (tester) async {
        final clipboard = FakeClipboard()..install(tester);
        await pumpView(tester, successState());
        await tester.tap(find.byTooltip('Copy'));
        await tester.pump();
        expect(clipboard.copied, 'I have an apple and an orange.');
        expect(find.text('Copied to clipboard'), findsOneWidget);
      });

      testWidgets('shares the output', (tester) async {
        final calls = <MethodCall>[];
        const channel = MethodChannel('dev.fluttercommunity.plus/share');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call);
            return 'dev.fluttercommunity.plus/share/unavailable';
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await pumpView(tester, successState(accepted: {1, 2}));
        await tester.tap(find.byTooltip('Share'));
        await tester.pump();
        expect(calls, hasLength(1));
        final arguments = calls.single.arguments as Map;
        expect(arguments['text'], 'I has an apple and an orange.');
        expect(arguments['originWidth'], greaterThan(0));
      });

      testWidgets('swallows share failures', (tester) async {
        const channel = MethodChannel('dev.fluttercommunity.plus/share');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async => throw PlatformException(code: 'error'),
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await pumpView(tester, successState());
        await tester.tap(find.byTooltip('Share'));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('uses the output as input', (tester) async {
        await pumpView(tester, successState());
        await tester.tap(find.text('Use as input'));
        verify(() => cubit.useOutputAsInput()).called(1);
      });

      testWidgets('disables output actions for empty output', (tester) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(
              correctedText: '',
              edits: [ProofreadEdit(original: 'x', replacement: '')],
            ),
            proofreadInput: 'x',
          ),
        );
        final copy = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.copy_outlined),
        );
        expect(copy.onPressed, isNull);
      });

      testWidgets('flags edits that could not be located', (tester) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(
              correctedText: 'Fixed.',
              edits: [ProofreadEdit(original: 'nowhere', replacement: 'x')],
            ),
          ),
        );
        expect(
          find.text("Couldn't match this edit to your text."),
          findsOneWidget,
        );
      });

      testWidgets('shows insertions and deletions in edit tiles', (
        tester,
      ) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(
              correctedText: '',
              edits: [
                ProofreadEdit(original: '', replacement: 'inserted'),
                ProofreadEdit(original: 'has ', replacement: ''),
              ],
            ),
            acceptedEdits: {0, 1},
          ),
        );
        expect(find.textContaining('inserted'), findsOneWidget);
        expect(find.textContaining('→'), findsNothing);
      });

      testWidgets('shows a clean result', (tester) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(correctedText: sampleInput),
            acceptedEdits: {},
          ),
        );
        expect(find.text('Looks good!'), findsOneWidget);
        expect(find.text('No issues found in your text.'), findsOneWidget);
        expect(find.text('Suggested edits'), findsNothing);
      });

      testWidgets('shows the summary of a clean result', (tester) async {
        await pumpView(
          tester,
          successState().copyWith(
            result: () => const ProofreadResult(
              correctedText: '',
              summary: 'Clear and concise.',
            ),
            acceptedEdits: {},
          ),
        );
        expect(find.text('Clear and concise.'), findsOneWidget);
      });

      testWidgets('keeps the result visible while re-proofreading', (
        tester,
      ) async {
        await pumpView(
          tester,
          successState().copyWith(status: ProofreadStatus.loading),
        );
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.text('Corrected text'), findsOneWidget);
      });
    });

    group('errors', () {
      Future<void> pumpError(WidgetTester tester, Object error) => pumpView(
        tester,
        readyState.copyWith(
          input: 'text',
          status: ProofreadStatus.failure,
          error: () => error,
        ),
      );

      testWidgets('shows a generic message and retries', (tester) async {
        await pumpError(tester, Exception('boom'));
        expect(find.text("Couldn't proofread"), findsOneWidget);
        expect(
          find.text('Something went wrong. Please try again.'),
          findsOneWidget,
        );
        await tester.tap(find.text('Retry'));
        verify(() => cubit.proofread()).called(1);
      });

      testWidgets('explains refusals', (tester) async {
        await pumpError(tester, const LlmRefusalException('no'));
        expect(
          find.text('The model declined to proofread this text.'),
          findsOneWidget,
        );
      });

      testWidgets('explains auth errors', (tester) async {
        await pumpError(tester, const LlmApiException('x', statusCode: 401));
        expect(
          find.text(
            'The AI provider rejected the API key. Check it in Settings.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('explains rate limits', (tester) async {
        await pumpError(tester, const LlmApiException('x', statusCode: 429));
        expect(
          find.text(
            'The AI provider is rate limiting requests. Try again in a moment.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('shows provider messages', (tester) async {
        await pumpError(
          tester,
          const LlmApiException('model not found', statusCode: 404),
        );
        expect(
          find.text('The AI provider returned an error: model not found'),
          findsOneWidget,
        );
      });

      testWidgets('falls back for empty provider messages', (tester) async {
        await pumpError(tester, const LlmApiException(' ', statusCode: 500));
        expect(
          find.text('Something went wrong. Please try again.'),
          findsOneWidget,
        );
      });
    });

    group('wide layout', () {
      testWidgets('shows input and result side by side', (tester) async {
        await pumpView(tester, readyState, size: const Size(1400, 1000));
        expect(
          find.text(
            'Your corrected text and suggested edits will appear here.',
          ),
          findsOneWidget,
        );
        final input = tester.getTopLeft(find.byType(ProofreadInputCard));
        final result = tester.getTopLeft(find.byType(ProofreadResultSection));
        expect(result.dx, greaterThan(input.dx));
      });

      testWidgets('narrow layout has no placeholder', (tester) async {
        await pumpView(tester, readyState);
        expect(
          find.text(
            'Your corrected text and suggested edits will appear here.',
          ),
          findsNothing,
        );
      });
    });

    testWidgets('renders in dark mode with dark diff colors', (tester) async {
      await pumpView(
        tester,
        successState(),
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      );
      final context = tester.element(find.byKey(const Key('proofread_diff')));
      final dark = ProofreadDiffColors.of(context);
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(
        dark.insertedBackground.computeLuminance(),
        lessThan(dark.insertedForeground.computeLuminance()),
      );
      expect(tester.takeException(), isNull);
    });
  });
}

List<TextSpan> _diffSpans(WidgetTester tester) {
  final richText = tester.widget<RichText>(
    find.descendant(
      of: find.byKey(const Key('proofread_diff')),
      matching: find.byType(RichText),
    ),
  );
  final spans = <TextSpan>[];
  richText.text.visitChildren((span) {
    if (span is TextSpan && span.text != null) spans.add(span);
    return true;
  });
  return spans;
}
