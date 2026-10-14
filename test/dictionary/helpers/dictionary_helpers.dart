import 'package:bloc_test/bloc_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
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
}
