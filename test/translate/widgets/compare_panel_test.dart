import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
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

/// Placeholders of engines still running.
final Finder _pending = find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('compare_pending:'),
);

const _deeplEntry = CompareEntry.success(
  TranslationResult(
    engineId: 'mozhi:deepl',
    engineName: 'DeepL',
    text: 'Bonjour  tout le monde ',
  ),
);

const _ollamaEntry = CompareEntry.success(
  TranslationResult(
    engineId: 'ai:ollama',
    engineName: 'Ollama',
    text: 'Salut tout le monde',
  ),
);

const _claudeEntry = CompareEntry.success(
  TranslationResult(
    engineId: 'ai:claude',
    engineName: 'Claude',
    text: 'Bonjour tout le monde',
  ),
);

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
      // 4 engines, 1 finished: the others in their places, named.
      expect(_pending, findsNWidgets(3));
      expect(find.text('DeepL'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('DeepL')).dy,
        lessThan(tester.getTopLeft(find.text('Google')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Google')).dy,
        lessThan(tester.getTopLeft(find.text('Claude')).dy),
      );
      // While it runs there is nothing to start.
      expect(find.byKey(const Key('translate_compare_button')), findsNothing);
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
      expect(_pending, findsNWidgets(2));
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
      expect(_pending, findsNWidgets(2));
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

    group('agreement and differences', () {
      testWidgets('merges engines that agree into one card', (tester) async {
        final harness = TranslateHarness(
          state: _compareState(
            entries: const [_deeplEntry, _googleEntry, _claudeEntry],
          ),
        );
        await harness.pump(tester, child: const ComparePanel());
        expect(find.byType(CompareEntryCard), findsOneWidget);
        expect(find.text('DeepL, Google and Claude agree'), findsOneWidget);
        // No time for several engines.
        expect(find.text('1.2 s'), findsNothing);
        await tester.tap(find.text('Use this'));
        verify(() => harness.translate.useCompareEntry(_deeplEntry)).called(1);
      });

      testWidgets('marks the current translation and highlights changes', (
        tester,
      ) async {
        final harness = TranslateHarness(
          state: _compareState(
            entries: const [_googleEntry, _deeplEntry, _ollamaEntry],
          ).copyWith(compareBaseline: () => _googleEntry.result),
        );
        await harness.pump(tester, child: const ComparePanel());
        expect(find.byType(CompareEntryCard), findsNWidgets(2));
        expect(find.text('Google and DeepL agree'), findsOneWidget);
        expect(find.text('Current translation'), findsOneWidget);
        expect(
          find.text('Highlighted words differ from the current translation.'),
          findsOneWidget,
        );
        // The current translation first, then the others by engine.
        expect(
          tester.getTopLeft(find.text('Google and DeepL agree')).dy,
          lessThan(tester.getTopLeft(find.text('Ollama')).dy),
        );
        final ollama = tester.widget<SelectableText>(
          find.descendant(
            of: find.byKey(const ValueKey('compare:ai:ollama')),
            matching: find.byType(SelectableText),
          ),
        );
        final spans = ollama.textSpan!.children!.cast<TextSpan>();
        expect(spans.map((span) => span.text).join(), 'Salut tout le monde');
        final highlighted = [
          for (final span in spans)
            if (span.style?.backgroundColor != null) span.text,
        ];
        expect(highlighted, ['Salut']);
        // "Use this" on the current translation's card keeps it.
        await tester.tap(find.text('Use this').first);
        verify(() => harness.translate.useCompareEntry(_googleEntry)).called(1);
      });

      testWidgets('no hint while every engine agrees', (tester) async {
        final harness = TranslateHarness(
          state: _compareState(entries: const [_googleEntry, _claudeEntry])
              .copyWith(compareBaseline: () => _googleEntry.result),
        );
        await harness.pump(tester, child: const ComparePanel());
        expect(find.textContaining('Highlighted words'), findsNothing);
      });

      testWidgets('long texts are not compared word by word', (tester) async {
        final long = 'mot ' * 1300;
        final harness = TranslateHarness(
          state: _compareState(
            entries: [
              _googleEntry,
              CompareEntry.success(
                TranslationResult(
                  engineId: 'ai:claude',
                  engineName: 'Claude',
                  text: long,
                ),
              ),
            ],
          ).copyWith(compareBaseline: () => _googleEntry.result),
        );
        await harness.pump(tester, child: const ComparePanel());
        final text = tester.widget<SelectableText>(
          find.descendant(
            of: find.byKey(const ValueKey('compare:ai:claude')),
            matching: find.byType(SelectableText),
          ),
        );
        expect(text.textSpan!.children, hasLength(1));
      });

      testWidgets('cards of engines outside the run come last', (tester) async {
        const other = CompareEntry.success(
          TranslationResult(
            engineId: 'mozhi:other',
            engineName: 'Other',
            text: 'Autre',
          ),
        );
        final harness = TranslateHarness(
          state: _compareState(entries: const [other, _ollamaEntry]),
        );
        await harness.pump(tester, child: const ComparePanel());
        expect(
          tester.getTopLeft(find.text('Ollama')).dy,
          lessThan(tester.getTopLeft(find.text('Other')).dy),
        );
      });

      test('compareCardTitle names one, two or more engines', () {
        final l10n = lookupAppLocalizations(const Locale('en'));
        expect(compareCardTitle(l10n, const []), '');
        expect(compareCardTitle(l10n, const ['A']), 'A');
        expect(compareCardTitle(l10n, const ['A', 'B']), 'A and B agree');
        expect(
          compareCardTitle(l10n, const ['A', 'B', 'C', 'D']),
          'A, B, C and D agree',
        );
      });
    });

    testWidgets('"Done" is the one way out', (tester) async {
      final harness = TranslateHarness(
        state: _compareState(entries: const [_googleEntry]),
      );
      await harness.pump(tester, child: const ComparePanel());
      expect(find.byKey(const Key('translate_compare_toggle')), findsOneWidget);
      expect(find.byTooltip('Exit compare mode'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
      await tester.tap(find.text('Done'));
      verify(() => harness.translate.setCompareMode(enabled: false)).called(1);
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
