import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';
import 'output_stubs.dart';

const _aiResult = TranslationResult(
  engineId: 'ai:claude',
  engineName: 'Claude',
  text: 'Bonjour le monde',
);

const _formalResult = TranslationResult(
  engineId: 'ai:claude',
  engineName: 'Claude',
  text: 'Bonjour à tous',
);

final RefinementSuggestion _formal = RefinementSuggestion.defaults[0];
final RefinementSuggestion _casual = RefinementSuggestion.defaults[1];
final RefinementSuggestion _shorter = RefinementSuggestion.defaults[2];
final RefinementSuggestion _simpler = RefinementSuggestion.defaults[3];

TranslateState _aiState({TranslationEngine engine = claude}) =>
    translatedState(engine: engine, result: _aiResult);

/// "More formal" applied (and optionally [more] after it).
TranslateState _applied({List<RefinementSuggestion> more = const []}) =>
    _aiState().copyWith(
      result: () => _formalResult,
      appliedRefinements: [
        AppliedRefinement(suggestion: _formal, previous: _aiResult),
        for (final suggestion in more)
          AppliedRefinement(suggestion: suggestion, previous: _formalResult),
      ],
    );

Finder _chip(RefinementSuggestion suggestion) => find.ancestor(
  of: find.text(suggestion.label),
  matching: find.byWidgetPredicate((w) => w is FilterChip || w is ActionChip),
);

FilterChip _filterChip(WidgetTester tester, RefinementSuggestion suggestion) =>
    tester.widget<FilterChip>(
      find.ancestor(
        of: find.text(suggestion.label),
        matching: find.byType(FilterChip),
      ),
    );

