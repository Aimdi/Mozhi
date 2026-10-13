import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/helpers.dart';

TranslateState _state([
  TranslationOptions options = const TranslationOptions(),
]) => readyState(engine: claude).copyWith(options: options);

Future<TranslateHarness> _open(
  WidgetTester tester, [
  TranslationOptions options = const TranslationOptions(),
]) async {
  final harness = TranslateHarness(state: _state(options));
  await harness.pump(
    tester,
    child: const OptionsButton(),
    size: const Size(800, 2000),
  );
  await tester.tap(find.byKey(const Key('translate_options_button')));
  await tester.pumpAndSettle();
  return harness;
}

TranslationOptions _captured(TranslateHarness harness) =>
    verify(() => harness.translate.setOptions(captureAny())).captured.last
        as TranslationOptions;

void main() {
  setUpAll(registerTranslateFallbacks);

  group('OptionsButton', () {
    testWidgets('is hidden for Mozhi engines', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const OptionsButton());
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('has no badge with default options', (tester) async {
      final harness = TranslateHarness(state: _state());
      await harness.pump(tester, child: const OptionsButton());
      final badge = tester.widget<Badge>(find.byType(Badge));
      expect(badge.isLabelVisible, isFalse);
    });
  });

  group('TranslationOptionsSheet', () {
    testWidgets('opens with all sections', (tester) async {
      await _open(tester);
      expect(find.text('Translation options'), findsWidgets);
      for (final label in [
        'Style',
        'Formality',
        'Reading level',
        'Speaker gender',
        'Addressee gender',
        'Context',
        'Preserve formatting',
        'Glossary',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('style segment sets literal', (tester) async {
      final harness = await _open(tester);
      await tester.tap(find.text('Literal'));
      expect(_captured(harness).style, TranslationStyle.literal);
    });

    testWidgets('formality chips set formality', (tester) async {
      final harness = await _open(tester);
      await tester.tap(find.text('Prefer informal'));
      expect(_captured(harness).formality, Formality.preferLess);
    });

    testWidgets('reading level dropdown sets the level', (tester) async {
      final harness = await _open(tester);
      await tester.tap(
        find.byKey(const Key('translate_options_reading_level')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('B1 · Intermediate').last);
      await tester.pumpAndSettle();
      expect(_captured(harness).readingLevel, ReadingLevel.b1);
    });

    testWidgets('gender chips set speaker and addressee', (tester) async {
      final harness = await _open(tester);
      await tester.tap(find.text('Feminine').first);
      expect(_captured(harness).speakerGender, Gender.feminine);
      await tester.tap(find.text('Masculine').last);
      expect(_captured(harness).addresseeGender, Gender.masculine);
    });

    testWidgets('context is applied after a pause', (tester) async {
      final harness = await _open(tester);
      await tester.enterText(
        find.byKey(const Key('translate_options_context')),
        'A note to my landlord',
      );
      verifyNever(() => harness.translate.setOptions(any()));
      await tester.pump(const Duration(seconds: 1));
      expect(_captured(harness).context, 'A note to my landlord');
    });

    testWidgets('context is applied when the sheet closes', (tester) async {
      final harness = await _open(tester);
      await tester.enterText(
        find.byKey(const Key('translate_options_context')),
        'Medical leaflet',
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(_captured(harness).context, 'Medical leaflet');
    });

    testWidgets('preserve formatting switch toggles', (tester) async {
      final harness = await _open(tester);
      await tester.tap(find.byKey(const Key('translate_options_formatting')));
      expect(_captured(harness).preserveFormatting, isFalse);
    });

    testWidgets('glossary terms can be added', (tester) async {
      final harness = await _open(tester);
      await tester.enterText(
        find.byKey(const Key('translate_glossary_source')),
        'cloud',
      );
      await tester.enterText(
        find.byKey(const Key('translate_glossary_target')),
        'nuage',
      );
      await tester.tap(find.byKey(const Key('translate_glossary_add')));
      expect(_captured(harness).glossary, {'cloud': 'nuage'});
    });

    testWidgets('incomplete glossary terms are ignored', (tester) async {
      final harness = await _open(tester);
      await tester.enterText(
        find.byKey(const Key('translate_glossary_source')),
        'cloud',
      );
      await tester.tap(find.byKey(const Key('translate_glossary_add')));
      verifyNever(() => harness.translate.setOptions(any()));
    });

    testWidgets('glossary terms can be removed', (tester) async {
      final harness = await _open(
        tester,
        const TranslationOptions(glossary: {'cloud': 'nuage', 'app': 'appli'}),
      );
      expect(find.text('cloud → nuage'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove cloud'));
      expect(_captured(harness).glossary, {'app': 'appli'});
    });

    testWidgets('reset restores the defaults', (tester) async {
      final harness = await _open(
        tester,
        const TranslationOptions(
          formality: Formality.more,
          readingLevel: ReadingLevel.a2,
        ),
      );
      await tester.tap(find.byKey(const Key('translate_options_reset')));
      final options = _captured(harness);
      expect(options.formality, Formality.automatic);
      expect(options.readingLevel, ReadingLevel.standard);
    });

    testWidgets('reset is disabled with default options', (tester) async {
      await _open(tester);
      final reset = tester.widget<TextButton>(
        find.byKey(const Key('translate_options_reset')),
      );
      expect(reset.onPressed, isNull);
    });
  });

  group('optionsAreDefault', () {
    test('ignores one-off instructions', () {
      expect(optionsAreDefault(const TranslationOptions()), isTrue);
      expect(
        optionsAreDefault(const TranslationOptions(instructions: 'Shorter')),
        isTrue,
      );
      expect(
        optionsAreDefault(const TranslationOptions(context: 'email')),
        isFalse,
      );
      expect(
        optionsAreDefault(const TranslationOptions(glossary: {'a': 'b'})),
        isFalse,
      );
    });
  });
}
