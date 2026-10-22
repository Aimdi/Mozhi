import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/dictionary.dart';
import 'package:mozhi/history/history.dart'
    show HistoryCubit, HistoryEntry, HistoryState, HistoryStatus;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:mozhi/voice/voice.dart' show SpeechInputService;
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';
import '../../translate/helpers/helpers.dart'
    show FakeSpeechInput, MockSpeechService;
import '../helpers/dictionary_helpers.dart';

class _MockGoRouter extends Mock implements GoRouter {
  new() {
    // Opened without an `extra` (no DictionaryLookUpRequest).
    final state = _MockGoRouterState();
    when(() => state.extra).thenReturn(null);
    when(() => this.state).thenReturn(state);
  }
}

class _MockGoRouterState extends Mock implements GoRouterState;

class _MockOfflineTranslator extends Mock implements OfflineTranslator;

const _readyWithAi = TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: [googleEngine, claudeEngine],
  engine: googleEngine,
  assistEngine: claudeEngine,
);

const _readyWithoutAi = TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: [googleEngine],
  engine: googleEngine,
);

void main() {
  setUpAll(registerDictionaryFallbacks);

  late MockTranslateCubit translateCubit;
  late MockSettingsCubit settingsCubit;
  late MockTranslationRepository repository;
  late MockUsageTracker tracker;

  setUp(() {
    translateCubit = MockTranslateCubit();
    settingsCubit = MockSettingsCubit();
    repository = MockTranslationRepository();
    tracker = MockUsageTracker();
    when(() => settingsCubit.state).thenReturn(const AppSettings());
    when(() => translateCubit.loadEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async {});
    when(
      () => tracker.recordText(
        any(),
        input: any(named: 'input'),
        output: any(named: 'output'),
      ),
    ).thenAnswer((_) async => UsageStats.zero);
    stubLookUp(repository, () async => gatoEntry);
  });

  void verifyLookUps(int times) => verify(
    () => repository.lookUp(
      any(),
      any(),
      source: any(named: 'source'),
      target: any(named: 'target'),
      uiLanguage: any(named: 'uiLanguage'),
      verbosity: any(named: 'verbosity'),
    ),
  ).called(times);

  void verifyNoLookUp() => verifyNever(
    () => repository.lookUp(
      any(),
      any(),
      source: any(named: 'source'),
      target: any(named: 'target'),
      uiLanguage: any(named: 'uiLanguage'),
      verbosity: any(named: 'verbosity'),
    ),
  );

  Future<void> pumpPage(
    WidgetTester tester, {
    DictionaryPage page = const DictionaryPage(),
    TranslateState state = _readyWithAi,
    Stream<TranslateState>? stream,
    GoRouter? router,
    bool withTracker = false,
    Size size = const Size(600, 1600),
    SpeechService? speech,
    SpeechInputService? speechInput,
    TextDirection? direction,
    HistoryCubit? history,
    OfflineTranslator? offline,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      translateCubit,
      stream ?? const Stream<TranslateState>.empty(),
      initialState: state,
    );
    Widget tree = MultiBlocProvider(
      providers: [
        BlocProvider<TranslateCubit>.value(value: translateCubit),
        BlocProvider<SettingsCubit>.value(value: settingsCubit),
        if (history != null) BlocProvider<HistoryCubit>.value(value: history),
      ],
      child: direction == null
          ? page
          : Directionality(textDirection: direction, child: page),
    );
    if (withTracker) {
      tree = RepositoryProvider<UsageTracker>.value(
        value: tracker,
        child: tree,
      );
    }
    if (speech != null) {
      tree = RepositoryProvider<SpeechService>.value(
        value: speech,
        child: tree,
      );
    }
    if (speechInput != null) {
      tree = RepositoryProvider<SpeechInputService>.value(
        value: speechInput,
        child: tree,
      );
    }
    tree = RepositoryProvider<TranslationRepository>.value(
      value: repository,
      child: tree,
    );
    if (offline != null) {
      tree = RepositoryProvider<OfflineTranslator>.value(
        value: offline,
        child: tree,
      );
    }
    if (router != null) {
      tree = InheritedGoRouter(goRouter: router, child: tree);
    }
    await tester.pumpApp(tree);
    await tester.pump();
  }

  DictionaryState dictionaryState(WidgetTester tester) =>
      tester.element(find.byType(DictionaryView)).read<DictionaryCubit>().state;

  void verifyLookUp(
    String word, {
    DictionaryVerbosity verbosity = DictionaryVerbosity.standard,
  }) => verify(
    () => repository.lookUp(
      claudeEngine,
      word,
      source: any(named: 'source'),
      target: any(named: 'target'),
      uiLanguage: any(named: 'uiLanguage'),
      verbosity: verbosity,
    ),
  ).called(1);

  Finder verbosityChip(DictionaryVerbosity verbosity) => find.descendant(
    of: find.byKey(const Key('dictionary_verbosity')),
    matching: find.byKey(
      ValueKey('translate_dictionary_verbosity:${verbosity.name}'),
    ),
  );

  bool isSelected(WidgetTester tester, DictionaryVerbosity verbosity) =>
      tester.widget<ChoiceChip>(verbosityChip(verbosity)).selected;

  Finder searchEditable() => find.descendant(
    of: find.byKey(const Key('dictionary_search_field')),
    matching: find.byType(EditableText),
  );

  /// The icon button inside [key] (the go button, the options button …).
  Finder buttonIn(Key key) => find.descendant(
    of: find.byKey(key),
    matching: find.byWidgetPredicate(
      (widget) => widget is IconButton || widget is TextButton,
    ),
  );

  /// Tooltips that leave the semantics to their child (`find.byTooltip`
  /// only knows Flutter's own `Tooltip` class for those).
  Finder tooltip(String message) => find.byWidgetPredicate(
    (widget) => widget is Tooltip && widget.message == message,
  );

  /// The go button ("Look up").
  IconButton goButton(WidgetTester tester) =>
      tester.widget<IconButton>(buttonIn(const Key('dictionary_look_up')));

  /// The focus node of the button [button].
  FocusNode focusOf(WidgetTester tester, Finder button) => Focus.of(
    tester.element(find.descendant(of: button, matching: find.byType(Icon))),
  );

  /// Opens the options sheet from the composer (or, with an entry, from
  /// the app bar).
  Future<void> openOptions(WidgetTester tester) async {
    final composer = find.byKey(const Key('dictionary_options_button'));
    await tester.tap(
      composer.evaluate().isNotEmpty
          ? composer
          : find.byKey(const Key('dictionary_result_options')),
    );
    await tester.pumpAndSettle();
  }

  /// Closes a bottom sheet by tapping the barrier.
  Future<void> closeSheet(WidgetTester tester) async {
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }

  /// The user drives the app with a keyboard (or a mouse).
  void useKeyboard() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
  }

  /// The user drives the app by touch.
  void useTouch() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
  }

  MockSpeechService speechService() {
    final speech = MockSpeechService();
    when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
    when(() => speech.current).thenReturn(null);
    when(
      () => speech.toggle(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
      ),
    ).thenAnswer((_) async {});
    return speech;
  }

  group('DictionaryPage', () {
    testWidgets('greets above the docked composer', (tester) async {
      useKeyboard();
      await pumpPage(tester);

      expect(find.byKey(const Key('dictionary_hero')), findsOneWidget);
      expect(find.text('Look up a word'), findsOneWidget);
      expect(
        find.text(
          'Meanings, pronunciation and examples from your AI provider.',
        ),
        findsOneWidget,
      );
      final composer = tester.getRect(
        find.byKey(const Key('dictionary_composer')),
      );
      expect(
        tester.getCenter(find.text('Look up a word')).dy,
        lessThan(composer.top),
      );
      // Docked at the bottom.
      expect(composer.bottom, greaterThan(1400));
      // [options | languages | go], like every composer.
      final options = tester.getCenter(
        find.byKey(const Key('dictionary_options_button')),
      );
      final go = tester.getCenter(find.byKey(const Key('dictionary_look_up')));
      final languages = tester.getCenter(
        find.byKey(const Key('dictionary_language_pair')),
      );
      expect(options.dx, lessThan(languages.dx));
      expect(languages.dx, lessThan(go.dx));
      expect(find.text('Detect language'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.byKey(const Key('dictionary_back')), findsNothing);
      // Driven by a keyboard: the field takes the focus.
      final field = tester.widget<TextField>(
        find.byKey(const Key('dictionary_search_field')),
      );
      expect(field.autofocus, isTrue);
      final state = dictionaryState(tester);
      expect(state.engine, claudeEngine);
      expect(state.source, Language.auto);
      expect(state.target, LanguageCatalog.byCode('en'));
    });

    group('autofocus', () {
      bool autofocus(WidgetTester tester) => tester
          .widget<TextField>(find.byKey(const Key('dictionary_search_field')))
          .autofocus;

      testWidgets('not on a tap on the tab on a touch screen', (tester) async {
        useTouch();
        await pumpPage(tester);

        expect(autofocus(tester), isFalse);
      });

      testWidgets('for a link that names the languages', (tester) async {
        useTouch();
        await pumpPage(tester, page: const DictionaryPage(from: 'es'));

        expect(autofocus(tester), isTrue);
      });

      test('dictionaryAutofocus', () {
        expect(
          dictionaryAutofocus(highlightMode: FocusHighlightMode.touch),
          isFalse,
        );
        expect(
          dictionaryAutofocus(highlightMode: FocusHighlightMode.traditional),
          isTrue,
        );
        expect(
          dictionaryAutofocus(
            highlightMode: FocusHighlightMode.touch,
            launchedHere: true,
          ),
          isTrue,
        );
        expect(
          dictionaryAutofocus(
            highlightMode: FocusHighlightMode.touch,
            linked: true,
          ),
          isTrue,
        );
      });
    });

    testWidgets('names the go button "Look up"', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPage(tester, page: const DictionaryPage(word: 'gato'));

      expect(find.bySemanticsLabel('Look up'), findsOneWidget);
      expect(tooltip('Look up'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Language of the word: detected automatically'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Translations in: English'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('options hold the detail level, languages and engine', (
      tester,
    ) async {
      await pumpPage(tester);

      await openOptions(tester);
      expect(find.byKey(const Key('dictionary_options_sheet')), findsOneWidget);
      expect(find.text('Options'), findsOneWidget);
      expect(find.text('Detail level'), findsOneWidget);
      expect(find.byKey(const Key('dictionary_verbosity')), findsOneWidget);
      expect(find.text('Languages'), findsOneWidget);
      expect(
        find.byKey(const Key('dictionary_source_language')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('dictionary_swap')), findsOneWidget);
      expect(find.text('Dictionary entries by Claude'), findsOneWidget);
    });

    testWidgets('prefills a linked word without looking it up', (tester) async {
      await pumpPage(
        tester,
        page: const DictionaryPage(word: ' gato ', from: 'es', to: 'fr'),
      );

      expect(find.text('gato'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('dictionary_search_field')),
      );
      expect(field.autofocus, isFalse);
      final state = dictionaryState(tester);
      expect(state.word, 'gato');
      expect(state.source.code, 'es');
      expect(state.target.code, 'fr');
      expect(find.text('Spanish'), findsOneWidget);
      expect(find.text('French'), findsOneWidget);
      verifyNoLookUp();

      await tester.tap(find.byKey(const Key('dictionary_look_up')));
      await tester.pump();
      await tester.pump();

      verify(
        () => repository.lookUp(
          claudeEngine,
          'gato',
          source: LanguageCatalog.byCode('es')!,
          target: LanguageCatalog.byCode('fr')!,
        ),
      ).called(1);
      expect(find.byType(DictionaryEntryTabs), findsOneWidget);
      expect(find.byKey(const Key('dictionary_composer')), findsNothing);
      expect(find.byKey(const Key('dictionary_hero')), findsNothing);
      expect(
        find.textContaining('A small domesticated feline.', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('AI-generated'), findsOneWidget);
    });

    testWidgets('caps a linked word', (tester) async {
      await pumpPage(tester, page: DictionaryPage(word: 'w' * 1000));

      expect(dictionaryState(tester).word, hasLength(100));
    });

    testWidgets('looks up right away when opened from the app', (tester) async {
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'gato', autoLookUp: true),
        withTracker: true,
      );
      await tester.pump();

      verifyLookUps(1);
      expect(find.byKey(const Key('dictionary_entry')), findsOneWidget);
      verify(
        () => tracker.recordText(
          'claude',
          input: 'gato',
          output: any(named: 'output'),
        ),
      ).called(1);
    });

    testWidgets('never looks links up on its own, even with instant AI', (
      tester,
    ) async {
      // Instant AI translation is on by default.
      when(() => settingsCubit.state).thenReturn(const AppSettings());
      await pumpPage(tester, page: const DictionaryPage(word: 'gato'));
      await tester.pump();

      verifyNoLookUp();
      final state = dictionaryState(tester);
      expect(state.word, 'gato');
      expect(state.status, DictionaryStatus.idle);
    });

    testWidgets('ignores unknown and custom link languages', (tester) async {
      await pumpPage(
        tester,
        state: _readyWithAi.copyWith(
          source: const Language(code: 'de', name: 'German'),
          target: const Language.custom('Pirate speak'),
        ),
        page: DictionaryPage(word: 'Haus', from: 'x' * 100, to: 'Pirate speak'),
      );

      final state = dictionaryState(tester);
      expect(state.source.code, 'de');
      expect(state.target.code, 'en');
    });

    testWidgets('ignores blank and unknown link languages', (tester) async {
      await pumpPage(
        tester,
        state: _readyWithAi.copyWith(
          source: const Language.custom('Shakespeare'),
          target: const Language(code: 'xx', name: 'Nowhere'),
        ),
        page: const DictionaryPage(word: 'Haus', from: ' ', to: 'qq-zz'),
      );

      final state = dictionaryState(tester);
      expect(state.source, Language.auto);
      expect(state.target.code, 'en');
    });

    testWidgets('accepts language names and auto in links', (tester) async {
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'chat', from: 'auto', to: 'German'),
      );

      final state = dictionaryState(tester);
      expect(state.source, Language.auto);
      expect(state.target.code, 'de');
    });

    testWidgets('waits for an engine that loads later', (tester) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      await pumpPage(
        tester,
        state: const TranslateState(enginesStatus: EnginesStatus.loading),
        stream: states.stream,
        page: const DictionaryPage(word: 'gato', autoLookUp: true),
      );

      // Above the composer, in place of the greeting.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const Key('dictionary_hero')), findsNothing);
      expect(goButton(tester).onPressed, isNull);
      verifyNoLookUp();

      states.add(_readyWithAi);
      await tester.pump();
      await tester.pump();

      verifyLookUps(1);
      expect(find.byType(DictionaryEntryTabs), findsOneWidget);
    });

    testWidgets('uses the first engine with AI extras', (tester) async {
      const mtEngine = TranslationEngine(
        id: 'ai:gemma',
        kind: EngineKind.ai,
        name: 'TranslateGemma',
        promptProfile: PromptProfile.translateGemma,
      );
      await pumpPage(
        tester,
        state: const TranslateState(
          enginesStatus: EnginesStatus.ready,
          engines: [mtEngine, ollamaEngine],
          engine: mtEngine,
          assistEngine: mtEngine,
        ),
      );

      expect(dictionaryState(tester).engine, ollamaEngine);
      await openOptions(tester);
      expect(find.text('Dictionary entries by Ollama'), findsOneWidget);
    });

    group('detail level', () {
      testWidgets('starts as on the translate screen and never looks up '
          'on its own', (tester) async {
        await pumpPage(
          tester,
          state: _readyWithAi.copyWith(
            dictionaryVerbosity: DictionaryVerbosity.concise,
          ),
          page: const DictionaryPage(word: 'gato'),
        );
        await openOptions(tester);

        expect(find.text('Concise'), findsOneWidget);
        expect(find.text('Standard'), findsOneWidget);
        expect(find.text('Detailed'), findsOneWidget);
        expect(find.bySemanticsLabel('Detail level'), findsOneWidget);
        expect(dictionaryState(tester).verbosity, DictionaryVerbosity.concise);
        expect(isSelected(tester, DictionaryVerbosity.concise), isTrue);

        await tester.tap(verbosityChip(DictionaryVerbosity.comprehensive));
        await tester.pump();

        expect(
          dictionaryState(tester).verbosity,
          DictionaryVerbosity.comprehensive,
        );
        expect(isSelected(tester, DictionaryVerbosity.comprehensive), isTrue);
        expect(isSelected(tester, DictionaryVerbosity.concise), isFalse);
        verifyNoLookUp();

        await closeSheet(tester);
        await tester.tap(find.byKey(const Key('dictionary_look_up')));
        await tester.pump();
        await tester.pump();
        verifyLookUp('gato', verbosity: DictionaryVerbosity.comprehensive);
      });

      testWidgets('looks the shown word up again', (tester) async {
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato', autoLookUp: true),
        );
        await tester.pump();
        verifyLookUp('gato');
        // From the entry's app bar.
        await openOptions(tester);
        expect(isSelected(tester, DictionaryVerbosity.standard), isTrue);

        // The selected level is not requested again.
        await tester.tap(verbosityChip(DictionaryVerbosity.standard));
        await tester.pump();
        verifyNoLookUp();

        await tester.tap(verbosityChip(DictionaryVerbosity.concise));
        await tester.pump();
        await tester.pump();

        verifyLookUp('gato', verbosity: DictionaryVerbosity.concise);
        await closeSheet(tester);
        expect(find.byKey(const Key('dictionary_entry')), findsOneWidget);
      });
    });

    group('entry', () {
      const fullEntry = DictionaryEntry(
        word: 'gato',
        pronunciation: '/ˈɡato/',
        partsOfSpeech: ['noun'],
        senses: [
          DictionarySense(
            definition: 'A small domesticated feline.',
            partOfSpeech: 'noun',
            translations: ['cat'],
            usage: 'common',
          ),
          DictionarySense(
            definition: 'A car jack.',
            partOfSpeech: 'noun',
            translations: ['jack'],
            usage: 'colloquial',
          ),
        ],
        examples: [
          DictionaryExample(
            source: 'El gato duerme.',
            translation: 'The cat sleeps.',
          ),
        ],
        synonyms: ['minino', ' ', 'micho'],
        etymology: 'From Late Latin cattus.',
        notes: 'Feminine: gata.',
        relatedWords: ['felino', ' ', 'gatito'],
      );

      Future<void> pumpEntry(
        WidgetTester tester, {
        DictionaryEntry entry = fullEntry,
        String from = 'es',
        SpeechService? speech,
        Size size = const Size(600, 1600),
        HistoryCubit? history,
        OfflineTranslator? offline,
      }) async {
        stubLookUp(repository, () async => entry);
        await pumpPage(
          tester,
          size: size,
          speech: speech,
          history: history,
          offline: offline,
          page: DictionaryPage(
            word: 'gato',
            from: from,
            to: 'en',
            autoLookUp: true,
          ),
        );
        await tester.pump();
        await tester.pump();
      }

      testWidgets('shows the meaning centred, in big type', (tester) async {
        await pumpEntry(tester);

        expect(find.text('Meaning'), findsOneWidget);
        expect(find.text('Usage'), findsOneWidget);
        expect(find.text('Examples'), findsOneWidget);
        // Normal-sized tabs, the entry from the top of the page.
        final theme = Theme.of(tester.element(find.text('Meaning')));
        expect(
          tester.widget<TabBar>(find.byType(TabBar)).labelStyle?.fontSize,
          theme.textTheme.titleSmall?.fontSize,
        );
        expect(find.text('noun'), findsOneWidget);
        final headword = find.byKey(const Key('dictionary_headword'));
        expect(headword, findsOneWidget);
        expect(
          tester.widget<Text>(headword).style?.fontSize,
          greaterThanOrEqualTo(36),
        );
        expect(find.text('/ˈɡato/'), findsOneWidget);
        expect(
          find.textContaining(
            'A small domesticated feline.',
            findRichText: true,
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('(common)', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('In English'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('dictionary_translations')),
            matching: find.textContaining('cat', findRichText: true),
          ),
          findsOneWidget,
        );
        // The second sense is on the "Usage" tab.
        expect(
          find.textContaining('A car jack.', findRichText: true),
          findsNothing,
        );
        expect(
          tester.getCenter(headword).dx,
          moreOrLessEquals(300, epsilon: 1),
        );
        expect(
          tester.getTopLeft(headword).dy,
          lessThan(tester.getBottomLeft(find.byType(TabBar)).dy + 120),
        );
        // No speech service: no listen button.
        expect(find.byKey(const Key('dictionary_listen')), findsNothing);
      });

      testWidgets('synonyms look that word up', (tester) async {
        final semantics = tester.ensureSemantics();
        await pumpEntry(tester);

        expect(find.bySemanticsLabel('Synonyms'), findsOneWidget);
        final synonym = find.byKey(const ValueKey('dictionary_synonym:micho'));
        expect(synonym, findsOneWidget);
        expect(find.byTooltip('Look up “micho”'), findsOneWidget);
        // Blank synonyms are left out.
        expect(
          find.descendant(
            of: find.byKey(const Key('dictionary_synonyms')),
            matching: find.byType(TextButton),
          ),
          findsNWidgets(2),
        );
        await tester.tap(synonym);
        await tester.pump();
        await tester.pump();

        verifyLookUp('micho');
        expect(dictionaryState(tester).word, 'micho');
        semantics.dispose();
      });

      testWidgets('the other senses, related words, etymology and notes '
          'are on "Usage"', (tester) async {
        await pumpEntry(tester);

        await tester.tap(find.text('Usage'));
        await tester.pumpAndSettle();

        expect(find.text('Other meanings'), findsOneWidget);
        expect(find.text('2.'), findsOneWidget);
        expect(
          find.textContaining('A car jack.', findRichText: true),
          findsOneWidget,
        );
        expect(find.textContaining('jack', findRichText: true), findsWidgets);
        expect(find.text('Related words'), findsOneWidget);
        expect(find.byType(ActionChip), findsNWidgets(2));
        expect(find.text('Etymology'), findsOneWidget);
        expect(find.text('From Late Latin cattus.'), findsOneWidget);
        expect(find.text('Notes'), findsOneWidget);
        expect(find.text('Feminine: gata.'), findsOneWidget);

        final chip = find.byKey(const ValueKey('dictionary_related:gatito'));
        await tester.ensureVisible(chip);
        stubLookUp(repository, () async => gatoEntry);
        await tester.tap(chip);
        await tester.pump();
        await tester.pump();

        verifyLookUp('gatito');
        final state = dictionaryState(tester);
        expect(state.word, 'gatito');
        expect(state.lookedUp, 'gatito');
        // A new entry starts on its meaning.
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('dictionary_headword')), findsOneWidget);
      });

      testWidgets('the examples are on "Examples"', (tester) async {
        await pumpEntry(tester);

        await tester.tap(find.text('Examples'));
        await tester.pumpAndSettle();

        expect(find.text('El gato duerme.'), findsOneWidget);
        expect(find.text('The cat sleeps.'), findsOneWidget);
      });

      testWidgets('leaves the tabs out when there is only the meaning', (
        tester,
      ) async {
        await pumpEntry(
          tester,
          entry: const DictionaryEntry(
            word: 'gato',
            senses: [DictionarySense(definition: 'A cat.')],
            partsOfSpeech: ['noun', 'adjective'],
          ),
        );

        expect(find.byKey(const Key('dictionary_tabs')), findsNothing);
        expect(find.byType(TabBar), findsNothing);
        expect(find.text('noun · adjective'), findsOneWidget);
        expect(find.byKey(const Key('dictionary_ipa')), findsNothing);
        expect(find.byKey(const Key('dictionary_synonyms')), findsNothing);
        expect(find.byKey(const Key('dictionary_translations')), findsNothing);
      });

      testWidgets('sets long words and phrases smaller', (tester) async {
        double sizeOf(WidgetTester tester) => tester
            .widget<Text>(find.byKey(const Key('dictionary_headword')))
            .style!
            .fontSize!;
        await pumpEntry(tester);
        final short = sizeOf(tester);

        // A new page each time (with its own cubit and look-up).
        await tester.pumpWidget(const SizedBox());
        await pumpEntry(
          tester,
          entry: const DictionaryEntry(
            word: 'Donaudampfschiff',
            senses: [DictionarySense(definition: 'A Danube steamer.')],
          ),
        );
        final long = sizeOf(tester);

        await tester.pumpWidget(const SizedBox());
        await pumpEntry(
          tester,
          entry: const DictionaryEntry(
            word: 'to take the bull by the horns',
            senses: [DictionarySense(definition: 'To face a problem.')],
          ),
        );
        final phrase = sizeOf(tester);

        expect(long, lessThan(short));
        expect(phrase, lessThan(long));
        expect(tester.takeException(), isNull);
      });

      testWidgets('reads the word aloud in its language', (tester) async {
        final speech = speechService();
        await pumpEntry(tester, speech: speech);

        final listen = find.byKey(const Key('dictionary_listen'));
        expect(listen, findsOneWidget);
        final button = find.descendant(
          of: listen,
          matching: find.byType(IconButton),
        );
        expect(tester.getSize(button).height, greaterThanOrEqualTo(56));
        await tester.tap(button);
        await tester.pump();

        verify(
          () => speech.toggle(
            id: 'dictionary_word',
            text: 'gato',
            languageCode: 'es',
          ),
        ).called(1);
      });

      testWidgets('asks for the word language to listen while detecting', (
        tester,
      ) async {
        await pumpEntry(tester, from: 'auto', speech: speechService());

        final button = find.descendant(
          of: find.byKey(const Key('dictionary_listen')),
          matching: find.byType(IconButton),
        );
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        expect(
          tooltip('Choose the word’s language to listen to it'),
          findsOneWidget,
        );
      });

      testWidgets('reads a detected word in the language the device '
          'identified', (tester) async {
        final offline = _MockOfflineTranslator();
        when(() => offline.isAvailable).thenReturn(true);
        when(() => offline.identifyLanguage(any()))
            .thenAnswer((_) async => 'es');
        final speech = speechService();
        await pumpEntry(tester, from: 'auto', speech: speech, offline: offline);
        await tester.pump();

        final button = find.descendant(
          of: find.byKey(const Key('dictionary_listen')),
          matching: find.byType(IconButton),
        );
        await tester.tap(button);
        await tester.pump();
        verify(
          () => speech.toggle(
            id: 'dictionary_word',
            text: 'gato',
            languageCode: 'es',
          ),
        ).called(1);
        // The example sentence went to the on-device identifier.
        final asked =
            verify(() => offline.identifyLanguage(captureAny())).captured.single
                as String;
        expect(asked, contains('El gato duerme.'));
      });

      testWidgets('does not ask an unavailable on-device identifier', (
        tester,
      ) async {
        final offline = _MockOfflineTranslator();
        when(() => offline.isAvailable).thenReturn(false);
        await pumpEntry(
          tester,
          from: 'auto',
          speech: speechService(),
          offline: offline,
        );
        await tester.pump();

        verifyNever(() => offline.identifyLanguage(any()));
      });

      testWidgets('"Did you mean …?" looks the suggestion up', (tester) async {
        stubLookUp(
          repository,
          () async => const DictionaryEntry(
            word: 'gato',
            senses: [DictionarySense(definition: 'A cat.')],
            didYouMean: 'gato',
          ),
        );
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gatto', autoLookUp: true),
        );
        await tester.pump();
        verifyLookUp('gatto');

        final link = find.byKey(const Key('dictionary_did_you_mean'));
        expect(link, findsOneWidget);
        expect(
          find.textContaining('Did you mean “gato”?', findRichText: true),
          findsOneWidget,
        );
        await tester.tap(link);
        await tester.pump();
        await tester.pump();

        verifyLookUp('gato');
        expect(dictionaryState(tester).word, 'gato');
        // Not offered for the word that was looked up.
        expect(link, findsNothing);
      });

      testWidgets('fits a small phone at 200% text', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpEntry(
          tester,
          size: const Size(320, 640),
          speech: speechService(),
          // With the favorite heart beside Listen.
          history: createDictionaryHistory(),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('dictionary_favorite')), findsOneWidget);
        expect(find.byKey(const Key('dictionary_search_bar')), findsOneWidget);
        // The tabs scroll: "Usage" may be past the edge.
        await tester.ensureVisible(find.text('Usage'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Usage'));
        await tester.pumpAndSettle();
        expect(find.text('Other meanings'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });

    group('without an AI engine', () {
      testWidgets('links to the AI provider settings', (tester) async {
        final router = _MockGoRouter();
        when(router.canPop).thenReturn(true);
        when(() => router.push<void>(any())).thenAnswer((_) async {});
        await pumpPage(tester, state: _readyWithoutAi, router: router);

        // In place of the greeting, above the composer.
        expect(find.byKey(const Key('dictionary_no_engine')), findsOneWidget);
        expect(find.byKey(const Key('dictionary_hero')), findsNothing);
        expect(find.byKey(const Key('dictionary_composer')), findsOneWidget);
        expect(
          find.text('The dictionary needs an AI provider'),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const Key('dictionary_search_field')),
          'gato',
        );
        await tester.pump();
        expect(goButton(tester).onPressed, isNull);

        await tester.tap(find.text('Add AI provider'));
        // Above the tabs: back returns to the dictionary.
        verify(() => router.push<void>('/settings/providers')).called(1);
        expect(dictionaryProvidersRoute, '/settings/providers');

        await openOptions(tester);
        expect(find.byKey(const Key('dictionary_engine')), findsNothing);
      });

      testWidgets('offers a retry when the engines failed to load', (
        tester,
      ) async {
        await pumpPage(
          tester,
          state: const TranslateState(enginesStatus: EnginesStatus.failure),
        );

        expect(
          find.byKey(const Key('dictionary_engines_error')),
          findsOneWidget,
        );
        // The engines (Mozhi instances) failed: AI providers never do.
        expect(find.text("Couldn't load translation engines"), findsOneWidget);
        expect(
          find.text(
            'Check your connection and try again. The dictionary also needs '
            'an AI provider.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Retry'));
        verify(() => translateCubit.loadEngines(refresh: true)).called(1);
      });
    });

    testWidgets('shows errors with a retry', (tester) async {
      stubLookUp(repository, () async => throw StateError('boom'));
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'gato', autoLookUp: true),
      );
      await tester.pump();

      expect(find.byType(TranslateErrorView), findsOneWidget);
      // The search stays above the error.
      expect(find.byKey(const Key('dictionary_search_bar')), findsOneWidget);
      stubLookUp(repository, () async => gatoEntry);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(DictionaryEntryTabs), findsOneWidget);
    });

    testWidgets('asks for consent before sending the word', (tester) async {
      var calls = 0;
      stubLookUp(repository, () async {
        if (calls++ == 0) {
          throw const ConsentRequiredException(
            kind: ConsentKind.pair,
            destination: PublicInstanceDestination(
              'mozhi.example.org',
              engine: 'google',
            ),
            engineId: 'ai:claude',
            source: 'es',
            target: 'en',
          );
        }
        return gatoEntry;
      });
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'gato', autoLookUp: true),
      );
      await tester.pump();

      expect(find.byKey(const Key('translate_error_consent')), findsOneWidget);
    });

    testWidgets('says when there is no entry', (tester) async {
      stubLookUp(repository, () async => const DictionaryEntry(word: 'qwz'));
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'qwz', autoLookUp: true),
      );
      await tester.pump();

      expect(find.byKey(const Key('dictionary_not_found')), findsOneWidget);
      expect(find.text('No dictionary entry found for “qwz”.'), findsOneWidget);
    });

    testWidgets('shows the word and progress while looking up', (tester) async {
      final pending = Completer<DictionaryEntry>();
      stubLookUp(repository, () => pending.future);
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'gato', autoLookUp: true),
      );

      expect(find.byKey(const Key('dictionary_loading')), findsOneWidget);
      expect(find.bySemanticsLabel('Looking up…'), findsOneWidget);
      // In large type, and in the search bar above it.
      expect(find.text('gato'), findsWidgets);
      pending.complete(gatoEntry);
      await tester.pump();
      expect(find.byKey(const Key('dictionary_loading')), findsNothing);
    });

    group('result navigation', () {
      testWidgets('back returns to the search with the word', (tester) async {
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato', autoLookUp: true),
        );
        await tester.pump();
        expect(find.byType(DictionaryEntryTabs), findsOneWidget);

        await tester.tap(find.byKey(const Key('dictionary_back')));
        await tester.pump();

        expect(find.byType(DictionaryEntryTabs), findsNothing);
        expect(find.byKey(const Key('dictionary_hero')), findsOneWidget);
        expect(find.byKey(const Key('dictionary_back')), findsNothing);
        final state = dictionaryState(tester);
        expect(state.status, DictionaryStatus.idle);
        expect(state.word, 'gato');
        expect(state.entry, isNull);
        final field = tester.widget<TextField>(
          find.byKey(const Key('dictionary_search_field')),
        );
        expect(field.controller!.text, 'gato');
        // Not focused again: no keyboard pops up.
        expect(field.autofocus, isFalse);
      });

      testWidgets('system back does the same, then leaves', (tester) async {
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato', autoLookUp: true),
        );
        await tester.pump();

        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump();

        expect(dictionaryState(tester).status, DictionaryStatus.idle);
        expect(find.byKey(const Key('dictionary_hero')), findsOneWidget);
      });

      testWidgets('back while looking up ignores the late entry', (
        tester,
      ) async {
        final pending = Completer<DictionaryEntry>();
        stubLookUp(repository, () => pending.future);
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato', autoLookUp: true),
        );

        await tester.tap(find.byKey(const Key('dictionary_back')));
        await tester.pump();
        pending.complete(gatoEntry);
        await tester.pump();

        expect(dictionaryState(tester).status, DictionaryStatus.idle);
        expect(find.byType(DictionaryEntryTabs), findsNothing);
      });

      testWidgets('the search bar on top looks the next word up', (
        tester,
      ) async {
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato', autoLookUp: true),
        );
        await tester.pump();

        final bar = find.byKey(const Key('dictionary_search_bar'));
        expect(bar, findsOneWidget);
        expect(find.byKey(const Key('dictionary_new_look_up')), findsNothing);
        // Above the entry, with the word and its languages inline.
        expect(
          tester.getRect(bar).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(TabBar)).top + 1),
        );
        expect(
          find.descendant(
            of: bar,
            matching: find.byKey(const Key('dictionary_language_pair')),
          ),
          findsOneWidget,
        );
        expect(
          tester.widget<EditableText>(searchEditable()).controller.text,
          'gato',
        );

        await tester.enterText(searchEditable(), 'perro');
        await tester.tap(find.byKey(const Key('dictionary_look_up')));
        await tester.pump();
        await tester.pump();
        verifyLookUp('perro');
        expect(dictionaryState(tester).lookedUp, 'perro');
      });

      testWidgets('the search bar puts the languages below on phones', (
        tester,
      ) async {
        await pumpPage(
          tester,
          size: const Size(400, 800),
          page: const DictionaryPage(word: 'gato', autoLookUp: true),
        );
        await tester.pump();

        final field = tester.getRect(
          find.byKey(const Key('dictionary_search_field')),
        );
        final pair = tester.getRect(
          find.byKey(const Key('dictionary_language_pair')),
        );
        expect(pair.top, greaterThan(field.bottom));
        expect(tester.takeException(), isNull);
      });

      testWidgets('Clear in the search bar starts a new look-up', (
        tester,
      ) async {
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato', autoLookUp: true),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('dictionary_clear')));
        await tester.pump();
        expect(dictionaryState(tester).word, isEmpty);
        expect(find.byKey(const Key('dictionary_hero')), findsOneWidget);
        expect(
          tester.widget<EditableText>(searchEditable()).focusNode,
          same(FocusManager.instance.primaryFocus),
        );
      });
    });

    group('search field', () {
      testWidgets('looks up on Enter', (tester) async {
        await pumpPage(tester);

        await tester.enterText(
          find.byKey(const Key('dictionary_search_field')),
          'gato',
        );
        await tester.pump();
        expect(dictionaryState(tester).word, 'gato');
        expect(goButton(tester).onPressed, isNotNull);

        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        await tester.pump();
        verifyLookUps(1);
        expect(find.byType(DictionaryEntryTabs), findsOneWidget);
        expect(find.byKey(const Key('dictionary_hero')), findsNothing);
      });

      testWidgets('clears and moves keyboard focus to the field', (
        tester,
      ) async {
        await pumpPage(tester, page: const DictionaryPage(word: 'gato'));

        focusOf(
          tester,
          find.byKey(const Key('dictionary_clear')),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(dictionaryState(tester).word, isEmpty);
        expect(find.byKey(const Key('dictionary_clear')), findsNothing);
        final field = tester.widget<TextField>(
          find.byKey(const Key('dictionary_search_field')),
        );
        expect(field.controller!.text, isEmpty);
        expect(
          tester.widget<EditableText>(searchEditable()).focusNode,
          same(FocusManager.instance.primaryFocus),
        );
      });

      testWidgets('works without a focus node of its own', (tester) async {
        final cubit = DictionaryCubit(
          repository: repository,
          engine: claudeEngine,
          word: 'gato',
        );
        addTearDown(cubit.close);
        await tester.pumpApp(
          BlocProvider.value(
            value: cubit,
            child: const Scaffold(body: DictionarySearchField()),
          ),
        );

        await tester.tap(find.byKey(const Key('dictionary_search_field')));
        await tester.pump();
        expect(
          tester.widget<EditableText>(searchEditable()).focusNode.hasFocus,
          isTrue,
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        verifyLookUps(1);
      });

      testWidgets('stays named once it holds a word', (tester) async {
        final semantics = tester.ensureSemantics();
        await pumpPage(tester, page: const DictionaryPage(word: 'gato'));

        expect(
          tester.getSemantics(searchEditable()),
          isSemantics(
            label: 'Look up a word or phrase',
            value: 'gato',
            isTextField: true,
          ),
        );
        semantics.dispose();
      });

      testWidgets('keyboard focus moves to the search bar above the entry', (
        tester,
      ) async {
        await pumpPage(tester, page: const DictionaryPage(word: 'gato'));

        focusOf(
          tester,
          find.byKey(const Key('dictionary_look_up')),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump();

        verifyLookUps(1);
        // The next word can be typed right away.
        expect(find.byKey(const Key('dictionary_search_bar')), findsOneWidget);
        expect(
          tester.widget<EditableText>(searchEditable()).focusNode,
          same(FocusManager.instance.primaryFocus),
        );
      });

      testWidgets('touch users get no keyboard over the entry', (tester) async {
        useTouch();
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato', autoLookUp: true),
        );
        await tester.pump();

        expect(
          tester
              .widget<TextField>(
                find.byKey(const Key('dictionary_search_field')),
              )
              .autofocus,
          isFalse,
        );
      });

      testWidgets('Enter looks up and hides the keyboard', (tester) async {
        await pumpPage(tester);

        await tester.enterText(
          find.byKey(const Key('dictionary_search_field')),
          'gato',
        );
        await tester.pump();
        expect(tester.testTextInput.isVisible, isTrue);
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        await tester.pump();

        verifyLookUps(1);
        expect(tester.testTextInput.isVisible, isFalse);
      });

      testWidgets(
        'puts the on-screen keyboard away only on touch platforms',
        (tester) async {
          await pumpPage(tester, page: const DictionaryPage(word: 'gato'));
          tester.testTextInput.log.clear();

          await tester.tap(find.byKey(const Key('dictionary_look_up')));
          await tester.pump();

          verifyLookUps(1);
          final methods = tester.testTextInput.log.map((call) => call.method);
          expect(
            methods,
            defaultTargetPlatform == TargetPlatform.iOS
                ? contains('TextInput.hide')
                : isNot(contains('TextInput.hide')),
          );
        },
        variant: const TargetPlatformVariant({
          TargetPlatform.iOS,
          TargetPlatform.linux,
        }),
      );

      testWidgets('does not look up blank words', (tester) async {
        await pumpPage(tester);

        await tester.enterText(
          find.byKey(const Key('dictionary_search_field')),
          '   ',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();

        verifyNoLookUp();
        expect(goButton(tester).onPressed, isNull);
      });

      testWidgets('limits the length', (tester) async {
        await pumpPage(tester);

        await tester.enterText(
          find.byKey(const Key('dictionary_search_field')),
          'x' * 150,
        );
        await tester.pump();

        expect(dictionaryState(tester).word, hasLength(100));
      });

      testWidgets('taps on the composer focus the field', (tester) async {
        await pumpPage(tester, page: const DictionaryPage(word: 'gato'));

        final composer = tester.getRect(
          find.byKey(const Key('dictionary_composer')),
        );
        await tester.tapAt(composer.topLeft + const Offset(8, 8));
        await tester.pump();

        expect(
          tester.widget<EditableText>(searchEditable()).focusNode.hasFocus,
          isTrue,
        );
      });
    });

    group('voice input', () {
      testWidgets('is not offered without a speech service', (tester) async {
        await pumpPage(tester);
        expect(find.byKey(const Key('dictionary_voice_input')), findsNothing);
      });

      testWidgets('dictates the word in its language', (tester) async {
        final speech = FakeSpeechInput();
        await pumpPage(
          tester,
          page: const DictionaryPage(from: 'es'),
          speechInput: speech.service,
        );
        final mic = find.descendant(
          of: find.byKey(const Key('dictionary_voice_input')),
          matching: find.byType(IconButton),
        );
        expect(mic, findsOneWidget);

        await tester.tap(mic);
        await tester.pump();
        expect(speech.languages, ['es']);

        speech.say('ga');
        await tester.pump();
        expect(dictionaryState(tester).word, 'ga');
        speech.say(' gato ', isFinal: true);
        await tester.pump();
        expect(dictionaryState(tester).word, 'gato');
        speech.say('  ', isFinal: true);
        await tester.pump();
        expect(dictionaryState(tester).word, 'gato');
        verifyNoLookUp();
      });
    });

    group('languages', () {
      testWidgets('picks the word language from a searchable list', (
        tester,
      ) async {
        await pumpPage(tester, page: const DictionaryPage(word: 'gato'));

        await tester.tap(find.byKey(const Key('dictionary_bar_source')));
        await tester.pumpAndSettle();
        expect(find.text('Language of the word'), findsOneWidget);
        expect(find.byKey(const Key('dictionary_language_auto')), findsOne);
        expect(
          find.descendant(
            of: find.byKey(const Key('dictionary_language_auto')),
            matching: find.byType(LanguageAvatar),
          ),
          findsOne,
        );

        await tester.enterText(
          find.byKey(const Key('dictionary_language_search')),
          'españ',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('dictionary_language_es')));
        await tester.pumpAndSettle();

        expect(dictionaryState(tester).source.code, 'es');
        expect(find.text('Spanish'), findsOneWidget);
        verifyNoLookUp();
      });

      testWidgets('keeps the language list above the keyboard', (tester) async {
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato'),
          size: const Size(400, 800),
        );
        await tester.tap(find.byKey(const Key('dictionary_bar_source')));
        await tester.pumpAndSettle();
        final list = find.descendant(
          of: find.byType(DictionaryLanguagePicker),
          matching: find.byType(ListView),
        );
        expect(tester.getRect(list).bottom, moreOrLessEquals(800));

        // The search field opens a 300 dp keyboard.
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();

        expect(tester.getRect(list).bottom, moreOrLessEquals(800 - 300));
        expect(tester.takeException(), isNull);
      });

      testWidgets('keeps the options above the navigation bar', (tester) async {
        await pumpPage(tester, size: const Size(400, 800));
        // Three-button navigation, drawn edge to edge.
        tester.view
          ..padding = const FakeViewPadding(bottom: 48)
          ..viewPadding = const FakeViewPadding(bottom: 48);
        await openOptions(tester);

        expect(
          tester.getRect(find.byKey(const Key('dictionary_engine'))).bottom,
          lessThanOrEqualTo(800 - 48 - 24),
        );
      });

      testWidgets('swaps them in the options', (tester) async {
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato', from: 'es'),
        );
        await openOptions(tester);

        final swap = find.byKey(const Key('dictionary_swap'));
        expect(tester.widget<IconButton>(swap).onPressed, isNotNull);
        await tester.tap(swap);
        await tester.pump();

        final state = dictionaryState(tester);
        expect(state.source.code, 'en');
        expect(state.target.code, 'es');
      });

      testWidgets('cannot swap while detecting the word language', (
        tester,
      ) async {
        await pumpPage(tester);
        await openOptions(tester);

        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('dictionary_swap')))
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const Key('dictionary_source_language')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('dictionary_language_search')),
          'French',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('dictionary_language_fr')));
        await tester.pumpAndSettle();
        expect(dictionaryState(tester).source.code, 'fr');
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('dictionary_swap')))
              .onPressed,
          isNotNull,
        );
      });

      testWidgets('names a detected word language for screen readers', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await pumpPage(tester);

        // Not "Language of the word: Detect language".
        expect(
          find.bySemanticsLabel('Language of the word: detected automatically'),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(RegExp('Detect language')), findsNothing);

        await tester.tap(find.byKey(const Key('dictionary_bar_source')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('dictionary_language_search')),
          'spanish',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('dictionary_language_es')));
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel('Language of the word: Spanish'),
          findsOneWidget,
        );
        semantics.dispose();
      });

      testWidgets('the language search stays named while it holds a query', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        await pumpPage(tester);

        await tester.tap(find.byKey(const Key('dictionary_bar_source')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('dictionary_language_search')),
          'spa',
        );
        // Let the hint fade out.
        await tester.pumpAndSettle();

        expect(
          tester.getSemantics(
            find.descendant(
              of: find.byKey(const Key('dictionary_language_search')),
              matching: find.byType(EditableText),
            ),
          ),
          isSemantics(
            label: 'Search languages',
            value: 'spa',
            isTextField: true,
          ),
        );
        semantics.dispose();
      });

      testWidgets('picks the first match on Enter', (tester) async {
        await pumpPage(tester);

        await tester.tap(find.byKey(const Key('dictionary_bar_target')));
        await tester.pumpAndSettle();
        expect(find.text('Translations in'), findsOneWidget);
        expect(find.byKey(const Key('dictionary_language_auto')), findsNothing);

        await tester.enterText(
          find.byKey(const Key('dictionary_language_search')),
          'fr',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();

        expect(dictionaryState(tester).target.code, 'fr');
      });

      testWidgets('says when no language matches and clears the search', (
        tester,
      ) async {
        await pumpPage(tester);

        await tester.tap(find.byKey(const Key('dictionary_bar_target')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('dictionary_language_search')),
          'zzzz',
        );
        await tester.pump();
        expect(find.text('No languages found'), findsOneWidget);

        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        expect(find.text('No languages found'), findsOneWidget);

        await tester.tap(find.byTooltip('Clear'));
        await tester.pump();
        expect(find.text('No languages found'), findsNothing);

        // Dismissing keeps the language.
        await closeSheet(tester);
        expect(dictionaryState(tester).target.code, 'en');
      });

      testWidgets('look the word up again once it was looked up', (
        tester,
      ) async {
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato', autoLookUp: true),
        );
        await tester.pump();
        verifyLookUps(1);

        await openOptions(tester);
        await tester.tap(find.byKey(const Key('dictionary_target_language')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('dictionary_language_search')),
          'French',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('dictionary_language_fr')));
        await tester.pumpAndSettle();

        verifyLookUps(1);
        expect(dictionaryState(tester).target.code, 'fr');
      });

      testWidgets('share the bar by their names', (tester) async {
        expect(dictionaryPairSplit(200, 50, 60), (100, 100));
        expect(dictionaryPairSplit(200, 150, 60), (140, 60));
        expect(dictionaryPairSplit(200, 50, 160), (50, 150));
        expect(dictionaryPairSplit(200, 150, 160), (100, 100));
        expect(dictionaryPairSplit(-10, 50, 60), (0, 0));
      });
    });

    group('favourite', () {
      late MockHistoryCubit history;

      setUp(() => history = createDictionaryHistory());

      Finder heart() => find.byKey(const Key('dictionary_favorite'));

      IconButton heartButton(WidgetTester tester) =>
          tester.widget<IconButton>(heart());

      Future<void> pumpGato(WidgetTester tester, {bool withHistory = true}) =>
          pumpPage(
            tester,
            page: const DictionaryPage(
              word: 'gato',
              from: 'es',
              to: 'en',
              autoLookUp: true,
            ),
            history: withHistory ? history : null,
          );

      testWidgets('the look-up is saved and the heart sits beside Listen', (
        tester,
      ) async {
        await pumpPage(
          tester,
          page: const DictionaryPage(
            word: 'gato',
            from: 'es',
            to: 'en',
            autoLookUp: true,
          ),
          history: history,
          speech: speechService(),
        );
        await tester.pump();

        final saved =
            verify(() => history.add(captureAny())).captured.single
                as HistoryEntry;
        expect(saved.isDictionary, isTrue);
        expect(saved.text, 'gato');
        expect(saved.source.code, 'es');
        expect(saved.target.code, 'en');
        expect(saved.isFavorite, isFalse);

        expect(heart(), findsOneWidget);
        expect(heartButton(tester).tooltip, 'Add to favorites');
        expect(
          find.descendant(
            of: heart(),
            matching: find.byIcon(Icons.favorite_border_rounded),
          ),
          findsOneWidget,
        );
        final heartRect = tester.getRect(heart());
        final listen = tester.getRect(
          find.byKey(const Key('dictionary_listen')),
        );
        expect(heartRect.left, greaterThan(listen.right));
        expect(heartRect.center.dy, closeTo(listen.center.dy, 1));
        expect(tester.getSize(heart()), const Size.square(56));
      });

      testWidgets('adds the look-up as a favourite', (tester) async {
        await pumpGato(tester);
        await tester.pump();
        clearInteractions(history);

        await tester.tap(heart());
        await tester.pump();

        final favorite =
            verify(() => history.add(captureAny())).captured.single
                as HistoryEntry;
        expect(favorite.isFavorite, isTrue);
        expect(favorite.text, 'gato');
      });

      testWidgets('is filled for a favourite and takes it out', (tester) async {
        whenListen(
          history,
          Stream.fromIterable([
            HistoryState(
              status: HistoryStatus.ready,
              entries: [gatoLookUp(isFavorite: true)],
            ),
          ]),
          initialState: const HistoryState(status: HistoryStatus.ready),
        );
        await pumpGato(tester);
        await tester.pump();

        expect(heartButton(tester).tooltip, 'Remove from favorites');
        expect(
          find.descendant(
            of: heart(),
            matching: find.byIcon(Icons.favorite_rounded),
          ),
          findsOneWidget,
        );

        await tester.tap(heart());
        verify(() => history.toggleFavorite('dictionary:1')).called(1);
      });

      testWidgets('is left out while loading and after an error', (
        tester,
      ) async {
        final answer = Completer<DictionaryEntry>();
        stubLookUp(repository, () => answer.future);
        await pumpGato(tester);

        expect(heart(), findsNothing);

        answer.completeError(StateError('offline'));
        await tester.pump();
        await tester.pump();
        expect(find.byType(TranslateErrorView), findsOneWidget);
        expect(heart(), findsNothing);
      });

      testWidgets('is left out for an empty entry', (tester) async {
        stubLookUp(repository, () async => const DictionaryEntry(word: 'xq'));
        await pumpGato(tester);
        await tester.pump();

        expect(find.byKey(const Key('dictionary_not_found')), findsOneWidget);
        expect(heart(), findsNothing);
        verifyNever(() => history.add(any()));
      });

      testWidgets('is left out without a history', (tester) async {
        await pumpGato(tester, withHistory: false);
        await tester.pump();

        expect(find.byKey(const Key('dictionary_entry')), findsOneWidget);
        expect(heart(), findsNothing);
      });
    });

    group('look-up requests', () {
      late MockHistoryCubit history;

      setUp(() => history = createDictionaryHistory());

      /// The app's dictionary route above a History stand-in, starting
      /// there.
      Future<GoRouter> pumpRouter(WidgetTester tester) async {
        tester.view
          ..physicalSize = const Size(600, 1600)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        whenListen(
          translateCubit,
          const Stream<TranslateState>.empty(),
          initialState: _readyWithAi,
        );
        final router = GoRouter(
          initialLocation: '/history',
          routes: [
            GoRoute(
              path: '/dictionary',
              builder: (context, state) {
                final query = state.uri.queryParameters;
                return DictionaryPage(
                  key: ValueKey(state.uri.query),
                  word: query['word'],
                  from: query['from'],
                  to: query['to'],
                  autoLookUp: state.extra == DictionaryLaunch.lookUp,
                );
              },
            ),
            GoRoute(
              path: '/history',
              builder: (_, _) => const Scaffold(body: Text('History page')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          RepositoryProvider<TranslationRepository>.value(
            value: repository,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<TranslateCubit>.value(value: translateCubit),
                BlocProvider<SettingsCubit>.value(value: settingsCubit),
                BlocProvider<HistoryCubit>.value(value: history),
              ],
              child: MaterialApp.router(
                routerConfig: router,
                localizationsDelegates: appLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
              ),
            ),
          ),
        );
        return router;
      }

      void verifyGato(DictionaryVerbosity verbosity) => verify(
        () => repository.lookUp(
          claudeEngine,
          'gato',
          source: spanish,
          target: english,
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: verbosity,
        ),
      ).called(1);

      testWidgets('look the word up with their detail level', (tester) async {
        final router = await pumpRouter(tester);

        router.go(
          '/dictionary?word=gato&from=es&to=en',
          extra: DictionaryLookUpRequest(
            verbosity: DictionaryVerbosity.comprehensive,
          ),
        );
        await tester.pumpAndSettle();

        verifyGato(DictionaryVerbosity.comprehensive);
        expect(find.byKey(const Key('dictionary_entry')), findsOneWidget);
        expect(
          dictionaryState(tester).verbosity,
          DictionaryVerbosity.comprehensive,
        );
      });

      testWidgets("without a detail level keep the dictionary's", (
        tester,
      ) async {
        final router = await pumpRouter(tester);

        router.go(
          '/dictionary?word=gato&from=es&to=en',
          extra: DictionaryLookUpRequest(),
        );
        await tester.pumpAndSettle();

        verifyGato(DictionaryVerbosity.standard);
      });

      testWidgets('look up again on a kept page, once each', (tester) async {
        final router = await pumpRouter(tester);
        const location = '/dictionary?word=gato&from=es&to=en';
        router.go(location, extra: DictionaryLookUpRequest());
        await tester.pumpAndSettle();
        verifyGato(DictionaryVerbosity.standard);

        // The user moves on, then opens History and comes back.
        await tester.tap(find.byKey(const Key('dictionary_back')));
        await tester.pumpAndSettle();
        expect(dictionaryState(tester).status, DictionaryStatus.idle);
        unawaited(router.push<void>('/history'));
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
        // The request the page already applied is not applied again.
        verifyNoLookUp();
        expect(dictionaryState(tester).status, DictionaryStatus.idle);

        // History opens the same look-up again: the page is kept.
        unawaited(router.push<void>('/history'));
        await tester.pumpAndSettle();
        router.go(
          location,
          extra: DictionaryLookUpRequest(
            verbosity: DictionaryVerbosity.concise,
          ),
        );
        await tester.pumpAndSettle();

        verifyGato(DictionaryVerbosity.concise);
        final state = dictionaryState(tester);
        expect(state.status, DictionaryStatus.success);
        expect(state.word, 'gato');
        expect(state.lookedUp, 'gato');
        expect(find.byKey(const Key('dictionary_entry')), findsOneWidget);
      });

      testWidgets('other navigation extras are no requests', (tester) async {
        final router = await pumpRouter(tester);

        router.go('/dictionary?word=gato', extra: 'something else');
        await tester.pumpAndSettle();

        verifyNoLookUp();
        expect(DictionaryLookUpRequest().toString(), contains('null'));
        expect(
          DictionaryLookUpRequest(verbosity: DictionaryVerbosity.concise)
              .toString(),
          contains('concise'),
        );
      });
    });

    group('navigation', () {
      testWidgets('is a tab: History and Settings, no back arrow', (
        tester,
      ) async {
        final router = _MockGoRouter();
        when(router.canPop).thenReturn(false);
        await pumpPage(tester, router: router);

        expect(find.byType(TopLevelActions), findsOneWidget);
        expect(find.byType(BackButton), findsNothing);
        expect(find.byKey(const Key('dictionary_back')), findsNothing);
      });

      testWidgets('pushed above a page it has the usual back button', (
        tester,
      ) async {
        await tester.pumpApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MultiBlocProvider(
                    providers: [
                      BlocProvider<TranslateCubit>.value(value: translateCubit),
                      BlocProvider<SettingsCubit>.value(value: settingsCubit),
                    ],
                    child: RepositoryProvider<TranslationRepository>.value(
                      value: repository,
                      child: const DictionaryPage(word: 'gato'),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        );
        whenListen(
          translateCubit,
          const Stream<TranslateState>.empty(),
          initialState: _readyWithAi,
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.byType(BackButton), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byType(DictionaryPage), findsNothing);
      });
    });

    group('layout', () {
      testWidgets('centres the composer and the entry on wide screens', (
        tester,
      ) async {
        await pumpPage(
          tester,
          size: const Size(1200, 900),
          page: const DictionaryPage(word: 'gato'),
        );

        final composer = tester.getRect(
          find.byKey(const Key('dictionary_composer')),
        );
        expect(composer.center.dx, moreOrLessEquals(600, epsilon: 1));
        expect(composer.width, lessThanOrEqualTo(760));
        // The greeting sits right above the card.
        expect(
          composer.top - tester.getRect(find.byType(DictionaryHero)).bottom,
          lessThan(40),
        );

        await tester.tap(find.byKey(const Key('dictionary_look_up')));
        await tester.pump();
        await tester.pump();
        final entry = tester.getRect(find.byKey(const Key('dictionary_entry')));
        expect(entry.width, lessThanOrEqualTo(720));
        expect(entry.center.dx, moreOrLessEquals(600, epsilon: 1));
        expect(tester.takeException(), isNull);
      });

      testWidgets('fits a small phone at 200% text', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpPage(
          tester,
          size: const Size(320, 900),
          page: const DictionaryPage(word: 'Donaudampfschiff', from: 'de'),
          speechInput: FakeSpeechInput().service,
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('dictionary_hero')), findsOneWidget);
        final bar = tester.getRect(find.byKey(const Key('dictionary_bar')));
        expect(bar.right, lessThanOrEqualTo(320));
        expect(
          tester.getSize(buttonIn(const Key('dictionary_bar_source'))).height,
          greaterThanOrEqualTo(48),
        );
      });

      testWidgets('keeps the composer above the keyboard', (tester) async {
        tester.view.viewInsets = const FakeViewPadding(bottom: 600);
        addTearDown(tester.view.resetViewInsets);
        await pumpPage(tester);
        await tester.pumpAndSettle();

        final composer = tester.getRect(
          find.byKey(const Key('dictionary_composer')),
        );
        expect(composer.bottom, lessThanOrEqualTo(1600 - 600));
        // Still room for the greeting above it.
        expect(find.byKey(const Key('dictionary_hero')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('shows only the composer in a low window', (tester) async {
        await pumpPage(tester, size: const Size(600, 300));

        expect(find.byKey(const Key('dictionary_hero')), findsNothing);
        expect(find.byKey(const Key('dictionary_composer')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('mirrors in right-to-left languages', (tester) async {
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato'),
          direction: TextDirection.rtl,
        );

        final options = tester.getCenter(
          find.byKey(const Key('dictionary_options_button')),
        );
        final go = tester.getCenter(
          find.byKey(const Key('dictionary_look_up')),
        );
        expect(options.dx, greaterThan(go.dx));
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('picks up edited engines', (tester) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      await pumpPage(tester, stream: states.stream);

      states.add(_readyWithAi.copyWith(assistEngine: () => ollamaEngine));
      await tester.pump();
      expect(dictionaryState(tester).engine, ollamaEngine);

      states.add(_readyWithoutAi);
      await tester.pump();
      expect(dictionaryState(tester).engine, isNull);

      states.add(
        _readyWithoutAi.copyWith(engines: const [googleEngine, ollamaEngine]),
      );
      await tester.pump();
      expect(dictionaryState(tester).engine, ollamaEngine);
    });

    group('AI model chip', () {
      const withOllama = TranslateState(
        enginesStatus: EnginesStatus.ready,
        engines: [googleEngine, claudeEngine, ollamaEngine],
        engine: googleEngine,
        assistEngine: claudeEngine,
      );

      testWidgets('shows the model beside the title and picks another', (
        tester,
      ) async {
        final states = StreamController<TranslateState>();
        addTearDown(states.close);
        await pumpPage(
          tester,
          state: withOllama,
          stream: states.stream,
          size: const Size(1000, 900),
        );

        final chip = find.byKey(const Key('dictionary_engine_chip'));
        expect(chip, findsOneWidget);
        expect(find.text('Dictionary'), findsOneWidget);
        expect(
          find.descendant(of: chip, matching: find.text('Claude')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('composer_engine_chip')));
        await tester.pumpAndSettle();
        // Only the engines with AI extras.
        expect(
          find.byKey(const Key('composer_engine:mozhi:google')),
          findsNothing,
        );
        await tester.tap(find.byKey(const Key('composer_engine:ai:ollama')));
        await tester.pumpAndSettle();
        expect(dictionaryState(tester).engine, ollamaEngine);

        // Kept when the app's engines change.
        states.add(withOllama.copyWith(engine: () => claudeEngine));
        await tester.pump();
        expect(dictionaryState(tester).engine, ollamaEngine);
      });

      testWidgets('takes the place of the title on phones', (tester) async {
        await pumpPage(tester, size: const Size(400, 800));

        expect(find.byKey(const Key('dictionary_engine_chip')), findsOneWidget);
        expect(find.text('Dictionary'), findsNothing);
      });

      testWidgets('opens the AI provider settings', (tester) async {
        final router = _MockGoRouter();
        when(() => router.push<void>(any())).thenAnswer((_) async {});
        await pumpPage(tester, router: router);

        await tester.tap(find.byKey(const Key('composer_engine_chip')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('composer_engine_manage')));
        await tester.pumpAndSettle();
        verify(() => router.push<void>('/settings/providers')).called(1);
      });

      testWidgets('is left out without an AI engine', (tester) async {
        await pumpPage(tester, state: _readyWithoutAi);

        expect(find.byKey(const Key('dictionary_engine_chip')), findsNothing);
        expect(find.text('Dictionary'), findsOneWidget);
      });
    });
  });

  group('dictionaryUiLanguage', () {
    test('names the UI language in English', () {
      expect(dictionaryUiLanguage(const Locale('en', 'GB')), 'English');
      expect(dictionaryUiLanguage(const Locale('de')), 'German');
      expect(dictionaryUiLanguage(const Locale('qq')), 'English');
    });
  });

  group('dictionaryEngine', () {
    test('prefers the assist engine, then any engine with extras', () {
      expect(dictionaryEngine(_readyWithAi), claudeEngine);
      expect(dictionaryEngine(_readyWithoutAi), isNull);
      expect(
        dictionaryEngine(
          const TranslateState(engines: [googleEngine, ollamaEngine]),
        ),
        ollamaEngine,
      );
    });
  });

  group('dictionaryLanguageName', () {
    testWidgets('names auto "Detect language"', (tester) async {
      late String auto;
      late String spanishName;
      await tester.pumpApp(
        Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context);
            auto = dictionaryLanguageName(l10n, Language.auto);
            spanishName = dictionaryLanguageName(l10n, spanish);
            return const SizedBox();
          },
        ),
      );
      expect(auto, 'Detect language');
      expect(spanishName, 'Spanish');
    });
  });
}
