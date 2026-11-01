import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/history/history.dart' show HistoryEntry, HistoryEntryKind;
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/dictionary_helpers.dart';
import '../helpers/offline_dictionary_helpers.dart';

void main() {
  setUpAll(registerDictionaryFallbacks);

  late MockTranslationRepository repository;
  late FakeOfflineDictionary offline;

  setUp(() {
    repository = MockTranslationRepository();
    offline = FakeOfflineDictionary();
    stubLookUp(repository, () async => gatoEntry);
  });

  DictionaryCubit build({
    TranslationEngine? engine = claudeEngine,
    String word = '',
    Language source = Language.auto,
    Language target = english,
    OfflineDictionary? dictionary,
    MockHistoryCubit? history,
    MockSettingsCubit? settings,
  }) => DictionaryCubit(
    repository: repository,
    engine: engine,
    word: word,
    source: source,
    target: target,
    offlineDictionary: dictionary ?? offline,
    history: history,
    settings: settings,
    clock: () => DateTime(2026, 10, 22),
  );

  void verifyAiLookUps(int times) => verify(
    () => repository.lookUp(
      any(),
      any(),
      source: any(named: 'source'),
      target: any(named: 'target'),
      uiLanguage: any(named: 'uiLanguage'),
      verbosity: any(named: 'verbosity'),
    ),
  ).called(times);

  void verifyNoAiLookUp() => verifyNever(
    () => repository.lookUp(
      any(),
      any(),
      source: any(named: 'source'),
      target: any(named: 'target'),
      uiLanguage: any(named: 'uiLanguage'),
      verbosity: any(named: 'verbosity'),
    ),
  );

  group('with offline dictionaries', () {
    test('reads their languages', () async {
      final cubit = build(engine: null, word: 'gato');
      expect(cubit.state.hasOfflineDictionaries, isFalse);
      await pumpEventQueue();
      expect(cubit.state.offlineLanguages, ['es']);
      expect(cubit.state.hasOfflineDictionaries, isTrue);
      expect(cubit.state.canLookUp, isTrue);
      expect(cubit.state.hasOfflineDictionaryFor(spanish), isTrue);
      expect(cubit.state.hasOfflineDictionaryFor(french), isFalse);
      expect(cubit.state.hasOfflineDictionaryFor(Language.auto), isTrue);
      offline.install(['es', 'fr']);
      await pumpEventQueue();
      expect(cubit.state.offlineLanguages, ['es', 'fr']);
      await cubit.close();
    });

    test('no languages when they cannot be read', () async {
      offline.error = StateError('unreadable');
      final cubit = build();
      await pumpEventQueue();
      expect(cubit.state.hasOfflineDictionaries, isFalse);
      await cubit.close();
    });

    blocTest<DictionaryCubit, DictionaryState>(
      'answers from a dictionary without AI',
      build: () => build(word: 'gato'),
      act: (cubit) => cubit.lookUp(),
      skip: 1,
      expect: () => [
        isA<DictionaryState>()
            .having((s) => s.status, 'status', DictionaryStatus.loading)
            .having((s) => s.lookedUp, 'lookedUp', 'gato'),
        isA<DictionaryState>()
            .having((s) => s.status, 'status', DictionaryStatus.success)
            .having((s) => s.entry, 'entry', gatoPackEntry)
            .having((s) => s.offlineAnswer, 'offlineAnswer', gatoAnswer)
            .having((s) => s.isOfflineEntry, 'isOfflineEntry', isTrue)
            .having((s) => s.entryLanguage, 'entryLanguage', 'es'),
      ],
      verify: (_) {
        verifyNoAiLookUp();
        expect(offline.lookUps, [(word: 'gato', language: null, target: 'en')]);
      },
    );

    test('looks up in the dictionary of the chosen language', () async {
      final cubit = build(word: 'gato', source: spanish, target: french);
      await cubit.lookUp();
      expect(offline.lookUps.single, (
        word: 'gato',
        language: 'es',
        target: 'fr',
      ));
      expect(cubit.state.entryLanguage, 'es');
      await cubit.close();
    });

    test('asks the AI engine when the dictionaries miss', () async {
      final cubit = build(word: 'perro');
      await cubit.lookUp();
      verifyAiLookUps(1);
      expect(cubit.state.status, DictionaryStatus.success);
      expect(cubit.state.entry, gatoEntry);
      expect(cubit.state.offlineAnswer, isNull);
      await cubit.close();
    });

    test('a failing dictionary counts as a miss', () async {
      final cubit = build(word: 'gato');
      await pumpEventQueue();
      offline.error = StateError('damaged');
      await cubit.lookUp();
      verifyAiLookUps(1);
      expect(cubit.state.entry, gatoEntry);
      await cubit.close();
    });

    test('without AI, a miss suggests similar words', () async {
      offline.suggestions = {
        'gatt': ['gato', 'gatos'],
      };
      final cubit = build(engine: null, word: 'gatto');
      await cubit.lookUp();
      verifyNoAiLookUp();
      expect(cubit.state.status, DictionaryStatus.success);
      expect(cubit.state.entry, isNull);
      expect(cubit.state.suggestions, ['gato', 'gatos']);
      // The word itself first, then without its last letter.
      expect(
        [for (final call in offline.suggested) call.prefix],
        ['gatto', 'gatt'],
      );
      // A new look-up clears them.
      cubit.setWord('gato');
      await cubit.lookUp();
      expect(cubit.state.suggestions, isEmpty);
      await cubit.close();
    });

    test('suggestions leave out the word and failures', () async {
      offline.suggestions = {
        'ga': ['ga', 'gato'],
      };
      final cubit = build(engine: null, word: 'ga', source: spanish);
      await cubit.lookUp();
      expect(cubit.state.suggestions, ['gato']);
      expect(offline.suggested.single.language, 'es');
      offline
        ..answers = {}
        ..suggestions = {};
      cubit.setWord('xy');
      await cubit.lookUp();
      expect(cubit.state.suggestions, isEmpty);
      await pumpEventQueue();
      final failing = FakeOfflineDictionary(answers: {});
      final other = build(engine: null, word: 'gatto', dictionary: failing);
      await pumpEventQueue();
      failing.error = StateError('gone');
      await other.lookUp();
      expect(other.state.suggestions, isEmpty);
      await cubit.close();
      await other.close();
    });

    test('moreDetail asks the AI about the shown word', () async {
      final cubit = build(word: 'gatos');
      await cubit.lookUp();
      expect(cubit.state.offlineAnswer, gatosAnswer);
      await cubit.moreDetail();
      verify(
        () => repository.lookUp(
          claudeEngine,
          'gatos',
          source: Language.auto,
          target: english,
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      ).called(1);
      expect(cubit.state.entry, gatoEntry);
      expect(cubit.state.offlineAnswer, isNull);
      await cubit.close();
    });

    test('moreDetail needs an engine and a word', () async {
      final cubit = build(engine: null, word: 'gato');
      await cubit.moreDetail();
      final empty = build();
      await empty.moreDetail();
      verifyNoAiLookUp();
      await cubit.close();
      await empty.close();
    });

    test('retry repeats the AI request after More detail', () async {
      final cubit = build(word: 'gato');
      await cubit.lookUp();
      stubLookUp(repository, () async => throw StateError('offline'));
      await cubit.moreDetail();
      expect(cubit.state.status, DictionaryStatus.failure);
      stubLookUp(repository, () async => gatoEntry);
      await cubit.retry();
      expect(cubit.state.entry, gatoEntry);
      expect(cubit.state.offlineAnswer, isNull);
      verifyAiLookUps(2);
      await cubit.close();
    });

    test('retry of an offline look-up looks up again', () async {
      final cubit = build(word: 'gato');
      await cubit.lookUp();
      await cubit.retry();
      expect(offline.lookUps, hasLength(2));
      verifyNoAiLookUp();
      await cubit.close();
    });

    test('the detail level only refreshes an AI entry', () async {
      final cubit = build(word: 'gato');
      await cubit.lookUp();
      await cubit.setVerbosity(DictionaryVerbosity.comprehensive);
      verifyNoAiLookUp();
      await cubit.moreDetail();
      verifyAiLookUps(1);
      await cubit.setVerbosity(DictionaryVerbosity.concise);
      verifyAiLookUps(1);
      await cubit.close();
    });

    test('picking an engine only refreshes an AI entry', () async {
      final cubit = build(word: 'gato');
      await cubit.lookUp();
      cubit.pickEngine(ollamaEngine);
      await pumpEventQueue();
      verifyNoAiLookUp();
      expect(cubit.state.offlineAnswer, gatoAnswer);
      await cubit.moreDetail();
      verifyAiLookUps(1);
      cubit.pickEngine(claudeEngine);
      await pumpEventQueue();
      verify(
        () => repository.lookUp(
          claudeEngine,
          'gato',
          source: any(named: 'source'),
          target: any(named: 'target'),
          uiLanguage: any(named: 'uiLanguage'),
          verbosity: any(named: 'verbosity'),
        ),
      ).called(1);
      await cubit.close();
    });

    test('a language change looks up again, also without AI', () async {
      final cubit = build(engine: null, word: 'gato');
      await cubit.lookUp();
      cubit.setSource(spanish);
      await pumpEventQueue();
      expect(offline.lookUps, hasLength(2));
      expect(offline.lookUps.last.language, 'es');
      await cubit.close();
    });

    test('a waiting look-up runs once a dictionary is installed', () async {
      offline.languages = [];
      final cubit = build(engine: null, word: 'gato');
      await cubit.lookUp();
      expect(offline.lookUps, isEmpty);
      offline.install(['es']);
      await pumpEventQueue();
      expect(offline.lookUps, hasLength(1));
      expect(cubit.state.offlineAnswer, gatoAnswer);
      await cubit.close();
    });

    test('ignores an answer that arrives after a new request', () async {
      final cubit = build(word: 'gato');
      await pumpEventQueue();
      offline.gate = Completer<void>();
      final first = cubit.lookUp();
      await pumpEventQueue();
      cubit.clear();
      offline.gate!.complete();
      await first;
      expect(cubit.state.status, DictionaryStatus.idle);
      expect(cubit.state.entry, isNull);
      await cubit.close();
    });

    test("saves look-ups to the history as the dictionary's", () async {
      final history = createDictionaryHistory();
      final settings = MockSettingsCubit();
      when(() => settings.state).thenReturn(const AppSettings());
      final cubit = build(word: 'gato', history: history, settings: settings);
      await cubit.lookUp();
      final saved =
          verify(() => history.add(captureAny())).captured.single
              as HistoryEntry;
      expect(saved.kind, HistoryEntryKind.dictionary);
      expect(saved.engineId, DictionaryCubit.offlineEngineId);
      expect(saved.engineName, 'Wiktionary');
      expect(saved.translation, 'noun · cat');
      await cubit.toggleFavorite();
      verify(() => history.add(any())).called(1);
      await cubit.close();
    });

    test('the offline engine is named after the source', () {
      expect(DictionaryCubit.offlineEngine(wiktionary).name, 'Wiktionary');
      expect(
        DictionaryCubit.offlineEngine(
          const DictionaryAttribution(source: ' ', license: 'L'),
        ).name,
        'Offline dictionary',
      );
      // The cubit passes the name in the UI language.
      expect(
        DictionaryCubit.offlineEngine(
          const DictionaryAttribution(source: '', license: 'L'),
          name: 'Offline-Wörterbuch',
        ).name,
        'Offline-Wörterbuch',
      );
      expect(
        DictionaryCubit.offlineEngine(wiktionary, name: 'x').name,
        'Wiktionary',
      );
      expect(DictionaryCubit.offlineEngine(wiktionary).isOffline, isTrue);
    });

    test('clear and closeEntry drop the offline answer', () async {
      final cubit = build(word: 'gato');
      await cubit.lookUp();
      cubit.closeEntry();
      expect(cubit.state.offlineAnswer, isNull);
      await cubit.lookUp();
      cubit.clear();
      expect(cubit.state.offlineAnswer, isNull);
      expect(cubit.state.suggestions, isEmpty);
      await cubit.close();
    });

    test('an empty answer is not saved', () async {
      final history = createDictionaryHistory();
      final settings = MockSettingsCubit();
      when(() => settings.state).thenReturn(const AppSettings());
      offline.answers = {
        'gato': const OfflineDictionaryAnswer(
          entry: DictionaryEntry(word: 'gato'),
          language: 'es',
          attribution: wiktionary,
        ),
      };
      final cubit = build(word: 'gato', history: history, settings: settings);
      await cubit.lookUp();
      expect(cubit.state.isEmptyEntry, isTrue);
      verifyNever(() => history.add(any()));
      await cubit.close();
    });

    test('a look-up after closing does nothing', () async {
      final cubit = build(word: 'gato');
      await cubit.close();
      await cubit.lookUp();
      expect(offline.lookUps, isEmpty);
    });
  });
}
