import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';
import 'output_stubs.dart';

const _offline = TranslationEngine(
  id: 'offline:bergamot',
  kind: EngineKind.offline,
  name: 'On this device',
  isLocal: true,
);

const _plain = TranslationResult(
  engineId: 'ai:claude',
  engineName: 'Claude',
  text: 'Bonjour le monde',
);

const _formalResult = TranslationResult(
  engineId: 'ai:claude',
  engineName: 'Claude',
  text: 'Bonjour à tout le monde',
);

final RefinementSuggestion _formal = RefinementSuggestion.defaults[0];

TranslateState _ai({TranslationResult result = _plain}) => translatedState(
  engine: claude,
  input: 'Hello to the world',
  result: result,
);

TranslateState _refined() => _ai(result: _formalResult).copyWith(
  appliedRefinements: [
    AppliedRefinement(suggestion: _formal, previous: _plain),
  ],
);

/// "Guten Tag. Böser Hund." on the device, its second sentence unsure.
const _unsureText = 'Guten Tag. Böser Hund.';
TranslateState _unsure({List<TranslationEngine>? engines}) {
  const result = TranslationResult(
    engineId: 'offline:bergamot',
    engineName: 'On this device',
    text: _unsureText,
  );
  return translatedState(
    engine: _offline,
    input: 'Good day. Bad dog.',
    result: result,
  ).copyWith(
    engines: engines ?? const [_offline, deepl],
    target: german,
    uncertainSentences: const [
      AlignedSpan(
        sourceStart: 10,
        sourceEnd: 18,
        targetStart: 11,
        targetEnd: 22,
      ),
    ],
    uncertainResult: () => result,
  );
}

Future<StreamController<TranslateState>> _listen(
  TranslateHarness harness,
  TranslateState initial,
) async {
  final states = StreamController<TranslateState>();
  addTearDown(states.close);
  whenListen(harness.translate, states.stream, initialState: initial);
  return states;
}

/// The spans of the translation that have [test] true.
List<TextSpan> _spans(WidgetTester tester, bool Function(TextSpan) test) {
  final text = tester.widget<SelectableText>(
    find.byKey(const Key('translate_output_text')),
  );
  final spans = <TextSpan>[];
  text.textSpan!.visitChildren((span) {
    if (span is TextSpan && span.text != null && test(span)) spans.add(span);
    return true;
  });
  return spans;
}

