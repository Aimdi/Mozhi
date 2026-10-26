import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/dictionary/view/dictionary_page.dart'
    show DictionaryLaunch;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';
import 'package:mozhi/word_lookup/word_lookup.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _MockSpeechService extends Mock implements SpeechService;

class _MockGoRouter extends Mock implements GoRouter;

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class _MockPhrasebook extends Mock implements PhrasebookRepository;

const _consent = ConsentRequiredException(
  kind: ConsentKind.cloudProvider,
  destination: CloudProviderDestination('OpenAI'),
  engineId: 'ai:openai',
);

void main() {
  late _MockSpeechService speech;
  late MockTranslationRepository repository;
  late _MockSettingsCubit settings;
  late _MockGoRouter router;
  late FakeOfflineDictionary dictionary;
  late List<String?> copied;

  setUpAll(() {
    registerFallbackValue(english);
    registerFallbackValue(aiEngine);
    registerFallbackValue(DictionaryVerbosity.concise);
    registerFallbackValue(_consent);
    registerFallbackValue(
      const PhraseDraft(
        text: '',
        translation: '',
        sourceCode: '',
        targetCode: '',
      ),
    );
  });

  setUp(() {
    speech = _MockSpeechService();
    when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
    when(() => speech.current).thenReturn(null);
    when(
      () => speech.toggle(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
      ),
    ).thenAnswer((_) async {});
    repository = MockTranslationRepository();
    when(
      () => repository.lookUp(
        any(),
        any(),
        source: any(named: 'source'),
        target: any(named: 'target'),
        context: any(named: 'context'),
        uiLanguage: any(named: 'uiLanguage'),
        verbosity: any(named: 'verbosity'),
      ),
    ).thenAnswer((_) async => aiGatoEntry);
    settings = _MockSettingsCubit();
    when(() => settings.state).thenReturn(const AppSettings());
    router = _MockGoRouter();
    when(() => router.go(any(), extra: any(named: 'extra'))).thenReturn(null);
    dictionary = FakeOfflineDictionary();
    copied = [];
    final previous = ClipboardService.instance;
    ClipboardService.instance = ClipboardService(
      isAndroid: false,
      setData: (data) async => copied.add(data.text),
    );
    addTearDown(() => ClipboardService.instance = previous);
  });

  Widget app(Widget home, {PhrasebookRepository? phrasebook}) =>
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SpeechService>.value(value: speech),
          RepositoryProvider<TranslationRepository>.value(value: repository),
          if (phrasebook != null)
            RepositoryProvider<PhrasebookRepository>.value(value: phrasebook),
        ],
        child: BlocProvider<SettingsCubit>.value(
          value: settings,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: home),
          ),
        ),
      );

  Future<void> pumpSheet(
    WidgetTester tester, {
    String word = 'gato',
    Language? into = english,
    TranslationEngine? engine = aiEngine,
    GoRouter? router,
    DictionaryPacks? packs,
    PhrasebookRepository? phrasebook,
  }) async {
    await tester.pumpWidget(
      app(
        WordLookupSheet(
          service: WordLookupService(
            repository: repository,
            offlineDictionary: dictionary,
          ),
          word: word,
          language: spanish,
          into: into,
          sentence: 'El gato duerme.',
          engine: engine,
          router: router,
          packs: packs,
        ),
        phrasebook: phrasebook,
      ),
    );
    await tester.pump();
  }

  group('an offline entry', () {
    testWidgets('shows the headword, senses, translations and credit', (
      tester,
    ) async {
      await pumpSheet(tester);
      expect(find.text('gato'), findsOneWidget);
      expect(find.text('ˈɡato · noun'), findsOneWidget);
      expect(find.text('cat'), findsOneWidget);
      expect(find.text('English: cat, tomcat'), findsOneWidget);
      expect(find.text('jack (for lifting a car)'), findsOneWidget);
      expect(find.text('a dance'), findsNothing);
      expect(find.text('1 more meaning in the Dictionary'), findsOneWidget);
      expect(find.text('From Wiktionary · CC BY-SA 4.0'), findsOneWidget);
      expect(find.text('AI-generated'), findsNothing);
      expect(find.text('Look up with GPT Mini'), findsOneWidget);
      // Nothing went to the engine.
      verifyNever(
        () => repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          context: any(named: 'context'),
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      );
    });

    testWidgets('the headword is a header in its language', (tester) async {
      await pumpSheet(tester);
      final headword = tester.widget<Text>(
        find.byKey(const Key('word_lookup_headword')),
      );
      expect(headword.textDirection, TextDirection.ltr);
      expect((headword.textSpan! as TextSpan).locale, const Locale('es'));
      expect(
        tester.getSemantics(find.byKey(const Key('word_lookup_headword'))),
        matchesSemantics(isHeader: true, label: 'gato'),
      );
    });

    testWidgets('says which word an inflected form is of', (tester) async {
      await pumpSheet(tester, word: 'gatos');
      expect(find.text('“gatos” is a form of “gato”'), findsOneWidget);
    });

    testWidgets('without the other language, translations stand alone', (
      tester,
    ) async {
      await pumpSheet(tester, into: null);
      expect(find.text('cat, tomcat'), findsOneWidget);
    });

    testWidgets('an entry with nothing to show says so', (tester) async {
      dictionary.answers = {
        'gato': const OfflineDictionaryAnswer(
          entry: DictionaryEntry(word: 'gato'),
          language: 'es',
          attribution: wiktionary,
        ),
      };
      await pumpSheet(tester);
      expect(find.text('Nothing found for “gato”.'), findsOneWidget);
    });
  });

  group('a word the dictionaries miss', () {
    testWidgets('says so; "Look up with" asks the engine once', (tester) async {
      await pumpSheet(tester, word: 'perro');
      expect(
        find.text('“perro” isn’t in your offline dictionaries.'),
        findsOneWidget,
      );
      verifyNever(
        () => repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          context: any(named: 'context'),
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      );
      await tester.tap(find.text('Look up with GPT Mini'));
      await tester.pump();
      await tester.pump();
      verify(
        () => repository.lookUp(
          aiEngine,
          'perro',
          source: spanish,
          target: english,
          context: 'El gato duerme.',
          verbosity: DictionaryVerbosity.concise,
        ),
      ).called(1);
      expect(find.text('A small domesticated feline.'), findsOneWidget);
      expect(find.text('AI-generated'), findsOneWidget);
      expect(find.text('Look up with GPT Mini'), findsNothing);
    });

    testWidgets('shows progress while the engine looks it up', (tester) async {
      final gate = Completer<DictionaryEntry>();
      when(
        () => repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          context: any(named: 'context'),
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      ).thenAnswer((_) => gate.future);
      await pumpSheet(tester, word: 'perro');
      await tester.tap(find.text('Look up with GPT Mini'));
      await tester.pump();
      expect(find.byKey(const Key('word_lookup_progress')), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const Key('word_lookup_progress'))),
        matchesSemantics(label: 'Looking up “perro”…'),
      );
      gate.complete(const DictionaryEntry(word: 'perro'));
      await tester.pump();
      expect(find.text('Nothing found for “perro”.'), findsOneWidget);
    });

    testWidgets('without an engine: how to look up any word', (tester) async {
      await pumpSheet(tester, word: 'perro', engine: null);
      expect(
        find.text(
          'Your offline dictionaries don’t have it. Add an AI provider to '
          'look up any word.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('word_lookup_online')), findsNothing);
    });

    testWidgets('a consent prompt first, then the look-up', (tester) async {
      var calls = 0;
      when(
        () => repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          context: any(named: 'context'),
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      ).thenAnswer((_) async {
        if (calls++ == 0) throw _consent;
        return aiGatoEntry;
      });
      await pumpSheet(tester, word: 'perro');
      await tester.tap(find.text('Look up with GPT Mini'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('translate_error_consent')), findsOneWidget);
      await tester.tap(find.text('Allow'));
      await tester.pump();
      await tester.pump();
      verify(() => settings.consentToProvider('openai')).called(1);
      verify(() => repository.allowOnce(_consent)).called(1);
      expect(calls, 2);
      expect(find.text('A small domesticated feline.'), findsOneWidget);
    });

    testWidgets('an engine failure shows the error with Retry', (tester) async {
      when(
        () => repository.lookUp(
          any(),
          any(),
          source: any(named: 'source'),
          target: any(named: 'target'),
          context: any(named: 'context'),
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      ).thenThrow(Exception('boom'));
      await pumpSheet(tester, word: 'perro');
      await tester.tap(find.text('Look up with GPT Mini'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('word_lookup_error')), findsOneWidget);
      expect(find.text('Look up with GPT Mini'), findsOneWidget);
    });
  });

  group('no dictionary of the language', () {
    testWidgets('says so, with "Get dictionaries"', (tester) async {
      dictionary.languages = ['fr'];
      final packs = DictionaryPacks(
        catalog: DictionaryPackCatalog(const []),
        storage: MemoryDictionaryPackStorage(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(packs.close);
      await pumpSheet(tester, packs: packs);
      expect(
        find.text('No offline dictionary for Spanish is downloaded.'),
        findsOneWidget,
      );
      expect(find.text('Get dictionaries'), findsOneWidget);
      expect(dictionary.lookUps, isEmpty);
    });

    testWidgets('without packs to download, only says so', (tester) async {
      dictionary.languages = [];
      await pumpSheet(tester);
      expect(
        find.text('No offline dictionary for Spanish is downloaded.'),
        findsOneWidget,
      );
      expect(find.text('Get dictionaries'), findsNothing);
    });
  });

  group('actions', () {
    testWidgets('Listen reads the headword in its language', (tester) async {
      await pumpSheet(tester);
      expect(find.byTooltip('Listen to “gato”'), findsNothing);
      final listen = find.byType(ListenButton);
      expect(find.bySemanticsLabel('Listen to “gato”'), findsOneWidget);
      await tester.tap(listen);
      await tester.pump();
      verify(
        () => speech.toggle(
          id: wordLookupSpeechId,
          text: 'gato',
          languageCode: 'es',
        ),
      ).called(1);
    });

    testWidgets('Copy copies the headword', (tester) async {
      await pumpSheet(tester);
      await tester.tap(find.byTooltip('Copy “gato”'));
      await tester.pump();
      expect(copied, ['gato']);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('Open in Dictionary opens the tab with both languages', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => WordLookupSheet(
                  service: WordLookupService(offlineDictionary: dictionary),
                  word: 'gatos',
                  language: spanish,
                  into: english,
                  router: router,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Open in Dictionary'));
      await tester.tap(find.text('Open in Dictionary'));
      await tester.pumpAndSettle();
      verify(
        () => router.go(
          '/dictionary?word=gatos&from=es&to=en',
          extra: DictionaryLaunch.lookUp,
        ),
      ).called(1);
      expect(find.byKey(const Key('word_lookup_sheet')), findsNothing);
    });

    testWidgets('without a router there is no Open in Dictionary', (
      tester,
    ) async {
      await pumpSheet(tester);
      expect(find.text('Open in Dictionary'), findsNothing);
    });

    testWidgets('Add to phrasebook adds the word and its translation', (
      tester,
    ) async {
      final phrasebook = _MockPhrasebook();
      when(phrasebook.collections).thenAnswer((_) async => const []);
      when(phrasebook.lastCollectionId).thenAnswer((_) async => null);
      when(() => phrasebook.collectionsWith(any()))
          .thenAnswer((_) async => const {});
      await pumpSheet(tester, phrasebook: phrasebook);
      await tester.tap(find.text('Add to phrasebook…'));
      await tester.pumpAndSettle();
      final draft =
          verify(() => phrasebook.collectionsWith(captureAny())).captured.single
              as PhraseDraft;
      expect(draft.text, 'gato');
      expect(draft.translation, 'cat');
      expect(draft.sourceCode, 'es');
      expect(draft.targetCode, 'en');
      expect(draft.origin, PhraseOrigin.dictionary);
      expect(find.text('Add to phrasebook'), findsWidgets);
    });

    testWidgets('no Add to phrasebook without an entry', (tester) async {
      final phrasebook = _MockPhrasebook();
      await pumpSheet(tester, word: 'perro', phrasebook: phrasebook);
      expect(find.text('Add to phrasebook…'), findsNothing);
    });

    test('the phrase of an entry without translations is its summary', () {
      const state = WordLookupState(
        word: 'gato',
        language: spanish,
        status: WordLookupStatus.found,
        offlineAnswer: OfflineDictionaryAnswer(
          entry: DictionaryEntry(
            word: 'gato',
            senses: [DictionarySense(definition: 'cat', partOfSpeech: 'noun')],
          ),
          language: 'es',
          attribution: wiktionary,
        ),
      );
      final draft = WordLookupView.phraseDraftOf(state)!;
      expect(draft.translation, 'noun · cat');
      expect(draft.targetCode, Phrase.unknownLanguage);
    });
  });

  group('showWordLookupSheet', () {
    testWidgets('opens the card with the app’s engine and dictionaries', (
      tester,
    ) async {
      final translate = _MockTranslateCubit();
      when(() => translate.state)
          .thenReturn(const TranslateState(engines: [aiEngine]));
      final packs = DictionaryPacks(
        catalog: DictionaryPackCatalog(const []),
        storage: MemoryDictionaryPackStorage(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(packs.close);
      await tester.pumpWidget(
        RepositoryProvider<DictionaryPacks>.value(
          value: packs,
          child: BlocProvider<TranslateCubit>.value(
            value: translate,
            child: app(
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => unawaited(
                    lookUpWordAt(
                      context,
                      text: 'El gato duerme.',
                      offset: 4,
                      language: spanish,
                      into: english,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('word_lookup_sheet')), findsOneWidget);
      expect(find.text('gato'), findsOneWidget);
      expect(
        find.text('No offline dictionary for Spanish is downloaded.'),
        findsOneWidget,
      );
      expect(find.text('Look up with GPT Mini'), findsOneWidget);
      await tester.tap(find.text('Look up with GPT Mini'));
      await tester.pumpAndSettle();
      verify(
        () => repository.lookUp(
          aiEngine,
          'gato',
          source: spanish,
          target: english,
          context: 'El gato duerme.',
          verbosity: DictionaryVerbosity.concise,
        ),
      ).called(1);
    });

    testWidgets('nothing opens without a word at the position', (tester) async {
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                lookUpWordAt(
                  context,
                  text: 'El  gato',
                  offset: 3,
                  language: spanish,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('word_lookup_sheet')), findsNothing);
    });

    testWidgets('works without the app’s providers', (tester) async {
      await tester.pumpWidget(
        RepositoryProvider<SpeechService>.value(
          value: speech,
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => unawaited(
                    showWordLookupSheet(
                      context,
                      word: 'gato',
                      language: spanish,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.text('No offline dictionary for Spanish is downloaded.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('word_lookup_online')), findsNothing);
      expect(find.text('Open in Dictionary'), findsNothing);
    });
  });

  testWidgets('works in the dark theme and at 200% text', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SpeechService>.value(value: speech),
          RepositoryProvider<TranslationRepository>.value(value: repository),
        ],
        child: BlocProvider<SettingsCubit>.value(
          value: settings,
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.dark),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: WordLookupSheet(
                service: WordLookupService(offlineDictionary: dictionary),
                word: 'gato',
                language: spanish,
                into: english,
                engine: aiEngine,
                router: router,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Look up with GPT Mini'), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  });
}
