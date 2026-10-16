import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';
import 'output_stubs.dart';

const _arabic = Language(code: 'ar', name: 'Arabic', nativeName: 'العربية');

const _omission = MeaningIssue(
  problem: 'The word "world" is missing.',
  type: MeaningIssueType.omission,
  sourceSpan: 'world',
  sourceStart: 6,
  sourceEnd: 11,
);

const _mistranslation = MeaningIssue(
  problem: '"Bonjour" is a greeting, not "hello" in general.',
  type: MeaningIssueType.mistranslation,
  sourceSpan: 'Hello',
  translationSpan: 'Bonjour',
  suggestion: 'Salut',
  sourceStart: 0,
  sourceEnd: 5,
  translationStart: 0,
  translationEnd: 7,
);

const _check = MeaningCheck(
  verdict: MeaningVerdict.minor,
  backTranslation: 'Hello the world',
  issues: [_mistranslation, _omission],
);

/// "Hello world" -> "Bonjour le monde" on DeepL with Claude for extras.
TranslateState _translated({TranslationEngine? assistEngine = claude}) =>
    translatedState(assistEngine: assistEngine);

TranslateState _checked({MeaningCheck check = _check, int? focus}) =>
    _translated().copyWith(
      meaningStatus: ExtraStatus.ready,
      meaningCheck: () => check,
      meaningFocus: () => focus,
    );

TranslateHarness _harness(TranslateState state) {
  final harness = TranslateHarness(state: state);
  stubOutputExtras(harness);
  when(
    () => harness.translate.checkMeaning(uiLanguage: any(named: 'uiLanguage')),
  ).thenAnswer((_) async {});
  return harness;
}

Finder _issue(int index) =>
    find.byKey(ValueKey('translate_meaning_issue_$index'));

/// The tappable part of difference [index].
Finder _tile(int index) =>
    find.descendant(of: _issue(index), matching: find.byType(InkWell));

