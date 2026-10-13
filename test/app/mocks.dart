import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/data/history_repository.dart';
import 'package:mozhi/platform/shared_text_service.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/data/settings_repository.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository {}

class MockSettingsRepository extends Mock implements SettingsRepository {}

class MockHistoryRepository extends Mock implements HistoryRepository {}

class MockSpeechService extends Mock implements SpeechService {}

class MockSharedTextService extends Mock implements SharedTextService {}

class MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit {}

class MockHistoryCubit extends MockCubit<HistoryState>
    implements HistoryCubit {}

class MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit {}

/// A local instance so nothing points at the network in tests.
const testInstance = MozhiInstance(url: 'http://mozhi.test', label: 'Test');

/// Engines returned by [stubTranslationRepository].
final testEngines = [TranslationEngine.mozhi('google', 'Google')];

const _english = Language(code: 'en', name: 'English');

void registerAppFallbacks() {
  registerFallbackValue(testEngines.first);
  registerFallbackValue(testInstance);
  registerFallbackValue(const Language(code: 'en', name: 'English'));
  registerFallbackValue(
    const AiProviderConfig(
      id: 'p',
      name: 'P',
      provider: LlmProvider.openAiCompatible,
      baseUrl: 'http://localhost',
      model: 'm',
    ),
  );
  registerFallbackValue(
    const TranslationRequest(text: '', source: _english, target: _english),
  );
  PackageInfo.setMockInitialValues(
    appName: 'Mozhi',
    packageName: 'io.github.aimdi.mozhi',
    version: '0.1.0',
    buildNumber: '1',
    buildSignature: '',
  );
}

/// Stubs everything pages may call on start-up with harmless answers.
void stubTranslationRepository(MockTranslationRepository repository) {
  when(() => repository.instances).thenReturn(const [testInstance]);
  when(() => repository.providers).thenReturn(const []);
  when(() => repository.activeInstance).thenReturn(testInstance);
  when(() => repository.getEngines(refresh: any(named: 'refresh')))
      .thenAnswer((_) async => testEngines);
  when(() => repository.getSourceLanguages(any()))
      .thenAnswer((_) async => const [Language.auto, _english]);
  when(() => repository.getTargetLanguages(any()))
      .thenAnswer((_) async => const [_english]);
  when(() => repository.pingInstance(any()))
      .thenAnswer((_) async => const Duration(milliseconds: 42));
  when(() => repository.listModels(any())).thenAnswer((_) async => const []);
  when(() => repository.translate(any(), any()))
      .thenAnswer((_) => const Stream.empty());
}

void stubSpeechService(MockSpeechService speech) {
  when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
  when(() => speech.current).thenReturn(null);
  when(speech.stop).thenAnswer((_) async {});
}

/// Mocked dependencies and cubits for pumping routes/pages.
class TestEnvironment {
  TestEnvironment({
    AppSettings settings = const AppSettings(instances: [testInstance]),
  }) {
    stubTranslationRepository(translationRepository);
    stubSpeechService(speechService);
    when(() => sharedTextService.texts).thenAnswer((_) => const Stream.empty());
    when(sharedTextService.initialText).thenAnswer((_) async => null);
    when(() => settingsCubit.state).thenReturn(settings);
    when(() => historyCubit.state)
        .thenReturn(const HistoryState(status: HistoryStatus.ready));
    when(historyCubit.load).thenAnswer((_) async {});
    when(() => translateCubit.state).thenReturn(
      TranslateState(
        enginesStatus: EnginesStatus.ready,
        engines: testEngines,
        engine: testEngines.first,
        sourceLanguages: const [Language.auto, _english],
        targetLanguages: const [_english],
      ),
    );
    when(() => translateCubit.loadEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async {});
  }

  final translationRepository = MockTranslationRepository();
  final settingsRepository = MockSettingsRepository();
  final historyRepository = MockHistoryRepository();
  final speechService = MockSpeechService();
  final sharedTextService = MockSharedTextService();
  final settingsCubit = MockSettingsCubit();
  final historyCubit = MockHistoryCubit();
  final translateCubit = MockTranslateCubit();

  /// Wraps [child] in all providers the pages expect.
  Widget wrap(Widget child) => MultiRepositoryProvider(
    providers: [
      RepositoryProvider<TranslationRepository>.value(
        value: translationRepository,
      ),
      RepositoryProvider<SettingsRepository>.value(value: settingsRepository),
      RepositoryProvider<HistoryRepository>.value(value: historyRepository),
      RepositoryProvider<SpeechService>.value(value: speechService),
      RepositoryProvider<SharedTextService>.value(value: sharedTextService),
    ],
    child: MultiBlocProvider(
      providers: [
        BlocProvider<SettingsCubit>.value(value: settingsCubit),
        BlocProvider<HistoryCubit>.value(value: historyCubit),
        BlocProvider<TranslateCubit>.value(value: translateCubit),
      ],
      child: child,
    ),
  );
}

/// Completes after microtasks and pending timers of zero duration ran.
Future<void> flush() => Future<void>.delayed(Duration.zero);
