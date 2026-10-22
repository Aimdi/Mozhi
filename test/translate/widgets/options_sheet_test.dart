import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/presets.dart';
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
  PresetsCubit? presets,
  TranslateState? state,
]) async {
  final harness = TranslateHarness(
    state: state ?? _state(options),
    presets: presets,
  );
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
    testWidgets('is shown for Mozhi engines too', (tester) async {
      final harness = TranslateHarness();
      await harness.pump(tester, child: const OptionsButton());
      expect(find.byType(IconButton), findsOneWidget);
      expect(find.byTooltip('Translation options'), findsOneWidget);
    });

    testWidgets('shows a badge for options kept for an AI translator', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState().copyWith(
          options: const TranslationOptions(style: TranslationStyle.literal),
        ),
      );
      await harness.pump(tester, child: const OptionsButton());
      expect(find.byTooltip('Translation options (modified)'), findsOneWidget);
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isTrue);
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
        'Tone',
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

    testWidgets('tone segments set the formality', (tester) async {
      final harness = await _open(tester);
      final tone = tester.widget<SegmentedButton<Formality>>(
        find.byKey(const Key('translate_options_tone')),
      );
      expect(tone.selected, {Formality.automatic});
      await tester.tap(find.text('Casual'));
      expect(_captured(harness).formality, Formality.less);
      await tester.tap(find.text('Formal'));
      expect(_captured(harness).formality, Formality.more);
    });

    testWidgets('the softer tones are under Advanced', (tester) async {
      final harness = await _open(tester);
      expect(find.text('Prefer informal'), findsNothing);
      await tester.tap(find.byKey(const Key('translate_options_advanced')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prefer informal'));
      expect(_captured(harness).formality, Formality.preferLess);
    });

    testWidgets('a softer tone opens Advanced and selects no segment', (
      tester,
    ) async {
      final harness = await _open(
        tester,
        const TranslationOptions(formality: Formality.preferMore),
      );
      final tone = tester.widget<SegmentedButton<Formality>>(
        find.byKey(const Key('translate_options_tone')),
      );
      expect(tone.selected, isEmpty);
      final chip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text('Prefer formal'),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(chip.selected, isTrue);
      // Choosing it again goes back to Neutral.
      await tester.tap(find.text('Prefer formal'));
      expect(_captured(harness).formality, Formality.automatic);
      // Advanced closes again.
      await tester.tap(find.byKey(const Key('translate_options_advanced')));
      await tester.pumpAndSettle();
      expect(find.text('Prefer formal'), findsNothing);
    });

    testWidgets('options the engine applies carry no reason', (tester) async {
      await _open(tester);
      expect(find.text('AI engines only'), findsNothing);
      expect(find.text('AI engines and DeepL only'), findsNothing);
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

  group('formality notes', () {
    final notes = find.byKey(const Key('translate_options_formality_notes'));

    testWidgets('are hidden while the formality is automatic', (tester) async {
      await _open(tester);
      expect(notes, findsNothing);
      expect(find.text('Formality notes'), findsNothing);
    });

    testWidgets('are shown with a formality and prefilled', (tester) async {
      await _open(
        tester,
        const TranslationOptions(
          formality: Formality.less,
          formalityContext: 'my sister',
        ),
      );
      expect(notes, findsOneWidget);
      expect(find.text('Formality notes'), findsOneWidget);
      final field = tester.widget<TextField>(notes);
      expect(field.controller!.text, 'my sister');
      expect(field.maxLength, TranslationOptionsSheet.formalityNotesMaxLength);
      expect(TranslationOptionsSheet.formalityNotesMaxLength, 2000);
    });

    testWidgets('are applied after a pause', (tester) async {
      final harness = await _open(
        tester,
        const TranslationOptions(formality: Formality.more),
      );
      await tester.enterText(notes, '  My boss, first-name terms ');
      verifyNever(() => harness.translate.setOptions(any()));
      await tester.pump(const Duration(seconds: 1));
      final options = _captured(harness);
      expect(options.formalityContext, 'My boss, first-name terms');
      expect(options.formality, Formality.more);
    });

    testWidgets('are applied when the sheet closes', (tester) async {
      final harness = await _open(
        tester,
        const TranslationOptions(formality: Formality.more),
      );
      await tester.enterText(notes, 'the landlord');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(_captured(harness).formalityContext, 'the landlord');
    });

    testWidgets('are applied when tapping elsewhere', (tester) async {
      final harness = await _open(
        tester,
        const TranslationOptions(formality: Formality.more),
      );
      await tester.enterText(notes, 'a client');
      // The focused field registers its tap region on the next frame.
      await tester.pump();
      await tester.tap(find.text('Reading level').first);
      await tester.pump();
      expect(_captured(harness).formalityContext, 'a client');
    });

    testWidgets('unchanged notes are not applied again', (tester) async {
      final harness = await _open(
        tester,
        const TranslationOptions(
          formality: Formality.more,
          formalityContext: 'boss',
        ),
      );
      await tester.enterText(notes, 'boss ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(seconds: 1));
      verifyNever(() => harness.translate.setOptions(any()));
    });

    testWidgets('reset clears them', (tester) async {
      final harness = await _open(
        tester,
        const TranslationOptions(
          formality: Formality.more,
          formalityContext: 'boss',
        ),
      );
      await tester.enterText(notes, 'boss and friend');
      await tester.tap(find.byKey(const Key('translate_options_reset')));
      expect(tester.widget<TextField>(notes).controller!.text, isEmpty);
      // The pending notes are dropped.
      await tester.pump(const Duration(seconds: 1));
      final options = verify(() => harness.translate.setOptions(captureAny()))
          .captured
          .cast<TranslationOptions>();
      expect(options, [const TranslationOptions()]);
    });
  });

  group('presets', () {
    const work = Preset(
      id: 'work',
      name: 'Work',
      options: TranslationOptions(
        formality: Formality.more,
        context: 'An email to a colleague.',
      ),
    );

    MockPresetsCubit presetsCubit() {
      final cubit = MockPresetsCubit();
      when(() => cubit.state).thenReturn(
        const PresetsState(status: PresetsStatus.ready, presets: [work]),
      );
      return cubit;
    }

    testWidgets('are not offered without a presets cubit', (tester) async {
      await _open(tester);
      expect(find.byKey(const Key('translate_options_presets')), findsNothing);
      expect(find.text('Preset'), findsNothing);
    });

    testWidgets('choosing one sets its options and keeps the glossary', (
      tester,
    ) async {
      final harness = await _open(
        tester,
        const TranslationOptions(glossary: {'cat': 'Katze'}),
        presetsCubit(),
      );
      expect(find.text('Preset'), findsOneWidget);
      expect(
        find.byKey(const Key('translate_options_presets')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('preset_picker_work')));
      await tester.pump();
      final options = _captured(harness);
      expect(options.formality, Formality.more);
      expect(options.context, 'An email to a colleague.');
      expect(options.glossary, {'cat': 'Katze'});
      final context = tester.widget<TextField>(
        find.byKey(const Key('translate_options_context')),
      );
      expect(context.controller!.text, 'An email to a colleague.');
    });

    testWidgets('a preset replaces context that is still being typed', (
      tester,
    ) async {
      final harness = await _open(
        tester,
        const TranslationOptions(),
        presetsCubit(),
      );
      await tester.enterText(
        find.byKey(const Key('translate_options_context')),
        'typing',
      );
      await tester.tap(find.byKey(const Key('preset_picker_work')));
      // The typed context would have been applied after this pause.
      await tester.pump(const Duration(seconds: 1));
      final options = verify(() => harness.translate.setOptions(captureAny()))
          .captured
          .cast<TranslationOptions>();
      expect(options.map((o) => o.context), ['An email to a colleague.']);
    });

    testWidgets('a preset replaces formality notes being typed', (
      tester,
    ) async {
      final harness = await _open(
        tester,
        const TranslationOptions(formality: Formality.less),
        presetsCubit(),
      );
      await tester.enterText(
        find.byKey(const Key('translate_options_formality_notes')),
        'typing',
      );
      await tester.tap(find.byKey(const Key('preset_picker_work')));
      await tester.pump(const Duration(seconds: 1));
      final options = verify(() => harness.translate.setOptions(captureAny()))
          .captured
          .cast<TranslationOptions>();
      expect(options.map((o) => o.formalityContext), ['']);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('translate_options_formality_notes')),
            )
            .controller!
            .text,
        isEmpty,
      );
    });

    testWidgets('"Default" restores the standard settings', (tester) async {
      final harness = await _open(
        tester,
        const TranslationOptions(
          readingLevel: ReadingLevel.a2,
          context: 'Kids',
        ),
        presetsCubit(),
      );
      await tester.tap(find.byKey(const Key('preset_picker_default')));
      await tester.pump();
      final options = _captured(harness);
      expect(options.readingLevel, ReadingLevel.standard);
      expect(options.context, isEmpty);
      final context = tester.widget<TextField>(
        find.byKey(const Key('translate_options_context')),
      );
      expect(context.controller!.text, isEmpty);
    });

    testWidgets('"Manage presets" closes the sheet and opens the page', (
      tester,
    ) async {
      final harness = await _open(
        tester,
        const TranslationOptions(),
        presetsCubit(),
      );
      await tester.tap(find.byKey(const Key('preset_picker_manage')));
      await tester.pumpAndSettle();
      expect(find.byType(TranslationOptionsSheet), findsNothing);
      verify(() => harness.router.push<void>(translatePresetsLocation))
          .called(1);
    });

    testWidgets('stay when the engine is no longer an AI engine', (
      tester,
    ) async {
      final states = StreamController<TranslateState>.broadcast();
      addTearDown(states.close);
      final harness = TranslateHarness(
        state: _state(),
        presets: presetsCubit(),
      );
      when(() => harness.translate.stream).thenAnswer((_) => states.stream);
      await harness.pump(
        tester,
        child: const OptionsButton(),
        size: const Size(800, 2000),
      );
      await tester.tap(find.byKey(const Key('translate_options_button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('translate_options_presets')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('translate_options_ai_note')), findsNothing);

      final mozhi = readyState();
      harness.setState(mozhi);
      states.add(mozhi);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('translate_options_presets')),
        findsOneWidget,
      );
      // The note now says the options wait for an AI translator.
      expect(
        find.byKey(const Key('translate_options_ai_note')),
        findsOneWidget,
      );
    });

    testWidgets('are offered for engines other than AI', (tester) async {
      final harness = TranslateHarness(presets: presetsCubit());
      await harness.pump(
        tester,
        size: const Size(800, 2000),
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOptionsSheet(context),
            child: const Text('Open'),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(TranslationOptionsSheet), findsOneWidget);
      expect(
        find.byKey(const Key('translate_options_presets')),
        findsOneWidget,
      );
    });
  });

  group('wide layouts', () {
    testWidgets('open a side sheet that is never cut off', (tester) async {
      final harness = TranslateHarness(state: _state());
      await harness.pump(
        tester,
        child: const OptionsButton(),
        size: const Size(1200, 700),
      );
      await tester.tap(find.byKey(const Key('translate_options_button')));
      await tester.pumpAndSettle();
      final sheet = find.byKey(const Key('translate_options_side_sheet'));
      expect(sheet, findsOneWidget);
      final rect = tester.getRect(sheet);
      expect(rect.right, 1200);
      expect(rect.width, 420);
      expect(rect.top, 0);
      expect(rect.bottom, 700);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      // Everything scrolls into view.
      await tester.scrollUntilVisible(
        find.byKey(const Key('translate_options_reset')),
        200,
        scrollable: find
            .descendant(of: sheet, matching: find.byType(Scrollable))
            .first,
      );
      expect(find.byKey(const Key('translate_options_reset')), findsOneWidget);
      await tester.tap(find.byKey(const Key('translate_options_done')));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(harness.translate.state.options, const TranslationOptions());
    });

    testWidgets('slides in from the start in right-to-left layouts', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _state());
      await harness.pump(
        tester,
        child: const OptionsButton(),
        size: const Size(1200, 700),
        locale: const Locale('ar'),
      );
      await tester.tap(find.byKey(const Key('translate_options_button')));
      await tester.pumpAndSettle();
      final rect = tester.getRect(
        find.byKey(const Key('translate_options_side_sheet')),
      );
      expect(rect.left, 0);
    });

    testWidgets('a tap beside the side sheet closes it', (tester) async {
      final harness = TranslateHarness(state: _state());
      await harness.pump(
        tester,
        child: const OptionsButton(),
        size: const Size(1200, 700),
        disableAnimations: true,
      );
      await tester.tap(find.byKey(const Key('translate_options_button')));
      await tester.pump();
      expect(
        find.byKey(const Key('translate_options_side_sheet')),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(100, 350));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('translate_options_side_sheet')),
        findsNothing,
      );
    });
  });

  group('engines that do not apply every option', () {
    Finder note() => find.byKey(const Key('translate_options_ai_note'));
    Finder action() => find.byKey(const Key('translate_options_ai_action'));

    testWidgets('AI engines get no note', (tester) async {
      await _open(tester);
      expect(note(), findsNothing);
    });

    testWidgets('Mozhi engines get a note and every option', (tester) async {
      final harness = await _open(
        tester,
        const TranslationOptions(),
        null,
        readyState(),
      );
      expect(note(), findsOneWidget);
      expect(
        find.text(
          'DeepL translates without these options. Style, formality, '
          'gender and context need an AI translator. Your choices are '
          'saved and apply when you use one.',
        ),
        findsOneWidget,
      );
      for (final label in ['Style', 'Tone', 'Speaker gender', 'Context']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // Each ignored option is greyed with the reason.
      expect(find.text('AI engines only'), findsNWidgets(4));
      expect(find.text('AI engines and DeepL only'), findsNWidgets(3));
      expect(
        find.text(
          'Keep line breaks, Markdown, links and placeholders\n'
          'AI engines and DeepL only',
        ),
        findsOneWidget,
      );
      // The choices are still saved.
      await tester.tap(find.text('Literal'));
      expect(_captured(harness).style, TranslationStyle.literal);
    });

    testWidgets('DeepL API says what it applies', (tester) async {
      const deeplApi = TranslationEngine(
        id: 'mt:deepl',
        kind: EngineKind.mt,
        name: 'DeepL API',
        providerId: 'deepl',
        mtService: MtService.deepl,
      );
      await _open(
        tester,
        const TranslationOptions(),
        null,
        readyState(engine: deeplApi),
      );
      expect(
        find.text(
          'DeepL API applies formality, context, formatting and the '
          'glossary. Style, reading level and gender need an AI translator. '
          'Your choices are saved and apply when you use one.',
        ),
        findsOneWidget,
      );
      // Only what DeepL ignores is greyed.
      expect(find.text('AI engines only'), findsNWidgets(4));
      expect(find.text('AI engines and DeepL only'), findsNothing);
      expect(
        find.byKey(const ValueKey('translate_options_ignored:Style')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('translate_options_ignored:Tone')),
        findsNothing,
      );
    });

    testWidgets('translation-only AI models get the note too', (tester) async {
      const gemma = TranslationEngine(
        id: 'ai:gemma',
        kind: EngineKind.ai,
        name: 'Gemma',
        providerId: 'gemma',
        promptProfile: PromptProfile.translateGemma,
      );
      await _open(
        tester,
        const TranslationOptions(),
        null,
        readyState(engine: gemma),
      );
      expect(note(), findsOneWidget);
    });

    testWidgets('"Choose an AI translator" opens the engine picker', (
      tester,
    ) async {
      await _open(tester, const TranslationOptions(), null, readyState());
      expect(find.text('Choose an AI translator'), findsOneWidget);
      await tester.tap(action());
      await tester.pumpAndSettle();
      expect(find.byType(TranslationOptionsSheet), findsNothing);
      expect(find.byType(EngineSheet), findsOneWidget);
    });

    testWidgets('"Add AI provider" opens the provider settings without an AI '
        'translator', (tester) async {
      final harness = await _open(
        tester,
        const TranslationOptions(),
        null,
        readyState().copyWith(engines: const [deepl, google]),
      );
      expect(find.text('Add AI provider'), findsOneWidget);
      await tester.tap(action());
      await tester.pumpAndSettle();
      expect(find.byType(TranslationOptionsSheet), findsNothing);
      verify(() => harness.router.push<void>(translateProvidersLocation))
          .called(1);
    });

    testWidgets('offers no action without an AI translator or a router', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState().copyWith(engines: const [deepl, google]),
      );
      await tester.pumpWidget(
        BlocProvider<TranslateCubit>.value(
          value: harness.translate,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SizedBox(height: 900, child: TranslationOptionsSheet()),
            ),
          ),
        ),
      );
      expect(note(), findsOneWidget);
      expect(action(), findsNothing);
    });
  });

  group('Done', () {
    testWidgets('closes the sheet', (tester) async {
      await _open(tester);
      expect(find.text('Done'), findsOneWidget);
      await tester.tap(find.byKey(const Key('translate_options_done')));
      await tester.pumpAndSettle();
      expect(find.byType(TranslationOptionsSheet), findsNothing);
    });

    testWidgets('saves a context still being typed', (tester) async {
      final harness = await _open(tester);
      await tester.enterText(
        find.byKey(const Key('translate_options_context')),
        'Wedding speech',
      );
      await tester.tap(find.byKey(const Key('translate_options_done')));
      await tester.pumpAndSettle();
      expect(_captured(harness).context, 'Wedding speech');
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
