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

const _options = TranslationOptions(
  style: TranslationStyle.literal,
  formality: Formality.more,
  readingLevel: ReadingLevel.b1,
  speakerGender: Gender.feminine,
  addresseeGender: Gender.masculine,
  context: 'A text message to my landlord about the heating',
  preserveFormatting: false,
  glossary: {'cat': 'chat', 'dog': 'chien'},
);

void main() {
  setUpAll(registerTranslateFallbacks);

  group('activeTranslationOptions', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('is empty for the defaults', () {
      expect(
        activeTranslationOptions(l10n, const TranslationOptions()),
        isEmpty,
      );
    });

    test('lists every non-default option and how to clear it', () {
      final active = activeTranslationOptions(l10n, _options);
      expect(active.map((o) => o.label), [
        'Literal',
        'More formal',
        'Reading level B1',
        'Speaker: Feminine',
        'Addressee: Masculine',
        'Context: A text message to my lan…',
        'Formatting not kept',
        'Glossary · 2 terms',
      ]);
      expect(active[2].tooltip, 'B1 · Intermediate');
      expect(active[5].tooltip, _options.context);
      expect(active[7].tooltip, 'cat → chat\ndog → chien');
      expect(active[0].cleared.style, TranslationStyle.natural);
      expect(active[1].cleared.formality, Formality.automatic);
      expect(active[2].cleared.readingLevel, ReadingLevel.standard);
      expect(active[3].cleared.speakerGender, Gender.unknown);
      expect(active[4].cleared.addresseeGender, Gender.unknown);
      expect(active[5].cleared.context, '');
      expect(active[6].cleared.preserveFormatting, isTrue);
      expect(active[7].cleared.glossary, isEmpty);
      // Clearing one option keeps the others.
      expect(active[5].cleared.formality, Formality.more);
    });

    test('keeps a short context whole', () {
      final active = activeTranslationOptions(
        l10n,
        const TranslationOptions(context: '  Landlord '),
      );
      expect(active.single.label, 'Context: Landlord');
    });
  });

  group('ActiveOptionsBar', () {
    testWidgets('is hidden for default options', (tester) async {
      final harness = TranslateHarness(state: translatedState(engine: claude));
      await harness.pump(tester, child: const ActiveOptionsBar());
      expect(find.byType(InputChip), findsNothing);
    });

    testWidgets('is hidden for engines without options', (tester) async {
      final harness = TranslateHarness(
        state: translatedState().copyWith(options: _options),
      );
      await harness.pump(tester, child: const ActiveOptionsBar());
      expect(find.byType(InputChip), findsNothing);
    });

    testWidgets('shows a chip per active option, grouped and named', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final harness = TranslateHarness(
        state: translatedState(engine: claude).copyWith(options: _options),
      );
      await harness.pump(tester, child: const ActiveOptionsBar());
      expect(find.byType(InputChip), findsNWidgets(8));
      expect(find.text('More formal'), findsOneWidget);
      expect(find.text('Glossary · 2 terms'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Active translation options'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('deleting a chip clears only that option', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(engine: claude).copyWith(
          options: const TranslationOptions(
            formality: Formality.more,
            context: 'landlord',
          ),
        ),
      );
      await harness.pump(tester, child: const ActiveOptionsBar());
      await tester.tap(find.byTooltip('Remove Context: landlord'));
      verify(
        () => harness.translate.setOptions(
          const TranslationOptions(formality: Formality.more),
        ),
      ).called(1);
    });

    testWidgets('reset clears every option at once', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(engine: claude).copyWith(options: _options),
      );
      await harness.pump(tester, child: const ActiveOptionsBar());
      await tester.tap(find.byKey(const Key('translate_active_options_reset')));
      verify(() => harness.translate.setOptions(const TranslationOptions()))
          .called(1);
    });

    testWidgets('follows option and engine changes', (tester) async {
      final initial = translatedState(engine: claude);
      final harness = TranslateHarness(state: initial);
      final controller = StreamController<TranslateState>();
      addTearDown(controller.close);
      whenListen(harness.translate, controller.stream, initialState: initial);
      await harness.pump(tester, child: const ActiveOptionsBar());
      expect(find.byType(InputChip), findsNothing);

      final formal = initial.copyWith(
        options: const TranslationOptions(formality: Formality.more),
      );
      controller.add(formal);
      await tester.pump();
      expect(find.text('More formal'), findsOneWidget);

      controller.add(formal.copyWith(engine: () => deepl));
      await tester.pump();
      expect(find.byType(InputChip), findsNothing);
    });

    testWidgets('tapping a chip opens the options sheet', (tester) async {
      final harness = TranslateHarness(
        state: translatedState(engine: claude).copyWith(
          options: const TranslationOptions(formality: Formality.more),
        ),
      );
      await harness.pump(tester, child: const ActiveOptionsBar());
      await tester.tap(find.text('More formal'));
      await tester.pumpAndSettle();
      expect(find.byType(TranslationOptionsSheet), findsOneWidget);
    });

    testWidgets('appears under the language bar on the translate screen', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: translatedState(engine: claude)
            .copyWith(options: const TranslationOptions(context: 'landlord')),
      );
      await harness.pump(tester, size: const Size(400, 900));
      final bar = tester.getRect(find.byType(LanguageBar));
      final chip = tester.getRect(find.byType(InputChip));
      final input = tester.getRect(find.byType(InputCard));
      expect(chip.top, greaterThanOrEqualTo(bar.bottom));
      expect(input.top, greaterThan(chip.bottom));
    });
  });
}