void main() {
  setUpAll(registerOutputFallbacks);

  group('MeaningCheckPanel', () {
    testWidgets('is hidden until a check is requested', (tester) async {
      await _harness(_translated())
          .pump(tester, child: const MeaningCheckPanel());
      expect(find.byKey(const Key('translate_meaning_panel')), findsNothing);
    });

    testWidgets('shows progress while checking', (tester) async {
      await _harness(_translated().copyWith(meaningStatus: ExtraStatus.loading))
          .pump(tester, child: const MeaningCheckPanel());
      expect(find.text('Meaning check'), findsOneWidget);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('translate_meaning_progress')),
      );
      expect(progress.semanticsLabel, 'Checking meaning…');
    });

    testWidgets('is a back-translation without an AI engine', (tester) async {
      await _harness(
        _translated(assistEngine: null)
            .copyWith(meaningStatus: ExtraStatus.loading),
      ).pump(tester, child: const MeaningCheckPanel());
      expect(find.text('Back-translation'), findsOneWidget);
    });

    testWidgets('shows failures with Retry in the UI language', (tester) async {
      final harness = _harness(
        _translated().copyWith(
          meaningStatus: ExtraStatus.failure,
          meaningError: () => Exception('bad json'),
        ),
      );
      await harness.pump(
        tester,
        child: const MeaningCheckPanel(),
        locale: const Locale('de'),
      );
      expect(find.byKey(const Key('translate_meaning_error')), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('translate_meaning_error')),
          matching: find.bySubtype<FilledButton>(),
        ),
      );
      verify(() => harness.translate.checkMeaning(uiLanguage: 'German'))
          .called(1);
    });

    testWidgets('shows the verdict, back-translation and differences', (
      tester,
    ) async {
      await _harness(_checked()).pump(tester, child: const MeaningCheckPanel());
      final verdict = find.byKey(const Key('translate_meaning_verdict'));
      expect(
        find.descendant(of: verdict, matching: find.text('Minor differences')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: verdict, matching: find.byIcon(Icons.info_outline)),
        findsOneWidget,
      );
      expect(find.text('Hello the world'), findsOneWidget);
      expect(find.text('Differences'), findsOneWidget);
      expect(find.text('Mistranslation'), findsOneWidget);
      expect(find.text('Omission'), findsOneWidget);
      expect(find.text(_mistranslation.problem), findsOneWidget);
      expect(find.textContaining('In your text: '), findsNWidgets(2));
      expect(find.textContaining('In the translation: '), findsOneWidget);
      expect(find.textContaining('Suggested wording: '), findsOneWidget);
      expect(find.textContaining('Salut'), findsOneWidget);
      expect(find.byKey(const Key('translate_meaning_partial')), findsNothing);
    });

    testWidgets('reads spans and suggestions in their languages', (
      tester,
    ) async {
      await _harness(_checked()).pump(tester, child: const MeaningCheckPanel());
      final rich = find
          .descendant(of: _issue(0), matching: find.byType(RichText))
          .evaluate()
          .map((element) => element.widget as RichText)
          .firstWhere(
            (text) => text.text.toPlainText().startsWith('Suggested wording'),
          );
      final spans = <TextSpan>[];
      rich.text.visitChildren((span) {
        if (span is TextSpan && (span.text?.contains('Salut') ?? false)) {
          spans.add(span);
        }
        return true;
      });
      expect(spans.single.locale, const Locale('fr'));
      expect(spans.single.text, '\u2068Salut\u2069');
      final back = tester.widget<SelectableText>(
        find.byKey(const Key('translate_meaning_back_translation')),
      );
      expect(back.textSpan?.locale, const Locale('en'));
      expect(back.textDirection, TextDirection.ltr);
    });

    testWidgets(
      'a right-to-left source gets a right-to-left back-translation',
      (tester) async {
        await _harness(_checked().copyWith(source: _arabic))
            .pump(tester, child: const MeaningCheckPanel());
        final back = tester.widget<SelectableText>(
          find.byKey(const Key('translate_meaning_back_translation')),
        );
        expect(back.textSpan?.locale, const Locale('ar'));
        expect(back.textDirection, TextDirection.rtl);
      },
    );

    testWidgets('says when the meaning is the same', (tester) async {
      await _harness(
        _checked(check: const MeaningCheck(verdict: MeaningVerdict.same)),
      ).pump(tester, child: const MeaningCheckPanel());
      expect(find.text('Same meaning'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(
        find.byKey(const Key('translate_meaning_no_issues')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('translate_meaning_back_translation')),
        findsNothing,
      );
    });

    testWidgets(
      'says differences could not be located instead of "no differences"',
      (tester) async {
        for (final verdict in [MeaningVerdict.minor, MeaningVerdict.major]) {
          await _harness(
            _checked(
              check: MeaningCheck(verdict: verdict, backTranslation: 'Hi'),
            ),
          ).pump(tester, child: const MeaningCheckPanel());
          expect(
            find.byKey(const Key('translate_meaning_issues_unlocated')),
            findsOneWidget,
          );
          expect(
            find.text(
              'The differences could not be pinpointed in the texts. '
              'Compare the back-translation with your text.',
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('translate_meaning_no_issues')),
            findsNothing,
          );
          expect(find.text('No differences in meaning found.'), findsNothing);
        }
      },
    );

    testWidgets('flags a major difference and a partial check', (tester) async {
      await _harness(
        _checked(
          check: const MeaningCheck(
            verdict: MeaningVerdict.major,
            issues: [_omission],
            isPartial: true,
          ),
        ),
      ).pump(tester, child: const MeaningCheckPanel());
      expect(find.text('Meaning differs'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(
        find.byKey(const Key('translate_meaning_partial')),
        findsOneWidget,
      );
    });

    testWidgets('names every kind of difference', (tester) async {
      await _harness(
        _checked(
          check: MeaningCheck(
            verdict: MeaningVerdict.major,
            issues: [
              for (final type in MeaningIssueType.values)
                MeaningIssue(
                  problem: type.name,
                  type: type,
                  sourceSpan: 'Hello',
                  sourceStart: 0,
                  sourceEnd: 5,
                ),
            ],
          ),
        ),
      ).pump(tester, child: const MeaningCheckPanel());
      for (final label in [
        'Omission',
        'Addition',
        'Negation',
        'Number',
        'Tense',
        'Mistranslation',
        'Other difference',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('tapping a difference highlights it, again removes it', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = _harness(_checked(focus: 1));
      await harness.pump(tester, child: const MeaningCheckPanel());
      expect(
        tester.getSemantics(_tile(1)),
        isSemantics(
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
          onTapHint: 'remove the highlight',
        ),
      );
      expect(
        tester.getSemantics(_tile(0)),
        isSemantics(
          isSelected: false,
          hasSelectedState: true,
          hasTapAction: true,
          onTapHint: 'highlight in both texts',
        ),
      );
      await tester.tap(_issue(0));
      verify(() => harness.translate.focusMeaningIssue(0)).called(1);
      await tester.tap(_issue(1));
      verify(() => harness.translate.focusMeaningIssue(null)).called(1);
      handle.dispose();
    });

    testWidgets('says where a one-sided difference is highlighted', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      const added = MeaningIssue(
        problem: '"le" was added.',
        type: MeaningIssueType.addition,
        translationSpan: 'le',
        translationStart: 8,
        translationEnd: 10,
      );
      await _harness(
        _checked(
          check: const MeaningCheck(
            verdict: MeaningVerdict.minor,
            issues: [_omission, added],
          ),
        ),
      ).pump(tester, child: const MeaningCheckPanel());
      expect(
        tester.getSemantics(_tile(0)),
        isSemantics(
          hasSelectedState: true,
          hasTapAction: true,
          onTapHint: 'highlight in your text',
        ),
      );
      expect(
        tester.getSemantics(_tile(1)),
        isSemantics(
          hasSelectedState: true,
          hasTapAction: true,
          onTapHint: 'highlight in the translation',
        ),
      );
      handle.dispose();
    });

    testWidgets('marks the differences that can be highlighted', (
      tester,
    ) async {
      await _harness(
        _checked(
          check: const MeaningCheck(
            verdict: MeaningVerdict.minor,
            issues: [
              _omission,
              MeaningIssue(problem: 'Somewhere'),
            ],
          ),
          focus: 0,
        ),
      ).pump(tester, child: const MeaningCheckPanel());
      Finder icon(int index) => find.descendant(
        of: _issue(index),
        matching: find.byKey(const Key('translate_meaning_issue_highlight')),
      );
      expect(icon(0), findsOneWidget);
      expect(
        find.descendant(
          of: _issue(0),
          matching: find.byIcon(Icons.highlight_off),
        ),
        findsOneWidget,
      );
      expect(icon(1), findsNothing);
      ShapeBorder? shape(int index) => tester
          .widget<Material>(
            find.descendant(of: _issue(index), matching: find.byType(Material)),
          )
          .shape;
      expect(
        (shape(0)! as RoundedRectangleBorder).side.style,
        BorderStyle.solid,
      );
      expect((shape(1)! as RoundedRectangleBorder).side, BorderSide.none);
    });

    testWidgets('a difference without a location cannot be tapped', (
      tester,
    ) async {
      final harness = _harness(
        _checked(
          check: const MeaningCheck(
            verdict: MeaningVerdict.minor,
            issues: [MeaningIssue(problem: 'Somewhere')],
          ),
        ),
      );
      await harness.pump(tester, child: const MeaningCheckPanel());
      await tester.tap(_issue(0));
      verifyNever(() => harness.translate.focusMeaningIssue(any()));
    });

    testWidgets('closes', (tester) async {
      final harness = _harness(_checked());
      await harness.pump(tester, child: const MeaningCheckPanel());
      await tester.tap(find.byKey(const Key('translate_meaning_close')));
      verify(harness.translate.clearMeaningCheck).called(1);
    });

    group('closing hands the focus to "Check meaning"', () {
      /// The focus node of the button found by [key].
      FocusNode focusOf(WidgetTester tester, Key key) => Focus.of(
        tester.element(
          find.descendant(of: find.byKey(key), matching: find.byType(Icon)),
        ),
      );

      testWidgets('from the keyboard', (tester) async {
        final harness = _harness(_checked());
        await harness.pump(tester);
        focusOf(tester, const Key('translate_meaning_close')).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        verify(harness.translate.clearMeaningCheck).called(1);
        expect(
          focusOf(
            tester,
            const Key('translate_meaning_button'),
          ).hasPrimaryFocus,
          isTrue,
        );
      });

      testWidgets('with a screen reader', (tester) async {
        final harness = _harness(_checked());
        await harness.pump(tester);
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(accessibleNavigation: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const Key('translate_meaning_close')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('translate_meaning_close')));
        await tester.pump();
        expect(
          focusOf(
            tester,
            const Key('translate_meaning_button'),
          ).hasPrimaryFocus,
          isTrue,
        );
      });

      testWidgets('but not from a tap elsewhere in focus', (tester) async {
        final harness = _harness(_checked());
        await harness.pump(tester);
        await tester.ensureVisible(
          find.byKey(const Key('translate_meaning_close')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('translate_meaning_close')));
        await tester.pump();
        expect(
          focusOf(tester, const Key('translate_meaning_button')).hasFocus,
          isFalse,
        );
      });
    });

    testWidgets('shows a back-translation with the engine that made it', (
      tester,
    ) async {
      await _harness(
        _translated(assistEngine: null).copyWith(
          meaningStatus: ExtraStatus.ready,
          backTranslation: () => 'Hello the world',
        ),
      ).pump(tester, child: const MeaningCheckPanel());
      expect(find.text('Back-translation'), findsOneWidget);
      expect(find.textContaining('Translated back with'), findsOneWidget);
      expect(find.textContaining('DeepL'), findsOneWidget);
      expect(find.text('Hello the world'), findsOneWidget);
      expect(find.byKey(const Key('translate_meaning_verdict')), findsNothing);
    });

    testWidgets('announces the verdict when it arrives', (tester) async {
      await _harness(
        _checked(),
      ).pump(tester, child: const MeaningCheckPanel(), supportsAnnounce: true);
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Minor differences. 2 differences.'),
      ]);
    });

    testWidgets('announces a back-translation', (tester) async {
      await _harness(
        _translated(assistEngine: null).copyWith(
          meaningStatus: ExtraStatus.ready,
          backTranslation: () => 'Hello',
        ),
      ).pump(tester, child: const MeaningCheckPanel(), supportsAnnounce: true);
      expect(tester.takeAnnouncements(), [
        isAccessibilityAnnouncement('Back-translation ready'),
      ]);
    });

    for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('meets the accessibility guidelines ($themeMode)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await _harness(
          _checked(focus: 0),
        ).pump(tester, child: const MeaningCheckPanel(), themeMode: themeMode);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
      });
    }

    testWidgets('fits at 200 % text on a phone', (tester) async {
      await _harness(_checked()).pump(
        tester,
        child: const MeaningCheckPanel(),
        size: const Size(360, 800),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('translateUiLanguage', () {
    test('is the English name of the UI language', () {
      expect(translateUiLanguage(const Locale('en', 'GB')), 'English');
      expect(translateUiLanguage(const Locale('de')), 'German');
      expect(translateUiLanguage(const Locale('xx')), 'English');
    });
  });

  group('meaning highlights', () {
    test('mark the focused difference in both texts', () {
      final state = _checked(focus: 0);
      expect(outputMeaningHighlight(state), const TextRange(start: 0, end: 7));
      expect(
        inputMeaningHighlight(state, 'Hello world'),
        const TextRange(start: 0, end: 5),
      );
    });

    test('mark only the side a difference is in', () {
      final state = _checked(focus: 1);
      expect(outputMeaningHighlight(state), isNull);
      expect(
        inputMeaningHighlight(state, 'Hello world'),
        const TextRange(start: 6, end: 11),
      );
    });

    test('need a current check of the shown texts', () {
      for (final state in [
        _checked(),
        _checked(focus: 0)
            .copyWith(input: 'Hello', resultInput: () => 'Hello world'),
        _checked(focus: 0).copyWith(meaningStatus: ExtraStatus.loading),
        _checked(focus: 0).copyWith(result: () => null),
        _checked(focus: 0).copyWith(
          result: () => const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Bonjour le monde',
            isComplete: false,
          ),
        ),
        _checked(focus: 0).copyWith(
          result: () => const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Bon',
          ),
        ),
      ]) {
        expect(outputMeaningHighlight(state), isNull, reason: '$state');
      }
      expect(inputMeaningHighlight(_checked(focus: 0), 'Hello'), isNull);
      expect(inputMeaningHighlight(_checked(), 'Hello world'), isNull);
      expect(
        inputMeaningHighlight(_checked(focus: 0).copyWith(input: 'Hi'), 'Hi'),
        isNull,
      );
    });
  });

  group('OutputCard meaning check', () {
    testWidgets('"Check meaning" starts a check in the UI language', (
      tester,
    ) async {
      final harness = _harness(_translated());
      await harness.pump(
        tester,
        child: const OutputCard(),
        locale: const Locale('de'),
      );
      await tester.tap(find.byKey(const Key('translate_meaning_button')));
      verify(() => harness.translate.checkMeaning(uiLanguage: 'German'))
          .called(1);
    });

    testWidgets('is offered for engines without AI extras too', (tester) async {
      final harness = _harness(_translated(assistEngine: null));
      await harness.pump(tester, child: const OutputCard());
      expect(find.byKey(const Key('translate_meaning_button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('translate_meaning_button')));
      expect(
        verify(
          () => harness.translate.checkMeaning(
            uiLanguage: captureAny(named: 'uiLanguage'),
          ),
        ).captured,
        ['English'],
      );
    });

    testWidgets('is disabled for an out-of-date translation', (tester) async {
      final harness = _harness(
        _translated().copyWith(
          input: 'Hello there',
          resultInput: () => 'Hello world',
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      final button = tester.widget<TranslateToolChip>(
        find.byKey(const Key('translate_meaning_button')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('hides a shown check', (tester) async {
      final harness = _harness(_checked());
      await harness.pump(tester, child: const OutputCard());
      expect(find.byTooltip('Hide meaning check'), findsOneWidget);
      await tester.tap(find.byKey(const Key('translate_meaning_button')));
      verify(harness.translate.clearMeaningCheck).called(1);
      verifyNever(
        () => harness.translate.checkMeaning(
          uiLanguage: any(named: 'uiLanguage'),
        ),
      );
    });

    testWidgets('highlights the focused difference over the alignment', (
      tester,
    ) async {
      final harness = _harness(
        _checked(focus: 0).copyWith(
          alignmentStatus: ExtraStatus.ready,
          alignment: const [
            AlignedSpan(
              sourceStart: 0,
              sourceEnd: 5,
              targetStart: 0,
              targetEnd: 7,
            ),
          ],
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      final text = tester.widget<SelectableText>(
        find.byKey(const Key('translate_output_text')),
      );
      final span = text.textSpan!;
      expect(span.locale, const Locale('fr'));
      expect(span.toPlainText(), 'Bonjour le monde');
      final highlighted = span.children!.first as TextSpan;
      expect(highlighted.text, 'Bonjour');
      final scheme = Theme.of(
        tester.element(find.byKey(const Key('translate_output_text'))),
      ).colorScheme;
      expect(highlighted.style, AlignedText.focusStyle(scheme));
      expect((span.children![1] as TextSpan).text, ' le monde');
    });

    testWidgets('highlights a difference in the middle of the output', (
      tester,
    ) async {
      final harness = _harness(
        _checked(
          focus: 0,
          check: const MeaningCheck(
            verdict: MeaningVerdict.minor,
            issues: [
              MeaningIssue(
                problem: 'p',
                translationSpan: 'le',
                translationStart: 8,
                translationEnd: 10,
              ),
            ],
          ),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      final span = tester
          .widget<SelectableText>(
            find.byKey(const Key('translate_output_text')),
          )
          .textSpan!;
      expect(
        [for (final child in span.children!) (child as TextSpan).text],
        ['Bonjour ', 'le', ' monde'],
      );
    });
  });

  group('OutputCard meaning highlight', () {
    testWidgets('keeps "Alternatives" for a selection', (tester) async {
      final harness = _harness(_checked(focus: 0));
      await harness.pump(tester, child: const OutputCard());
      final editable = tester.state<EditableTextState>(
        find.descendant(
          of: find.byKey(const Key('translate_output_text')),
          matching: find.byType(EditableText),
        ),
      );
      editable.userUpdateTextEditingValue(
        editable.textEditingValue.copyWith(
          selection: const TextSelection(baseOffset: 11, extentOffset: 16),
        ),
        SelectionChangedCause.longPress,
      );
      await tester.pump();
      expect(editable.showToolbar(), isTrue);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alternatives'));
      verify(
        () => harness.translate.loadAlternatives(span: 'monde', spanStart: 11),
      ).called(1);
    });
  });

  group('MeaningCheckPanel updates', () {
    testWidgets('follow the result, the engine and the status', (tester) async {
      final harness = _harness(_checked());
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(
        harness.translate,
        controller.stream,
        initialState: _checked(),
      );
      await harness.pump(tester, child: const MeaningCheckPanel());
      expect(find.byKey(const Key('translate_meaning_verdict')), findsOne);
      controller.add(_checked().copyWith(engine: () => google));
      await tester.pump();
      await tester.pump();
      controller.add(
        _checked().copyWith(
          engine: () => google,
          result: () => const TranslationResult(
            engineId: 'mozhi:google',
            engineName: 'Google',
            text: 'Bonjour le monde',
            detectedSource: 'ja',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final back = tester.widget<SelectableText>(
        find.byKey(const Key('translate_meaning_back_translation')),
      );
      expect(back.textSpan?.locale, const Locale('ja'));
      controller.add(_translated());
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('translate_meaning_panel')), findsNothing);
    });
  });

  group('InputCard meaning check', () {
    testWidgets('highlights the focused difference in the input', (
      tester,
    ) async {
      final harness = _harness(_checked(focus: 1));
      await harness.pump(tester, child: const InputCard());
      final field = tester.widget<TextField>(
        find.byKey(const Key('translate_input_field')),
      );
      final controller = field.controller! as HighlightTextEditingController;
      expect(controller.highlight, const TextRange(start: 6, end: 11));
    });

    testWidgets('follows the focus', (tester) async {
      final harness = _harness(_checked());
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(
        harness.translate,
        controller.stream,
        initialState: _checked(),
      );
      await harness.pump(tester, child: const InputCard());
      final field = tester.widget<TextField>(
        find.byKey(const Key('translate_input_field')),
      );
      final text = field.controller! as HighlightTextEditingController;
      expect(text.highlight, isNull);
      controller.add(
        _checked(focus: 0).copyWith(meaningStatus: ExtraStatus.loading),
      );
      await tester.pump();
      await tester.pump();
      expect(text.highlight, isNull);
      controller.add(_checked(focus: 0));
      await tester.pump();
      await tester.pump();
      expect(text.highlight, const TextRange(start: 0, end: 5));
      controller.add(_translated());
      await tester.pump();
      await tester.pump();
      expect(text.highlight, isNull);
    });
  });

  group('TranslateView', () {
    testWidgets('shows the meaning check under the translation', (
      tester,
    ) async {
      await _harness(_checked()).pump(tester);
      expect(find.byKey(const Key('translate_meaning_panel')), findsOneWidget);
    });
  });
}
