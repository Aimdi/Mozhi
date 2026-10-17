import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

/// Keys of everything the "More" area holds.
const _moreKeys = [
  'translate_meaning_button',
  'translate_insights_button',
  'translate_alignment_button',
  'translate_compare_toggle',
  'translate_refine_and_learn',
  'translate_extra_targets_button',
  'translate_word_choices',
];

/// A Google (Mozhi) result with word choices, translated with Claude as
/// the assist engine: every tool of the "More" area applies.
const _result = TranslationResult(
  engineId: 'mozhi:google',
  engineName: 'Google',
  text: 'Bonjour le monde',
  detectedSource: 'en',
  wordChoices: [WordChoice(word: 'monde', definition: 'world')],
);

TranslateState _translated() =>
    translatedState(engine: google, assistEngine: claude, result: _result);

Finder _key(String key) => find.byKey(Key(key));

void main() {
  setUpAll(registerTranslateFallbacks);

  group('the More area', () {
    testWidgets('is closed at first: languages, input and translation only', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: _translated());
      await harness.pump(tester, size: const Size(400, 1200));
      expect(find.byType(LanguageBar), findsOneWidget);
      expect(find.byType(InputCard), findsOneWidget);
      expect(find.text('Bonjour le monde'), findsOneWidget);
      for (final key in _moreKeys) {
        expect(_key(key), findsNothing, reason: key);
      }
      expect(
        tester.getSemantics(_key('translate_more_toggle')),
        isSemantics(
          label: 'More',
          isButton: true,
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
        ),
      );
      expect(findTooltipMessage('Show more tools'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('opens with every tool, and closes again', (tester) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(state: _translated());
      await harness.pump(tester, size: const Size(400, 1600));
      await openMore(tester);
      for (final key in _moreKeys) {
        expect(_key(key), findsOneWidget, reason: key);
      }
      expect(
        tester.getSemantics(_key('translate_more_toggle')),
        isSemantics(
          label: 'More',
          isButton: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
        ),
      );
      expect(findTooltipMessage('Hide more tools'), findsOneWidget);

      await tester.tap(_key('translate_more_toggle'));
      await tester.pumpAndSettle();
      for (final key in _moreKeys) {
        expect(_key(key), findsNothing, reason: key);
      }
      handle.dispose();
    });

    testWidgets('is two taps from any tool', (tester) async {
      final harness = TranslateHarness(state: _translated());
      await harness.pump(tester, size: const Size(400, 1600));
      await openMore(tester);
      await tester.tap(_key('translate_insights_button'));
      await tester.pump();
      verify(harness.translate.loadInsights).called(1);
    });

    testWidgets('stays open across layouts', (tester) async {
      final harness = TranslateHarness(state: _translated());
      await harness.pump(tester, size: const Size(400, 1600));
      await openMore(tester);
      tester.view.physicalSize = const Size(1200, 1600);
      await tester.pumpAndSettle();
      expect(_key('translate_wide_layout'), findsOneWidget);
      expect(_key('translate_meaning_button'), findsOneWidget);
      expect(_key('translate_refine_and_learn'), findsOneWidget);
    });

    testWidgets('has no toggle before there is a translation', (tester) async {
      final harness = TranslateHarness(state: readyState(input: 'Hello'));
      await harness.pump(tester);
      expect(_key('translate_more_toggle'), findsNothing);
      expect(_key('translate_extra_targets_button'), findsNothing);
      expect(_key('translate_empty_output'), findsOneWidget);
    });

    testWidgets('shows nothing of itself in the empty state when left open', (
      tester,
    ) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final harness = TranslateHarness(state: _translated());
      whenListen(harness.translate, states.stream, initialState: _translated());
      await harness.pump(tester, size: const Size(400, 1600));
      await openMore(tester);
      states.add(readyState());
      await tester.pumpAndSettle();
      expect(_key('translate_extra_targets_button'), findsNothing);
      expect(_key('translate_refine_and_learn'), findsNothing);
    });

    testWidgets('keeps the translations into extra languages visible', (
      tester,
    ) async {
      final state = _translated().copyWith(
        extraTargets: const [german],
        extraTranslations: const [
          ExtraTranslation(
            target: german,
            status: TranslateStatus.success,
            result: TranslationResult(
              engineId: 'mozhi:google',
              engineName: 'Google',
              text: 'Hallo Welt',
            ),
            request: TranslationRequest(
              text: 'Hello world',
              source: Language.auto,
              target: german,
            ),
          ),
        ],
      );
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, size: const Size(400, 1600));
      expect(find.byType(ExtraTargetCard), findsOneWidget);
      expect(find.text('Hallo Welt'), findsOneWidget);
      // Choosing the languages is in the More area.
      expect(_key('translate_extra_targets_button'), findsNothing);
      await openMore(tester);
      expect(_key('translate_extra_targets_button'), findsOneWidget);
    });

    testWidgets('a shown meaning check stays when the area closes', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _translated().copyWith(meaningStatus: ExtraStatus.loading),
      );
      await harness.pump(tester, size: const Size(400, 1600));
      expect(find.byType(MeaningCheckPanel), findsOneWidget);
      expect(_key('translate_meaning_panel_progress'), findsWidgets);
    });
  });

  group('TranslateMoreHost', () {
    testWidgets('remembers the choice for the session', (tester) async {
      var shown = true;
      late StateSetter setOuter;
      TranslateMoreController? controller;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          home: StatefulBuilder(
            builder: (context, setState) {
              setOuter = setState;
              return shown
                  ? TranslateMoreHost(
                      child: Builder(
                        builder: (context) {
                          controller = TranslateMoreScope.maybeOf(context);
                          return const SizedBox();
                        },
                      ),
                    )
                  : const SizedBox();
            },
          ),
        ),
      );
      expect(controller!.expanded, isFalse);
      controller!.toggle();
      setOuter(() => shown = false);
      await tester.pump();
      setOuter(() => shown = true);
      await tester.pump();
      expect(controller!.expanded, isTrue);
      controller!.expanded = false;
      setOuter(() => shown = false);
      await tester.pump();
      setOuter(() => shown = true);
      await tester.pump();
      expect(controller!.expanded, isFalse);
    });
  });

  group('TranslateMoreToggle', () {
    testWidgets('turns its chevron, unless motion is reduced', (tester) async {
      final controller = TranslateMoreController();
      addTearDown(controller.dispose);
      final harness = TranslateHarness();
      await harness.pump(
        tester,
        child: TranslateMoreToggle(controller: controller),
      );
      await tester.tap(_key('translate_more_toggle'));
      await tester.pump();
      expect(controller.expanded, isTrue);
      final rotation = tester.widget<AnimatedRotation>(
        find.byType(AnimatedRotation),
      );
      expect(rotation.turns, 0.5);
      expect(rotation.duration, const Duration(milliseconds: 200));

      await harness.pump(
        tester,
        child: TranslateMoreToggle(controller: controller),
        disableAnimations: true,
      );
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).duration,
        Duration.zero,
      );
    });
  });

  group('compare', () {
    testWidgets('the compare panel has a close button', (tester) async {
      final harness = TranslateHarness(
        state: readyState(input: 'Hi').copyWith(compareMode: true),
      );
      await harness.pump(tester, child: const ComparePanel());
      expect(find.byTooltip('Exit compare mode'), findsOneWidget);
      await tester.tap(_key('translate_compare_toggle'));
      verify(() => harness.translate.setCompareMode(enabled: false)).called(1);
    });
  });
}