void main() {
  setUpAll(registerOutputFallbacks);

  group('refinement chips', () {
    testWidgets('are in view under the actions of an AI translation', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _ai());
      await harness.pump(tester, child: const OutputCard());
      expect(
        find.byKey(const Key('translate_refinement_chips')),
        findsOneWidget,
      );
      expect(
        tester
            .getTopLeft(find.byKey(const Key('translate_refinement_chips')))
            .dy,
        greaterThan(
          tester
              .getTopLeft(find.byKey(const Key('translate_output_actions')))
              .dy,
        ),
      );
      await tester.tap(find.text('More formal'));
      verify(() => harness.translate.applySuggestion(_formal)).called(1);
    });

    testWidgets('wait (faded) while the translation is not finished', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _ai().copyWith(status: TranslateStatus.translating),
      );
      await harness.pump(tester, child: const OutputCard());
      final refinements = find.byKey(const Key('translate_output_refinements'));
      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .descendant(
                    of: refinements,
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        isTrue,
      );
    });

    testWidgets('are not offered for machine translation', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(assistEngine: claude),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.byKey(const Key('translate_refinement_chips')), findsNothing);
    });
  });

  group('refinement feedback', () {
    testWidgets('tags the header with each refinement; × undoes it', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _refined());
      await harness.pump(tester, child: const OutputCard());
      final tag = find.byKey(const ValueKey('translate_refinement_tag:0'));
      expect(tag, findsOneWidget);
      expect(
        find.descendant(of: tag, matching: find.text('More formal')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('translate_output_header')),
          matching: tag,
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Undo “More formal”').first);
      verify(() => harness.translate.applySuggestion(_formal)).called(1);
    });

    testWidgets('no tag while the translation is out of date', (tester) async {
      final harness = TranslateHarness(
        state: _refined().copyWith(
          input: 'Hello there',
          resultInput: () => 'Hello to the world',
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(
        find.byKey(const ValueKey('translate_refinement_tag:0')),
        findsNothing,
      );
    });

    testWidgets('lights up the changed words, then fades them out', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _ai());
      final states = await _listen(harness, _ai());
      await harness.pump(tester, child: const OutputCard());
      states.add(_refined());
      await tester.pump();
      await tester.pump();
      List<TextSpan> lit() =>
          _spans(tester, (span) => span.style?.backgroundColor != null);
      final changed = lit();
      expect([for (final span in changed) span.text], ['à tout']);
      final start = changed.single.style!.backgroundColor!.a;
      expect(start, greaterThan(0.5));
      await tester.pump(const Duration(milliseconds: 1200));
      expect(lit().single.style!.backgroundColor!.a, lessThan(start));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(lit(), isEmpty);
      // The plain text again.
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('translate_output_text')),
            )
            .textSpan
            ?.toPlainText(),
        'Bonjour à tout le monde',
      );
    });

    testWidgets('holds the highlight without a fade with reduced motion', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _ai());
      final states = await _listen(harness, _ai());
      await harness.pump(
        tester,
        child: const OutputCard(),
        disableAnimations: true,
      );
      states.add(_refined());
      await tester.pump();
      await tester.pump();
      List<TextSpan> lit() =>
          _spans(tester, (span) => span.style?.backgroundColor != null);
      final start = lit().single.style!.backgroundColor!.a;
      await tester.pump(const Duration(milliseconds: 1400));
      expect(lit().single.style!.backgroundColor!.a, start);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(lit(), isEmpty);
    });

    testWidgets('undoing a refinement shows what came back', (tester) async {
      final harness = TranslateHarness(state: _refined());
      final states = await _listen(harness, _refined());
      await harness.pump(tester, child: const OutputCard());
      states.add(_ai());
      await tester.pump();
      await tester.pump();
      // Only removals: nothing new to light up, and no error.
      expect(
        _spans(tester, (span) => span.style?.backgroundColor != null),
        isEmpty,
      );
      await tester.pump(OutputCard.refinementFlash);
    });

    testWidgets('scrolls the translation into view', (tester) async {
      final harness = TranslateHarness(state: _ai());
      final states = await _listen(harness, _ai());
      await harness.pump(
        tester,
        size: const Size(400, 500),
        child: Column(
          children: [
            const SizedBox(height: 600),
            const OutputCard(),
            Container(height: 1200, color: Colors.transparent),
          ],
        ),
      );
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      // The user scrolled down to the chips: the text is above the screen.
      scrollable.position.jumpTo(1000);
      await tester.pump();
      expect(
        tester.getTopLeft(find.byKey(const Key('translate_output_card'))).dy,
        lessThan(0),
      );
      states.add(_refined());
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.getTopLeft(find.byKey(const Key('translate_output_card'))).dy,
        greaterThanOrEqualTo(0),
      );
      await tester.pump(OutputCard.refinementFlash);
    });
  });

  group('sentences the on-device engine is unsure about', () {
    testWidgets('are underlined with dots and counted in a note', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _unsure());
      await harness.pump(tester, child: const OutputCard());
      final unsure = _spans(
        tester,
        (span) => span.style?.decorationStyle == TextDecorationStyle.dotted,
      );
      expect([for (final span in unsure) span.text], ['Böser Hund.']);
      expect(unsure.single.mouseCursor, SystemMouseCursors.help);
      expect(
        find.text(
          'The on-device engine is unsure about 1 sentence (dotted underline)',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a tap on one says why', (tester) async {
      final harness = TranslateHarness(state: _unsure());
      await harness.pump(tester, child: const OutputCard());
      final unsure = _spans(
        tester,
        (span) => span.style?.decorationStyle == TextDecorationStyle.dotted,
      ).single;
      (unsure.recognizer! as TapGestureRecognizer).onTap!();
      await tester.pump();
      expect(
        find.text('The on-device engine is unsure about this sentence'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('hovering one says why', (tester) async {
      final harness = TranslateHarness(state: _unsure());
      await harness.pump(tester, child: const OutputCard());
      final unsure = _spans(
        tester,
        (span) => span.style?.decorationStyle == TextDecorationStyle.dotted,
      ).single;
      unsure.onEnter!(const PointerEnterEvent());
      await tester.pump();
      expect(
        find.text('The on-device engine is unsure about this sentence'),
        findsOneWidget,
      );
      unsure.onExit!(const PointerExitEvent());
      await tester.pumpAndSettle();
      expect(
        find.text('The on-device engine is unsure about this sentence'),
        findsNothing,
      );
    });

    testWidgets('"Compare with another engine" compares at once', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _unsure());
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.text('Compare with another engine'));
      verify(() => harness.translate.setCompareMode(enabled: true)).called(1);
      verify(harness.translate.runCompare).called(1);
    });

    testWidgets('no compare without another engine', (tester) async {
      final harness = TranslateHarness(
        state: _unsure(engines: const [_offline]),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('Compare with another engine'), findsNothing);
      expect(find.byKey(const Key('translate_uncertain_note')), findsOneWidget);
    });

    testWidgets('are gone once the text is edited', (tester) async {
      final harness = TranslateHarness(
        state: _unsure().copyWith(
          input: 'Good day. Bad cat.',
          resultInput: () => 'Good day. Bad dog.',
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.byKey(const Key('translate_uncertain_note')), findsNothing);
    });
  });

  group('screen readers on the web', () {
    testWidgets('read the translation as the value of its container', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard(webSemantics: true));
      final node = tester.getSemantics(
        find.byKey(const Key('translate_output_semantics')),
      );
      expect(node.label, 'Translation');
      expect(node.value, 'Bonjour le monde');
      expect(node.flagsCollection.isReadOnly, isTrue);
      expect(
        node.attributedValue.attributes.single,
        isA<LocaleStringAttribute>(),
      );
      // The selectable text is not a second (empty) field.
      expect(
        find.descendant(
          of: find.byKey(const Key('translate_output_semantics')),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
      );
      handle.dispose();
    });

    testWidgets('elsewhere the selectable text is read', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      final node = tester.getSemantics(
        find.byKey(const Key('translate_output_semantics')),
      );
      expect(node.label, 'Translation');
      expect(node.value, isEmpty);
      handle.dispose();
    });
  });

  group('still layout', () {
    testWidgets('detection alternatives come under the actions', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: translatedState(
          input: 'Hello',
          result: const TranslationResult(
            engineId: 'mozhi:deepl',
            engineName: 'DeepL',
            text: 'Bonjour',
            detectedSource: 'en',
            detectionUncertain: true,
            detectedAlternatives: ['de'],
          ),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      final alternative = find.byKey(
        const ValueKey('translate_detected_alternative:de'),
      );
      expect(alternative, findsOneWidget);
      expect(
        tester.getTopLeft(alternative).dy,
        greaterThan(
          tester
              .getTopLeft(find.byKey(const Key('translate_output_actions')))
              .dy,
        ),
      );
    });

    testWidgets('the on-device badge shows with the first text', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState(
          engine: _offline,
          input: 'Hello world',
          status: TranslateStatus.translating,
          result: const TranslationResult(
            engineId: 'offline:bergamot',
            engineName: 'On this device',
            text: 'Hallo',
            isComplete: false,
          ),
        ),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.byKey(const Key('translate_output_badges')), findsOneWidget);
    });

    testWidgets('a short input shows the engine data under the actions', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: translatedState(
          input: 'hello',
          result: const TranslationResult(
            engineId: 'mozhi:google',
            engineName: 'Google',
            text: 'bonjour',
            targetSynonyms: ['salut'],
          ),
        ),
      );
      stubOutputExtras(harness);
      await harness.pump(tester, child: const OutputCard());
      expect(find.byKey(const Key('translate_short_query')), findsOneWidget);
      expect(find.text('salut', findRichText: true), findsOneWidget);
    });
  });

  group('copyToClipboard', () {
    testWidgets('confirms with a snack bar for buttons without a check', (
      tester,
    ) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => copyToClipboard(context, 'Hallo'),
            child: const Text('Copy it'),
          ),
        ),
      );
      await tester.tap(find.text('Copy it'));
      await tester.pump();
      expect(clipboard.copied, 'Hallo');
      expect(find.text('Copied to clipboard'), findsOneWidget);
    });

    testWidgets('no snack bar on the web after an inline confirmation', (
      tester,
    ) async {
      debugSnackBarAfterInlineCopy = false;
      addTearDown(() => debugSnackBarAfterInlineCopy = null);
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness();
      late bool shown;
      await harness.pump(
        tester,
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () async => shown = await copyAndConfirm(
              context,
              'Hallo',
              inlineConfirmation: true,
            ),
            child: const Text('Copy it'),
          ),
        ),
      );
      await tester.tap(find.text('Copy it'));
      await tester.pump();
      expect(clipboard.copied, 'Hallo');
      expect(shown, isFalse);
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
