import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/dictionary/data/dictionary_entry_store.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/dictionary_helpers.dart';

void main() {
  setUpAll(registerDictionaryFallbacks);

  late MockTranslationRepository repository;
  late MockHistoryCubit history;
  late MockSettingsCubit settings;
  final now = DateTime(2026, 10, 20, 9, 30);
  var calls = 0;

  setUp(() {
    calls = 0;
    repository = MockTranslationRepository();
    stubLookUp(repository, () async {
      calls++;
      return gatoEntry;
    });
    history = createDictionaryHistory();
    settings = MockSettingsCubit();
    when(() => settings.state).thenReturn(const AppSettings());
  });

  DictionaryCubit build({
    String word = 'gato',
    Language source = spanish,
    Future<String?> Function(String text)? identify,
  }) => DictionaryCubit(
    repository: repository,
    engine: claudeEngine,
    word: word,
    source: source,
    history: history,
    settings: settings,
    identifyLanguage: identify,
    clock: () => now,
  );

  int lookUps() => calls;

  HistoryEntry saved({String? json, Language source = spanish}) => HistoryEntry(
    id: 'dictionary:1',
    kind: HistoryEntryKind.dictionary,
    text: 'gato',
    translation: 'noun · A small domesticated feline.',
    source: source,
    target: french,
    engineId: 'ai:other',
    engineName: 'Other',
    createdAt: DateTime(2026),
    verbosity: DictionaryVerbosity.comprehensive,
    dictionaryJson: json,
  );

  group('openSaved', () {
    test('shows the kept entry without asking the AI', () async {
      final cubit = build(word: '');
      await cubit.openSaved(saved(json: encodeDictionaryEntry(gatoEntry)));
      expect(cubit.state.status, DictionaryStatus.success);
      expect(cubit.state.entry, gatoEntry);
      expect(cubit.state.saved, isTrue);
      expect(cubit.state.lookedUp, 'gato');
      expect(cubit.state.word, 'gato');
      expect(cubit.state.target, french);
      expect(cubit.state.verbosity, DictionaryVerbosity.comprehensive);
      expect(cubit.state.entryLanguage, 'es');
      expect(lookUps(), 0);
      verifyNever(() => history.add(any()));

      // Starring it keeps the entry and its engine.
      await cubit.toggleFavorite();
      final starred =
          verify(() => history.add(captureAny())).captured.single
              as HistoryEntry;
      expect(starred.isFavorite, isTrue);
      expect(starred.engineId, 'ai:other');
      expect(decodeDictionaryEntry(starred.dictionaryJson), gatoEntry);
    });

    test('Refresh asks the AI again', () async {
      final cubit = build(word: '');
      await cubit.openSaved(saved(json: encodeDictionaryEntry(gatoEntry)));
      await cubit.refresh();
      expect(lookUps(), 1);
      expect(cubit.state.saved, isFalse);
      expect(cubit.state.status, DictionaryStatus.success);
    });

    test('a detected word has its detected language', () async {
      final cubit = build(word: '', source: Language.auto);
      await cubit.openSaved(
        HistoryEntry(
          id: 'dictionary:1',
          kind: HistoryEntryKind.dictionary,
          text: 'gato',
          translation: '',
          source: Language.auto,
          target: english,
          engineId: 'ai:claude',
          engineName: 'Claude',
          createdAt: DateTime(2026),
          detectedSource: 'es',
          dictionaryJson: encodeDictionaryEntry(gatoEntry),
        ),
      );
      expect(cubit.state.entryLanguage, 'es');
    });

    test('a look-up kept without its entry is looked up again', () async {
      final cubit = build(word: '');
      await cubit.openSaved(saved());
      expect(lookUps(), 1);
      expect(cubit.state.saved, isFalse);
      expect(cubit.state.target, french);
    });

    test('Refresh does nothing without a word', () async {
      await build(word: '').refresh();
      expect(lookUps(), 0);
    });
  });

  group('the AI entries kept in memory', () {
    test('looking the same word up again asks once', () async {
      final cubit = build();
      await cubit.lookUp();
      expect(cubit.state.saved, isFalse);
      await cubit.lookUp();
      expect(lookUps(), 1);
      expect(cubit.state.entry, gatoEntry);
      expect(cubit.state.saved, isTrue);
      // Another page of the same repository reuses it too.
      await build().lookUp();
      expect(lookUps(), 1);
    });

    test('are not kept in incognito', () async {
      when(() => settings.state).thenReturn(const AppSettings(incognito: true));
      final cubit = build();
      await cubit.lookUp();
      await cubit.lookUp();
      expect(lookUps(), 2);
    });

    test('empty entries are not kept', () async {
      stubLookUp(repository, () async {
        calls++;
        return const DictionaryEntry(word: 'xq');
      });
      final cubit = build(word: 'xq');
      await cubit.lookUp();
      await cubit.lookUp();
      expect(lookUps(), 2);
    });
  });

  group('the history', () {
    test('keeps the language a detected word was found in', () async {
      final cubit = build(source: Language.auto, identify: (_) async => 'es');
      await cubit.lookUp();
      await Future<void>.delayed(Duration.zero);
      final entry =
          verify(() => history.add(captureAny())).captured.single
              as HistoryEntry;
      expect(entry.detectedSource, 'es');
      expect(cubit.state.entryLanguage, 'es');
    });

    test('keeps no language for an unknown one', () async {
      final cubit = build(source: Language.auto, identify: (_) async => 'zz');
      await cubit.lookUp();
      await Future<void>.delayed(Duration.zero);
      final entry =
          verify(() => history.add(captureAny())).captured.single
              as HistoryEntry;
      expect(entry.detectedSource, isNull);
    });
  });

  group('remembers the languages the user chose', () {
    test('word, translations and swap', () {
      final cubit = build()..setTarget(french);
      verify(
        () => settings.setDictionaryLanguages(source: spanish, target: french),
      ).called(1);
      cubit.setSource(english);
      verify(
        () => settings.setDictionaryLanguages(source: english, target: french),
      ).called(1);
      cubit.swap();
      verify(
        () => settings.setDictionaryLanguages(source: french, target: english),
      ).called(1);
    });

    test('not for a look-up opened from elsewhere', () async {
      await build().open('chat', source: french, target: spanish);
      verifyNever(
        () => settings.setDictionaryLanguages(
          source: any(named: 'source'),
          target: any(named: 'target'),
        ),
      );
    });
  });
}
