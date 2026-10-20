import 'package:bloc_test/bloc_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockUsageTracker extends Mock implements UsageTracker;

class MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class MockSettingsCubit extends MockCubit<AppSettings> implements SettingsCubit;

class MockDictionaryCubit extends MockCubit<DictionaryState>
    implements DictionaryCubit;

class MockHistoryCubit extends MockCubit<HistoryState> implements HistoryCubit;

/// A [MockHistoryCubit] with [state] whose changes succeed.
MockHistoryCubit createDictionaryHistory([
  HistoryState state = const HistoryState(status: HistoryStatus.ready),
]) {
  final history = MockHistoryCubit();
  when(() => history.state).thenReturn(state);
  when(() => history.add(any())).thenAnswer((_) async {});
  when(() => history.toggleFavorite(any())).thenAnswer((_) async {});
  return history;
}

/// The history entry of a look-up of `gato` ([gatoEntry]) from Spanish
/// into English with Claude.
HistoryEntry gatoLookUp({
  String id = 'dictionary:1',
  bool isFavorite = false,
  Language source = spanish,
  Language target = english,
}) => HistoryEntry(
  id: id,
  kind: HistoryEntryKind.dictionary,
  text: 'gato',
  translation: 'noun · A small domesticated feline.',
  source: source,
  target: target,
  engineId: claudeEngine.id,
  engineName: claudeEngine.name,
  createdAt: DateTime(2026, 10, 20),
  verbosity: DictionaryVerbosity.standard,
  isFavorite: isFavorite,
);

const english = Language(code: 'en', name: 'English');
const spanish = Language(code: 'es', name: 'Spanish', nativeName: 'Español');
const french = Language(code: 'fr', name: 'French', nativeName: 'Français');

const claudeEngine = TranslationEngine(
  id: 'ai:claude',
  kind: EngineKind.ai,
  name: 'Claude',
  providerId: 'claude',
);
const ollamaEngine = TranslationEngine(
  id: 'ai:ollama',
  kind: EngineKind.ai,
  name: 'Ollama',
  isLocal: true,
);
const googleEngine = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
);

const gatoEntry = DictionaryEntry(
  word: 'gato',
  pronunciation: 'ˈɡato',
  partsOfSpeech: ['noun'],
  senses: [
    DictionarySense(
      definition: 'A small domesticated feline.',
      partOfSpeech: 'noun',
      translations: ['cat'],
      usage: 'common',
    ),
  ],
  examples: [
    DictionaryExample(
      source: 'El gato duerme.',
      translation: 'The cat sleeps.',
    ),
  ],
  synonyms: ['minino'],
  etymology: 'From Late Latin cattus.',
  notes: 'Also a car jack.',
);

void stubLookUp(
  MockTranslationRepository repository,
  Future<DictionaryEntry> Function() answer,
) {
  when(
    () => repository.lookUp(
      any(),
      any(),
      source: any(named: 'source'),
      target: any(named: 'target'),
      uiLanguage: any(named: 'uiLanguage'),
      verbosity: any(named: 'verbosity'),
    ),
  ).thenAnswer((_) => answer());
}

void registerDictionaryFallbacks() {
  registerFallbackValue(claudeEngine);
  registerFallbackValue(english);
  registerFallbackValue(DictionaryVerbosity.standard);
  registerFallbackValue(gatoLookUp());
}
