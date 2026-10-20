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
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/dictionary_card.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';
import '../helpers/dictionary_helpers.dart';

class _MockGoRouter extends Mock implements GoRouter;

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
      ],
      child: page,
    );
    if (withTracker) {
      tree = RepositoryProvider<UsageTracker>.value(
        value: tracker,
        child: tree,
      );
    }
    tree = RepositoryProvider<TranslationRepository>.value(
      value: repository,
      child: tree,
    );
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

  /// The focus node of the button [button].
  FocusNode focusOf(WidgetTester tester, Finder button) => Focus.of(
    tester.element(find.descendant(of: button, matching: find.byType(Icon))),
  );

  group('DictionaryPage', () {
    testWidgets('shows the hero above the search and the engine', (
      tester,
    ) async {
      await pumpPage(tester);

      expect(find.byKey(const Key('dictionary_empty')), findsOneWidget);
      expect(find.byKey(const Key('dictionary_hero')), findsOneWidget);
      expect(find.text('What does this mean?'), findsOneWidget);
      expect(
        find.text(
          'See definitions, pronunciation, examples and translations, '
          'written by your AI provider.',
        ),
        findsOneWidget,
      );
      // The hero says it all: no second empty message below the search.
      expect(find.text('Look up any word'), findsNothing);
      expect(
        tester.getCenter(find.text('What does this mean?')).dy,
        lessThan(
          tester.getCenter(find.byKey(const Key('dictionary_search_field'))).dy,
        ),
      );
      expect(find.text('Dictionary entries by Claude'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('dictionary_search_field')),
      );
      expect(field.autofocus, isTrue);
      final state = dictionaryState(tester);
      expect(state.engine, claudeEngine);
      expect(state.source, Language.auto);
      expect(state.target, LanguageCatalog.byCode('en'));
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
      expect(find.byType(DictionaryEntryView), findsOneWidget);
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

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      verifyNoLookUp();

      states.add(_readyWithAi);
      await tester.pump();
      await tester.pump();

      verifyLookUps(1);
      expect(find.byType(DictionaryEntryView), findsOneWidget);
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
        expect(isSelected(tester, DictionaryVerbosity.standard), isTrue);

        // The selected level is not requested again.
        await tester.tap(verbosityChip(DictionaryVerbosity.standard));
        await tester.pump();
        verifyNoLookUp();

        await tester.tap(verbosityChip(DictionaryVerbosity.concise));
        await tester.pump();
        await tester.pump();

        verifyLookUp('gato', verbosity: DictionaryVerbosity.concise);
        expect(find.byKey(const Key('dictionary_entry')), findsOneWidget);
      });
    });

    group('entry links', () {
      testWidgets('related words look that word up', (tester) async {
        stubLookUp(
          repository,
          () async => const DictionaryEntry(
            word: 'gato',
            senses: [DictionarySense(definition: 'A cat.')],
            relatedWords: ['felino', ' ', 'gatito'],
          ),
        );
        await pumpPage(
          tester,
          page: const DictionaryPage(word: 'gato', autoLookUp: true),
        );
        await tester.pump();
        verifyLookUp('gato');

        expect(find.text('Related words'), findsOneWidget);
        expect(find.byType(ActionChip), findsNWidgets(2));
        final chip = find.byKey(
          const ValueKey('translate_dictionary_related:gatito'),
        );
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pump();
        await tester.pump();

        verifyLookUp('gatito');
        final state = dictionaryState(tester);
        expect(state.word, 'gatito');
        expect(state.lookedUp, 'gatito');
        final field = tester.widget<TextField>(
          find.byKey(const Key('dictionary_search_field')),
        );
        expect(field.controller!.text, 'gatito');
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

        final link = find.byKey(const Key('translate_dictionary_did_you_mean'));
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
    });

    group('without an AI engine', () {
      testWidgets('links to the AI provider settings', (tester) async {
        final router = _MockGoRouter();
        when(router.canPop).thenReturn(true);
        when(() => router.push<void>(any())).thenAnswer((_) async {});
        await pumpPage(tester, state: _readyWithoutAi, router: router);
        // The hero stays above the search.
        expect(find.text('What does this mean?'), findsOneWidget);

        expect(find.byKey(const Key('dictionary_no_engine')), findsOneWidget);
        expect(
          find.text('The dictionary needs an AI provider'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('dictionary_engine')), findsNothing);
        final lookUp = tester.widget<IconButton>(
          find.byKey(const Key('dictionary_look_up')),
        );
        expect(lookUp.onPressed, isNull);

        await tester.tap(find.text('Add AI provider'));
        // Above the tabs: back returns to the dictionary.
        verify(() => router.push<void>('/settings/providers')).called(1);
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
      stubLookUp(repository, () async => gatoEntry);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(DictionaryEntryView), findsOneWidget);
    });

    testWidgets('says when there is no entry', (tester) async {
      stubLookUp(repository, () async => const DictionaryEntry(word: 'qwz'));
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'qwz', autoLookUp: true),
      );
      await tester.pump();

      expect(find.text('No dictionary entry found for “qwz”.'), findsOneWidget);
    });

    testWidgets('shows progress while looking up', (tester) async {
      final pending = Completer<DictionaryEntry>();
      stubLookUp(repository, () => pending.future);
      await pumpPage(
        tester,
        page: const DictionaryPage(word: 'gato', autoLookUp: true),
      );

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      pending.complete(gatoEntry);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    group('search field', () {
      testWidgets('looks up on Enter and clears', (tester) async {
        await pumpPage(tester);

        await tester.enterText(
          find.byKey(const Key('dictionary_search_field')),
          'gato',
        );
        await tester.pump();
        expect(dictionaryState(tester).word, 'gato');

        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        await tester.pump();
        verifyLookUps(1);
        expect(find.byType(DictionaryEntryView), findsOneWidget);
        expect(find.byKey(const Key('dictionary_hero')), findsNothing);

        await tester.tap(find.byKey(const Key('dictionary_clear')));
        await tester.pump();
        expect(dictionaryState(tester).word, isEmpty);
        expect(find.byKey(const Key('dictionary_clear')), findsNothing);
        expect(find.byKey(const Key('dictionary_empty')), findsOneWidget);
        expect(find.byKey(const Key('dictionary_hero')), findsOneWidget);
        final field = tester.widget<TextField>(
          find.byKey(const Key('dictionary_search_field')),
        );
        expect(field.controller!.text, isEmpty);
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

      testWidgets('clearing moves keyboard focus to the field', (tester) async {
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
        expect(
          tester.widget<EditableText>(searchEditable()).focusNode,
          same(FocusManager.instance.primaryFocus),
        );
      });

      testWidgets('Look up keeps keyboard focus on the button', (tester) async {
        await pumpPage(tester, page: const DictionaryPage(word: 'gato'));

        final lookUp = focusOf(
          tester,
          find.byKey(const Key('dictionary_look_up')),
        )..requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump();

        verifyLookUps(1);
        expect(lookUp.hasPrimaryFocus, isTrue);
      });

      testWidgets('Enter keeps focus in the field and hides the keyboard', (
        tester,
      ) async {
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
        expect(
          tester
              .widget<EditableText>(searchEditable())
              .focusNode
              .hasPrimaryFocus,
          isTrue,
        );
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
    });

    group('languages', () {
      testWidgets('picks the word language from a searchable list', (
        tester,
      ) async {
        await pumpPage(tester, page: const DictionaryPage(word: 'gato'));

        final swap = find.byKey(const Key('dictionary_swap'));
        expect(tester.widget<IconButton>(swap).onPressed, isNull);

        await tester.tap(find.byKey(const Key('dictionary_source_language')));
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
        expect(tester.widget<IconButton>(swap).onPressed, isNotNull);
        verifyNoLookUp();

        await tester.tap(swap);
        await tester.pump();
        final state = dictionaryState(tester);
        expect(state.source.code, 'en');
        expect(state.target.code, 'es');
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

        await tester.tap(find.byKey(const Key('dictionary_source_language')));
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

        await tester.tap(find.byKey(const Key('dictionary_source_language')));
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

        await tester.tap(find.byKey(const Key('dictionary_target_language')));
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

        await tester.tap(find.byKey(const Key('dictionary_target_language')));
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
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
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

    testWidgets('shows search and entry side by side on wide screens', (
      tester,
    ) async {
      await pumpPage(
        tester,
        size: const Size(1200, 900),
        page: const DictionaryPage(word: 'gato', autoLookUp: true),
      );
      await tester.pump();

      final field = tester.getRect(
        find.byKey(const Key('dictionary_search_field')),
      );
      final entry = tester.getRect(find.byKey(const Key('dictionary_entry')));
      expect(entry.left, greaterThan(field.right));
      expect(tester.takeException(), isNull);
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
