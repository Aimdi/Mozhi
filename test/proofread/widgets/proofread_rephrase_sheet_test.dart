import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/proofread/proofread.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/proofread_helpers.dart';

const _input = 'I has an apple. It is red. We like it.';
const _corrected = 'I have an apple. It is red. We like it.';
const _result = ProofreadResult(
  correctedText: _corrected,
  edits: [
    ProofreadEdit(
      original: 'has',
      replacement: 'have',
      explanation: 'Agreement.',
    ),
  ],
);

void main() {
  late MockTranslationRepository repository;
  late MockTranslateCubit translateCubit;
  late ProofreadCubit cubit;

  setUpAll(() {
    registerFallbackValue(openAiEngine);
    registerFallbackValue(WritingStyle.general);
    registerFallbackValue(WritingTone.automatic);
    registerFallbackValue(Formality.automatic);
  });

  setUp(() {
    repository = MockTranslationRepository();
    translateCubit = MockTranslateCubit();
    whenListen(
      translateCubit,
      const Stream<TranslateState>.empty(),
      initialState: readyTranslateState,
    );
    cubit =
        ProofreadCubit(repository: repository, engines: const [openAiEngine])
          ..emit(
            readyState.copyWith(
              input: _input,
              status: ProofreadStatus.success,
              result: () => _result,
              proofreadInput: _input,
              acceptedEdits: {0},
            ),
          );
    addTearDown(cubit.close);
  });

  void stubRephrase(Future<List<String>> Function() answer) => when(
    () => repository.rephrase(
      any(),
      any(),
      any(),
      style: any(named: 'style'),
      tone: any(named: 'tone'),
      formality: any(named: 'formality'),
      count: any(named: 'count'),
      uiLanguage: any(named: 'uiLanguage'),
    ),
  ).thenAnswer((_) => answer());

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(800, 2000),
    ThemeData? theme,
    Widget child = const Scaffold(
      body: SingleChildScrollView(child: ProofreadResultSection()),
    ),
  }) async {
    setSurface(tester, size);
    await tester.pumpProofread(
      child,
      translateCubit: translateCubit,
      proofreadCubit: cubit,
      theme: theme,
    );
  }

  /// The spans of the result text.
  List<TextSpan> spans(WidgetTester tester, {String key = 'proofread_diff'}) {
    final finder = find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byWidgetPredicate(
        (widget) => widget is RichText || widget is EditableText,
      ),
    );
    final widget = tester.widget(finder.first);
    final root = widget is RichText
        ? widget.text
        : (widget as EditableText).controller.buildTextSpan(
            context: tester.element(finder.first),
            withComposing: false,
          );
    final result = <TextSpan>[];
    root.visitChildren((span) {
      if (span is TextSpan && span.text != null) result.add(span);
      return true;
    });
    return result;
  }

  /// Taps the span [text] of the result text.
  Future<void> tapSpan(
    WidgetTester tester,
    String text, {
    String key = 'proofread_diff',
  }) async {
    final span = spans(tester, key: key).firstWhere((s) => s.text == text);
    (span.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pump();
  }

  Finder sheet() => find.byKey(const Key('proofread_rephrase_sheet'));

  group('rephrasing a sentence', () {
    testWidgets('splits the result into tappable sentences with a hint', (
      tester,
    ) async {
      await pump(tester);
      expect(spans(tester).map((s) => s.text), [
        'I ',
        'has',
        'have',
        ' an apple.',
        ' ',
        'It is red.',
        ' ',
        'We like it.',
      ]);
      expect(find.byKey(const Key('proofread_rephrase_hint')), findsOneWidget);
      expect(
        find.text('Tap a sentence for other ways to say it.'),
        findsOneWidget,
      );
    });

    testWidgets('shows loading, then the alternatives, and replaces it', (
      tester,
    ) async {
      final clipboard = FakeClipboard()..install(tester);
      final response = Completer<List<String>>();
      stubRephrase(() => response.future);
      await pump(tester);

      await tapSpan(tester, 'It is red.');
      await tester.pump(const Duration(seconds: 1));
      expect(sheet(), findsOneWidget);
      expect(find.text('Rephrase sentence'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('proofread_rephrase_current')),
          matching: find.text('It is red.'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('proofread_rephrase_loading')), findsOne);
      expect(find.text('Finding other ways to say this…'), findsOneWidget);
      expect(find.byKey(const Key('proofread_rephrase_restore')), findsNothing);
      verify(() => repository.rephrase(openAiEngine, _corrected, 'It is red.'))
          .called(1);

      response.complete(['It is crimson.', 'It looks red.']);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('proofread_rephrase_loading')), findsNothing);
      expect(find.text('It is crimson.'), findsOneWidget);
      expect(find.text('It looks red.'), findsOneWidget);
      final tile = tester.getSize(
        find.byKey(const ValueKey('proofread_rephrase_alternative_0')),
      );
      expect(tile.height, greaterThanOrEqualTo(48));

      await tester.tap(find.text('It is crimson.'));
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      expect(
        cubit.state.finalText,
        'I have an apple. It is crimson. We like it.',
      );
      expect(cubit.state.alternatives, isNull);
      final rephrased = spans(tester)
          .singleWhere((s) => s.text == 'It is crimson.');
      expect(rephrased.semanticsLabel, 'rephrased: It is crimson.');
      expect(
        rephrased.style,
        ProofreadDiffColors.of(
          tester.element(find.byKey(const Key('proofread_diff'))),
        ).rephrasedStyle,
      );

      // Copy has the rephrasing.
      await tester.tap(find.byKey(const Key('proofread_copy_corrected')));
      await tester.pump();
      expect(clipboard.copied, 'I have an apple. It is crimson. We like it.');
    });

    testWidgets('a rephrased sentence offers new alternatives and restoring', (
      tester,
    ) async {
      stubRephrase(() async => ['It is scarlet.']);
      cubit.rephraseSentence(const SentenceRange(17, 27), 'It is crimson.');
      await pump(tester);

      await tapSpan(tester, 'It is crimson.');
      await tester.pumpAndSettle();
      verify(
        () => repository.rephrase(
          openAiEngine,
          'I have an apple. It is crimson. We like it.',
          'It is crimson.',
        ),
      ).called(1);
      expect(
        find.descendant(
          of: find.byKey(const Key('proofread_rephrase_current')),
          matching: find.text('It is crimson.'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('proofread_rephrase_restore')));
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      expect(cubit.state.rephrasings, isEmpty);
      expect(cubit.state.finalText, _corrected);
    });

    testWidgets('shows an error with a retry', (tester) async {
      var calls = 0;
      stubRephrase(() async {
        if (calls++ == 0) throw const LlmApiException('Overloaded');
        return ['It is crimson.'];
      });
      await pump(tester);
      await tapSpan(tester, 'It is red.');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('proofread_rephrase_error')), findsOne);
      expect(find.text("Couldn't load alternatives"), findsOneWidget);
      expect(find.textContaining('Overloaded'), findsOneWidget);

      await tester.tap(find.byKey(const Key('proofread_rephrase_retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('proofread_rephrase_error')), findsNothing);
      expect(find.text('It is crimson.'), findsOneWidget);
      expect(calls, 2);
    });

    testWidgets('asks for consent inline', (tester) async {
      stubRephrase(
        () async => throw const ConsentRequiredException(
          kind: ConsentKind.cloudProvider,
          destination: CloudProviderDestination(
            'OpenAI',
            host: 'api.openai.com',
          ),
          engineId: 'ai:openai',
        ),
      );
      await pump(tester);
      await tapSpan(tester, 'It is red.');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('proofread_rephrase_consent')), findsOne);
    });

    testWidgets('says when there are no alternatives, with a retry', (
      tester,
    ) async {
      stubRephrase(() async => const []);
      await pump(tester);
      await tapSpan(tester, 'We like it.');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('proofread_rephrase_empty')), findsOne);
      expect(
        find.text('No other phrasings found. Try again for new ones.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('proofread_rephrase_retry')));
      await tester.pumpAndSettle();
      verify(() => repository.rephrase(openAiEngine, _corrected, 'We like it.'))
          .called(2);
    });

    testWidgets('closing the sheet forgets the alternatives', (tester) async {
      final response = Completer<List<String>>();
      stubRephrase(() => response.future);
      await pump(tester);
      await tapSpan(tester, 'It is red.');
      await tester.pump(const Duration(seconds: 1));
      expect(cubit.state.alternatives, isNotNull);
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      expect(cubit.state.alternatives, isNull);
      response.complete(['late']);
      await tester.pumpAndSettle();
      expect(cubit.state.alternatives, isNull);
    });

    testWidgets('stays open while another sentence is rephrased', (
      tester,
    ) async {
      stubRephrase(() async => ['It is crimson.']);
      await pump(tester);
      await tapSpan(tester, 'It is red.');
      await tester.pumpAndSettle();
      cubit.rephraseSentence(const SentenceRange(28, 39), 'We love it.');
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      expect(find.text('It is crimson.'), findsOneWidget);
    });

    testWidgets('closes when an edit changes the text', (tester) async {
      stubRephrase(() async => ['It is crimson.']);
      await pump(tester);
      await tapSpan(tester, 'It is red.');
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      cubit.toggleEdit(0);
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
    });

    testWidgets('a change keeps opening its edit', (tester) async {
      stubRephrase(() async => const []);
      await pump(tester);
      await tapSpan(tester, 'have');
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Agreement.'),
        ),
        findsOneWidget,
      );
      verifyNever(
        () => repository.rephrase(
          any(),
          any(),
          any(),
          style: any(named: 'style'),
          tone: any(named: 'tone'),
          formality: any(named: 'formality'),
          count: any(named: 'count'),
          uiLanguage: any(named: 'uiLanguage'),
        ),
      );
    });

    testWidgets('a long press opens the sentence under it, also on a change', (
      tester,
    ) async {
      stubRephrase(() async => ['I own an apple.']);
      await pump(tester);
      final text = find.descendant(
        of: find.byKey(const Key('proofread_diff')),
        matching: find.byType(RichText),
      );
      // The start of the paragraph: "I has have an apple."
      await tester.longPressAt(tester.getTopLeft(text) + const Offset(4, 8));
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      verify(
        () => repository.rephrase(openAiEngine, _corrected, 'I have an apple.'),
      ).called(1);
      await tester.tap(find.text('I own an apple.'));
      await tester.pumpAndSettle();
      expect(cubit.state.finalText, 'I own an apple. It is red. We like it.');
    });

    testWidgets('screen readers get a rephrase action per sentence', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      stubRephrase(() async => const []);
      await pump(tester);
      final node = tester.getSemantics(find.byKey(const Key('proofread_diff')));
      final data = node.getSemanticsData();
      final labels = [
        for (final id in data.customSemanticsActionIds ?? const <int>[])
          CustomSemanticsAction.getAction(id)!.label!,
      ];
      expect(labels, [
        'Rephrase: I have an apple.',
        'Rephrase: It is red.',
        'Rephrase: We like it.',
      ]);
      final id = data.customSemanticsActionIds![1];
      node.owner!.performAction(node.id, SemanticsAction.customAction, id);
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      verify(() => repository.rephrase(openAiEngine, _corrected, 'It is red.'))
          .called(1);
      semantics.dispose();
    });

    testWidgets('shortens long sentences in the action labels', (tester) async {
      final semantics = tester.ensureSemantics();
      const long =
          'This sentence is much longer than the preview of an action label.';
      cubit.emit(
        cubit.state.copyWith(
          input: 'this sentence',
          proofreadInput: 'this sentence',
          result: () => const ProofreadResult(correctedText: long),
          acceptedEdits: const {},
        ),
      );
      await pump(tester);
      final data = tester
          .getSemantics(find.byKey(const Key('proofread_diff')))
          .getSemanticsData();
      final label = CustomSemanticsAction.getAction(
        data.customSemanticsActionIds!.single,
      )!.label!;
      expect(label, startsWith('Rephrase: This sentence is much'));
      expect(label, endsWith('…'));
      expect(
        label.length,
        lessThan(
          'Rephrase: '.length + ProofreadOutputText.maxActionPreview + 2,
        ),
      );
      semantics.dispose();
    });

    testWidgets('sentences are tappable in the plain text too', (tester) async {
      stubRephrase(() async => ['It is crimson.']);
      await pump(tester);
      await tester.tap(find.byTooltip('Hide changes'));
      await tester.pump();
      expect(find.byKey(const Key('proofread_output')), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      await tapSpan(tester, 'It is red.', key: 'proofread_output');
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      await tester.tap(find.text('It is crimson.'));
      await tester.pumpAndSettle();
      // Plain text: the rephrasing, without its highlight.
      final rephrased = spans(
        tester,
        key: 'proofread_output',
      ).singleWhere((s) => s.text == 'It is crimson.');
      expect(rephrased.style, isNull);
    });

    testWidgets('works on wide screens, in the dark terminal look', (
      tester,
    ) async {
      stubRephrase(() async => ['It is crimson.']);
      await pump(
        tester,
        size: const Size(1200, 1000),
        theme: buildAppTheme(
          ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.dark,
          ),
          look: AppLook.terminal,
        ),
        child: const ProofreadView(),
      );
      expect(find.byKey(const Key('proofread_wide_layout')), findsOneWidget);
      await tapSpan(tester, 'It is red.');
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('It is crimson.'));
      await tester.pumpAndSettle();
      expect(cubit.state.finalText, contains('It is crimson.'));
    });
  });

  group('a clean result', () {
    const clean = 'It is red. We like it.';

    void emitClean({String summary = ''}) => cubit.emit(
      cubit.state.copyWith(
        input: clean,
        proofreadInput: clean,
        result: () => ProofreadResult(correctedText: clean, summary: summary),
        acceptedEdits: const {},
      ),
    );

    testWidgets('keeps the notice and shows the text as sentences', (
      tester,
    ) async {
      emitClean(summary: 'Clear and concise.');
      await pump(tester);
      expect(find.text('Looks good!'), findsOneWidget);
      // The summary is in the notice only.
      expect(find.text('Clear and concise.'), findsOneWidget);
      final card = find.byKey(const Key('proofread_clean_text'));
      expect(card, findsOneWidget);
      expect(
        tester.getTopLeft(card).dy,
        greaterThan(tester.getTopLeft(find.text('Looks good!')).dy),
      );
      expect(find.text('Your text'), findsOneWidget);
      expect(find.text('Corrected text'), findsNothing);
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.byKey(const Key('proofread_suggestion_count')), findsNothing);
      expect(find.byKey(const Key('proofread_rephrase_hint')), findsOneWidget);
      expect(spans(tester).map((s) => s.text), [
        'It is red.',
        ' ',
        'We like it.',
      ]);
    });

    testWidgets('rephrases, restores and copies the text', (tester) async {
      final clipboard = FakeClipboard()..install(tester);
      stubRephrase(() async => ['We love it.']);
      emitClean();
      await pump(tester);

      await tapSpan(tester, 'We like it.');
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      verify(() => repository.rephrase(openAiEngine, clean, 'We like it.'))
          .called(1);
      await tester.tap(find.text('We love it.'));
      await tester.pumpAndSettle();
      expect(cubit.state.finalText, 'It is red. We love it.');
      // Still clean: the notice stays.
      expect(find.text('Looks good!'), findsOneWidget);

      await tester.tap(find.byKey(const Key('proofread_copy_corrected')));
      await tester.pump();
      expect(clipboard.copied, 'It is red. We love it.');

      await tapSpan(tester, 'We love it.');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('proofread_rephrase_restore')));
      await tester.pumpAndSettle();
      expect(cubit.state.finalText, clean);

      cubit.rephraseSentence(const SentenceRange(0, 10), 'It is crimson.');
      await tester.tap(find.text('Use as input'));
      await tester.pump();
      expect(cubit.state.input, 'It is crimson. We like it.');
      expect(cubit.state.result, isNull);
    });

    testWidgets('works in the terminal look', (tester) async {
      emitClean();
      await pump(
        tester,
        theme: buildAppTheme(
          ColorScheme.fromSeed(seedColor: Colors.teal),
          look: AppLook.terminal,
        ),
      );
      expect(find.byKey(const Key('proofread_clean_text')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('real taps', () {
    testWidgets('a tap on a sentence of the diff opens it', (tester) async {
      stubRephrase(() async => const []);
      await pump(tester);
      await tester.tapOnText(find.textRange.ofSubstring('It is red.'));
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      verify(() => repository.rephrase(openAiEngine, _corrected, 'It is red.'))
          .called(1);
    });

    testWidgets('a tap on a sentence of the plain text opens it', (
      tester,
    ) async {
      stubRephrase(() async => const []);
      await pump(tester);
      await tester.tap(find.byTooltip('Hide changes'));
      await tester.pump();
      final editable = tester.renderObject<RenderEditable>(
        find.descendant(
          of: find.byKey(const Key('proofread_output')),
          matching: find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_Editable',
          ),
        ),
      );
      final start = _corrected.indexOf('We like it.');
      final box = editable
          .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 4),
          )
          .first;
      await tester.tapAt(editable.localToGlobal(box.toRect().center));
      await tester.pumpAndSettle();
      expect(sheet(), findsOneWidget);
      verify(() => repository.rephrase(openAiEngine, _corrected, 'We like it.'))
          .called(1);
    });
  });

  group('showProofreadRephraseSheet', () {
    testWidgets('ignores invalid sentences', (tester) async {
      await pump(tester);
      final context = tester.element(find.byType(ProofreadResultSection));
      await showProofreadRephraseSheet(context, 9);
      await showProofreadRephraseSheet(context, -1);
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
    });
  });
}
