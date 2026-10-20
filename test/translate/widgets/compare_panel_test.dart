import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

const _googleEntry = CompareEntry.success(
  TranslationResult(
    engineId: 'mozhi:google',
    engineName: 'Google',
    text: 'Bonjour tout le monde',
    elapsed: Duration(milliseconds: 1240),
  ),
);

const _claudeFailure = CompareEntry.failure(
  engineId: 'ai:claude',
  engineName: 'Claude',
  error: LlmApiException('rate', statusCode: 429),
);

TranslateState _compareState({
  List<CompareEntry> entries = const [],
  bool comparing = false,
  String input = 'Hello world',
}) => readyState(input: input)
    .copyWith(compareMode: true, compareEntries: entries, comparing: comparing);

void main() {
  setUpAll(registerTranslateFallbacks);

  group('ComparePanel', () {
    testWidgets('shows a hint before comparing', (tester) async {
      final harness = TranslateHarness(state: _compareState());
      await harness.pump(tester, child: const ComparePanel());
      expect(find.text('Compare engines'), findsOneWidget);
      expect(
        find.text(
          'Translate with every engine side by side and pick the best result.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Compare runs the comparison', (tester) async {
      final harness = TranslateHarness(state: _compareState());
      await harness.pump(tester, child: const ComparePanel());
      await tester.tap(find.byKey(const Key('translate_compare_button')));
      verify(harness.translate.runCompare).called(1);
    });

    testWidgets('Compare is disabled without input', (tester) async {
      final harness = TranslateHarness(state: _compareState(input: ' '));
      await harness.pump(tester, child: const ComparePanel());
      final button = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('translate_compare_button')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('shows a card per result and placeholders for the rest', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _compareState(entries: const [_googleEntry], comparing: true),
      );
      await harness.pump(tester, child: const ComparePanel());
      expect(find.byType(CompareEntryCard), findsOneWidget);
      expect(find.text('Google'), findsOneWidget);
      expect(find.text('1.2 s'), findsOneWidget);
      expect(find.text('Bonjour tout le monde'), findsOneWidget);
      // 4 engines, 1 finished.
      expect(find.byType(SkeletonCard), findsNWidgets(3));
      final button = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('translate_compare_button')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('placeholders respect the configured compare engines', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _compareState(comparing: true),
        settings: const AppSettings(
          compareEngineIds: ['mozhi:deepl', 'ai:claude'],
        ),
      );
      await harness.pump(tester, child: const ComparePanel());
      expect(find.byType(SkeletonCard), findsNWidgets(2));
    });

    testWidgets('placeholders only count engines for custom languages', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _compareState(comparing: true)
            .copyWith(target: const Language.custom('Pirate')),
      );
      await harness.pump(tester, child: const ComparePanel());
      // Claude and Ollama.
      expect(find.byType(SkeletonCard), findsNWidgets(2));
    });

    testWidgets('cards of a custom target follow their text', (tester) async {
      final harness = TranslateHarness(
        state: _compareState(entries: const [_googleEntry])
            .copyWith(target: const Language.custom('Pirate')),
      );
      await harness.pump(tester, child: const ComparePanel());
      final text = tester.widget<SelectableText>(
        find.descendant(
          of: find.byType(CompareEntryCard),
          matching: find.byType(SelectableText),
        ),
      );
      expect(text.textDirection, TextDirection.ltr);
    });

    testWidgets('Compare is enabled once there is input', (tester) async {
      final initial = _compareState(input: '');
      final harness = TranslateHarness(state: initial);
      whenListen(
        harness.translate,
        Stream.value(initial.copyWith(input: 'Hello')),
        initialState: initial,
      );
      await harness.pump(tester, child: const ComparePanel());
      await tester.pump();
      final button = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('translate_compare_button')),
      );
      expect(button.onPressed, isNotNull);
    });

    test('compareEngineCount picks engines like the cubit', () {
      final state = _compareState();
      expect(compareEngineCount(state, const []), 4);
      expect(compareEngineCount(state, const ['mozhi:deepl']), 1);
      // None of the configured engines is available: all of them.
      expect(compareEngineCount(state, const ['gone']), 4);
      expect(
        compareEngineCount(
          state.copyWith(source: const Language.custom('Klingon')),
          const ['mozhi:deepl', 'ai:claude'],
        ),
        1,
      );
    });

    testWidgets('failures show a readable error', (tester) async {
      final harness = TranslateHarness(
        state: _compareState(entries: const [_googleEntry, _claudeFailure]),
      );
      await harness.pump(tester, child: const ComparePanel());
      expect(find.text('Claude'), findsOneWidget);
      expect(find.textContaining('Too many requests'), findsOneWidget);
      // Only the successful entry can be used or copied.
      expect(find.text('Use this'), findsOneWidget);
      expect(find.byTooltip('Copy'), findsOneWidget);
    });

    testWidgets('an undetectable source language offers the source picker', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _compareState(
          entries: const [
            _googleEntry,
            CompareEntry.failure(
              engineId: 'offline:bergamot',
              engineName: 'On this device',
              error: SourceLanguageRequiredException(
                engineId: 'offline:bergamot',
              ),
            ),
          ],
        ),
      );
      await harness.pump(tester, child: const ComparePanel());
      expect(find.textContaining("can't detect the language"), findsOneWidget);
      expect(find.text('Something went wrong. Try again.'), findsNothing);
      await tester.tap(find.text('Choose language'));
      await tester.pumpAndSettle();
      expect(find.byType(LanguagePickerSheet), findsOneWidget);
      await tester.tap(
        find
            .descendant(
              of: find.byType(LanguagePickerSheet),
              matching: find.text('German'),
            )
            .last,
      );
      await tester.pumpAndSettle();
      verify(() => harness.translate.setSource(german)).called(1);
    });

    testWidgets('"Use this" selects the entry', (tester) async {
      final harness = TranslateHarness(
        state: _compareState(entries: const [_googleEntry]),
      );
      await harness.pump(tester, child: const ComparePanel());
      await tester.tap(find.text('Use this'));
      verify(() => harness.translate.useCompareEntry(_googleEntry)).called(1);
    });

    testWidgets('copy copies the entry text', (tester) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(
        state: _compareState(entries: const [_googleEntry]),
      );
      await harness.pump(tester, child: const ComparePanel());
      await tester.tap(find.byTooltip('Copy'));
      await tester.pump();
      expect(clipboard.copied, 'Bonjour tout le monde');
    });
  });
}