void main() {
  setUpAll(registerOutputFallbacks);

  group('refinementLabel', () {
    testWidgets('translates built-in chips', (tester) async {
      final harness = TranslateHarness();
      late List<String> labels;
      await harness.pump(
        tester,
        child: Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context);
            labels = [
              for (final suggestion in RefinementSuggestion.defaults)
                refinementLabel(l10n, suggestion),
            ];
            return const SizedBox();
          },
        ),
      );
      expect(labels, [
        'More formal',
        'More casual',
        'Shorter',
        'Simpler',
        'More fluent',
        'More literal',
      ]);
    });

    testWidgets('keeps fetched labels', (tester) async {
      final harness = TranslateHarness();
      late String fetched;
      late String unknownIcon;
      await harness.pump(
        tester,
        child: Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context);
            fetched = refinementLabel(
              l10n,
              const RefinementSuggestion(
                label: 'Warmer',
                instruction: 'Make it warmer.',
                icon: 'formal',
              ),
            );
            unknownIcon = refinementLabel(
              l10n,
              const RefinementSuggestion(label: 'Odd', instruction: 'x'),
            );
            return const SizedBox();
          },
        ),
      );
      expect(fetched, 'Warmer');
      expect(unknownIcon, 'Odd');
    });

    test('maps icon hints to icons', () {
      expect(refinementIcon('formal'), Icons.work_outline);
      expect(refinementIcon('casual'), Icons.emoji_emotions_outlined);
      expect(refinementIcon('shorter'), Icons.compress);
      expect(refinementIcon('longer'), Icons.notes);
      expect(refinementIcon('simplify'), Icons.auto_fix_high_outlined);
      expect(refinementIcon('fluent'), Icons.record_voice_over_outlined);
      expect(refinementIcon('literal'), Icons.format_quote_outlined);
      expect(refinementIcon('tune'), Icons.tune);
    });
  });

  group('RefinementChips', () {
    testWidgets('are filter chips when they revise the output', (tester) async {
      final harness = TranslateHarness(state: _aiState());
      await harness.pump(tester, child: RefinementChips(state: _aiState()));
      expect(find.byType(FilterChip), findsNWidgets(6));
      expect(_filterChip(tester, _formal).selected, isFalse);
      await tester.tap(find.text('More formal'));
      verify(() => harness.translate.applySuggestion(_formal)).called(1);
    });

    testWidgets('are one-off action chips for translation-only models', (
      tester,
    ) async {
      final state = _aiState(engine: translateGemma)
          .copyWith(assistEngine: () => claude);
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: RefinementChips(state: state));
      expect(find.byType(FilterChip), findsNothing);
      expect(
        find.byKey(const ValueKey('translate_refinement_chip:0')),
        findsOneWidget,
      );
      await tester.tap(find.text('Shorter'));
      verify(() => harness.translate.applySuggestion(_shorter)).called(1);
    });

    testWidgets('fetched descriptions become tooltips of action chips', (
      tester,
    ) async {
      final state = _aiState(engine: translateGemma).copyWith(
        assistEngine: () => claude,
        suggestions: const [
          RefinementSuggestion(
            label: 'Warmer',
            instruction: 'Make it warmer.',
            description: 'Friendlier tone',
          ),
        ],
      );
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: RefinementChips(state: state));
      expect(find.byTooltip('Friendlier tone'), findsOneWidget);
    });

    testWidgets('an applied chip is selected with a check mark', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final state = _applied();
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: RefinementChips(state: state));
      final chip = _filterChip(tester, _formal);
      expect(chip.selected, isTrue);
      expect(chip.showCheckmark, isNot(isFalse));
      // The check mark replaces the icon.
      expect(chip.avatar, isNull);
      expect(_filterChip(tester, _simpler).selected, isFalse);
      expect(
        tester.getSemantics(_chip(_formal).first),
        isSemantics(
          isSelected: true,
          isButton: true,
          hasTapAction: true,
          tooltip: 'Undo “More formal”',
        ),
      );
      expect(
        tester.getSemantics(_chip(_simpler).first),
        isSemantics(isSelected: false, isButton: true, hasTapAction: true),
      );
      handle.dispose();
    });

    testWidgets('tapping an applied chip undoes it', (tester) async {
      final state = _applied();
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: RefinementChips(state: state));
      expect(find.byTooltip('Undo “More formal”'), findsOneWidget);
      await tester.tap(find.text('More formal'));
      verify(() => harness.translate.applySuggestion(_formal)).called(1);
    });

    testWidgets('chips of an exclusive group say which chip they replace', (
      tester,
    ) async {
      final state = _applied(more: [_shorter]);
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: RefinementChips(state: state));
      // Only one chip of a group is selected.
      expect(_filterChip(tester, _formal).selected, isTrue);
      expect(_filterChip(tester, _casual).selected, isFalse);
      expect(_filterChip(tester, _shorter).selected, isTrue);
      expect(find.byTooltip('Replaces “More formal”'), findsOneWidget);
      // Chips without a group just stack.
      expect(find.byTooltip('Replaces “Shorter”'), findsNothing);
      await tester.tap(find.text('More casual'));
      verify(() => harness.translate.applySuggestion(_casual)).called(1);
    });

    testWidgets('chips stay selectable while a refinement stacks', (
      tester,
    ) async {
      // Applied chips keep the filter chips even when the output is no
      // longer revisable (e.g. the input is being edited).
      final state = _applied().copyWith(status: TranslateStatus.translating);
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: RefinementChips(state: state));
      expect(find.byType(FilterChip), findsNWidgets(6));
    });

    testWidgets('the chip in flight shows a spinner and cancels on tap', (
      tester,
    ) async {
      final state = _aiState().copyWith(pendingRefinement: () => _shorter);
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: RefinementChips(state: state));
      final chip = _filterChip(tester, _shorter);
      expect(chip.selected, isFalse);
      expect(
        find.descendant(
          of: _chip(_shorter),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Cancel “Shorter”'), findsOneWidget);
      await tester.tap(find.text('Shorter'));
      verify(() => harness.translate.applySuggestion(_shorter)).called(1);
    });

    testWidgets('keep the fetched descriptions as tooltips', (tester) async {
      final state = _aiState().copyWith(
        suggestionsStatus: ExtraStatus.ready,
        suggestions: const [
          RefinementSuggestion(
            label: 'Warmer',
            instruction: 'Make it warmer.',
            description: 'Friendlier tone',
          ),
        ],
      );
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: RefinementChips(state: state));
      expect(find.byTooltip('Friendlier tone'), findsOneWidget);
      expect(find.byKey(const Key('translate_more_suggestions')), findsNothing);
    });

    testWidgets('"More suggestions" shows progress while loading', (
      tester,
    ) async {
      final state = _aiState().copyWith(suggestionsStatus: ExtraStatus.loading);
      final harness = TranslateHarness(state: state);
      await harness.pump(tester, child: RefinementChips(state: state));
      final more = tester.widget<ActionChip>(
        find.byKey(const Key('translate_more_suggestions')),
      );
      expect(more.onPressed, isNull);
      expect(
        find.descendant(
          of: find.byKey(const Key('translate_more_suggestions')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
    });

    testWidgets('work in dark mode and right to left', (tester) async {
      final state = _applied();
      final harness = TranslateHarness(state: state);
      await harness.pump(
        tester,
        child: RefinementChips(state: state),
        themeMode: ThemeMode.dark,
        locale: const Locale('ar'),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(FilterChip), findsNWidgets(6));
    });
  });

  group('ExtrasSection', () {
    testWidgets('shows a snack bar when a refinement fails', (tester) async {
      final initial = _aiState();
      final harness = TranslateHarness(state: initial);
      whenListen(
        harness.translate,
        Stream.fromIterable([
          initial.copyWith(pendingRefinement: () => _formal),
          initial.copyWith(
            pendingRefinement: () => null,
            refinementError: () => const LlmApiException('x', statusCode: 429),
          ),
        ]),
        initialState: initial,
      );
      await harness.pump(tester, child: const ExtrasSection());
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('translate_refinement_error')),
        findsOneWidget,
      );
      expect(
        find.textContaining("Couldn't refine the translation."),
        findsOneWidget,
      );
      expect(find.textContaining('Too many requests'), findsOneWidget);
    });
  });
}
