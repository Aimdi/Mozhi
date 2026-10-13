import 'package:bloc_test/bloc_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockSettingsCubit extends MockCubit<AppSettings> implements SettingsCubit;

class MockHistoryCubit extends MockCubit<HistoryState> implements HistoryCubit;

const google = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  mozhiEngine: 'google',
);
const deepl = TranslationEngine(
  id: 'mozhi:deepl',
  kind: EngineKind.mozhi,
  name: 'DeepL',
  mozhiEngine: 'deepl',
);
const claude = TranslationEngine(
  id: 'ai:claude',
  kind: EngineKind.ai,
  name: 'Claude',
  providerId: 'claude',
);
const local = TranslationEngine(
  id: 'ai:local',
  kind: EngineKind.ai,
  name: 'Local',
  providerId: 'local',
  isLocal: true,
);

const en = Language(code: 'en', name: 'English');
const de = Language(code: 'de', name: 'German');
const fr = Language(code: 'fr', name: 'French');
const es = Language(code: 'es', name: 'Spanish');
const ja = Language(code: 'ja', name: 'Japanese');
const pirate = Language.custom('Pirate speak');

const List<Language> sources = [Language.auto, en, de, fr, es];
const List<Language> targets = [en, de, fr, es];
const List<TranslationEngine> allEngines = [google, deepl, claude];

const fastDebounce = Duration(milliseconds: 20);
const fastAiDebounce = Duration(milliseconds: 40);

/// Long enough for either debounce to fire.
const afterDebounce = Duration(milliseconds: 120);

TranslationResult resultOf(
  String text, {
  TranslationEngine engine = google,
  String? detected,
  bool isComplete = true,
}) => TranslationResult(
  engineId: engine.id,
  engineName: engine.name,
  text: text,
  detectedSource: detected,
  isComplete: isComplete,
);

/// A loaded state: engines ready, Google selected, Claude as assist.
TranslateState readyState({
  TranslationEngine engine = google,
  TranslationEngine? assistEngine = claude,
  List<TranslationEngine> engines = allEngines,
  String input = '',
  Language source = Language.auto,
  Language target = en,
  TranslationResult? result,
  String? resultInput,
  TranslateStatus status = TranslateStatus.idle,
  TranslationOptions options = const TranslationOptions(),
}) => TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: engines,
  engine: engine,
  assistEngine: assistEngine,
  sourceLanguages: sources,
  targetLanguages: targets,
  source: source,
  target: target,
  input: input,
  result: result,
  // A result belongs to the input unless said otherwise.
  resultInput: resultInput ?? (result == null ? null : input),
  status: status,
  options: options,
);

/// Registers mocktail fallback values used by `any()`.
void registerTranslateFallbacks() {
  registerFallbackValue(google);
  registerFallbackValue(
    const TranslationRequest(text: '', source: en, target: de),
  );
  registerFallbackValue(en);
  registerFallbackValue(const TranslationOptions());
  registerFallbackValue(<TranslationEngine>[]);
  registerFallbackValue(
    HistoryEntry(
      id: '0',
      text: '',
      translation: '',
      source: en,
      target: de,
      engineId: google.id,
      engineName: google.name,
      createdAt: DateTime(2026),
    ),
  );
}

/// Mocks with sensible defaults; tweak per test.
class TranslateMocks {
  new() {
    when(() => settings.state).thenReturn(const AppSettings());
    when(() => history.add(any())).thenAnswer((_) async {});
    when(() => repository.getEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async => allEngines);
    when(() => repository.getSourceLanguages(any()))
        .thenAnswer((_) async => sources);
    when(() => repository.getTargetLanguages(any()))
        .thenAnswer((_) async => targets);
  }

  final repository = MockTranslationRepository();
  final settings = MockSettingsCubit();
  final history = MockHistoryCubit();

  void stubSettings(AppSettings value) =>
      when(() => settings.state).thenReturn(value);

  /// Every translate call emits [result] (or a result per request when
  /// [result] is null: `<text>-><target>`).
  void stubTranslate([TranslationResult? result]) {
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final engine = invocation.positionalArguments[0] as TranslationEngine;
      final request = invocation.positionalArguments[1] as TranslationRequest;
      return Stream.value(
        result ??
            resultOf('${request.text}->${request.target.code}', engine: engine),
      );
    });
  }

  List<TranslationRequest> translateRequests() =>
      verify(() => repository.translate(any(), captureAny())).captured
          .cast<TranslationRequest>();

  List<HistoryEntry> historyEntries() =>
      verify(() => history.add(captureAny())).captured.cast<HistoryEntry>();

  /// Device languages seen by the smart swap (none by default).
  List<String> deviceLanguages = const [];

  /// The cubit's clock; null for the real one.
  DateTime Function()? clock;

  TranslateCubit build() => TranslateCubit(
    repository: repository,
    settings: settings,
    history: history,
    debounce: fastDebounce,
    aiDebounce: fastAiDebounce,
    clock: clock,
    deviceLanguages: () => deviceLanguages,
  );
}
