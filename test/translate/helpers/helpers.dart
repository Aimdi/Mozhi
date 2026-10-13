import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

class MockHistoryCubit extends MockCubit<HistoryState>
    implements HistoryCubit;

class MockSpeechService extends Mock implements SpeechService;

class MockGoRouter extends Mock implements GoRouter;

const deepl = TranslationEngine(
  id: 'mozhi:deepl',
  kind: EngineKind.mozhi,
  name: 'DeepL',
  subtitle: 'mozhi.example.org',
  mozhiEngine: 'deepl',
);

const google = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  subtitle: 'mozhi.example.org',
  mozhiEngine: 'google',
);

const claude = TranslationEngine(
  id: 'ai:claude',
  kind: EngineKind.ai,
  name: 'Claude',
  subtitle: 'claude-opus-5-5',
  providerId: 'claude',
);

const ollama = TranslationEngine(
  id: 'ai:ollama',
  kind: EngineKind.ai,
  name: 'Ollama',
  subtitle: 'qwen3:8b',
  providerId: 'ollama',
  isLocal: true,
);

const english = Language(code: 'en', name: 'English', nativeName: 'English');
const french = Language(code: 'fr', name: 'French', nativeName: 'Français');
const german = Language(code: 'de', name: 'German', nativeName: 'Deutsch');
const japanese = Language(code: 'ja', name: 'Japanese', nativeName: '日本語');

const List<Language> languages = [english, french, german, japanese];

const helloResult = TranslationResult(
  engineId: 'mozhi:deepl',
  engineName: 'DeepL',
  text: 'Bonjour le monde',
  detectedSource: 'en',
  elapsed: Duration(milliseconds: 800),
);

/// A ready translate screen on DeepL, English (auto) -> French.
TranslateState readyState({
  TranslationEngine engine = deepl,
  TranslationEngine? assistEngine,
  String input = '',
  TranslationResult? result,
  TranslateStatus? status,
  Language source = Language.auto,
  Language target = french,
}) => TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: const [deepl, google, claude, ollama],
  engine: engine,
  assistEngine: assistEngine ?? (engine.isAi ? engine : null),
  sourceLanguages: const [Language.auto, ...languages],
  targetLanguages: languages,
  source: source,
  target: target,
  input: input,
  result: result,
  status:
      status ??
      (result == null ? TranslateStatus.idle : TranslateStatus.success),
);

/// "Hello world" -> "Bonjour le monde" translated by DeepL.
TranslateState translatedState({
  TranslationEngine engine = deepl,
  TranslationEngine? assistEngine,
  String input = 'Hello world',
  TranslationResult result = helloResult,
}) => readyState(
  engine: engine,
  assistEngine: assistEngine,
  input: input,
  result: result,
);

void registerTranslateFallbacks() {
  registerFallbackValue(const TranslationOptions());
  registerFallbackValue(english);
  registerFallbackValue(deepl);
  registerFallbackValue(RefinementSuggestion.defaults.first);
  registerFallbackValue(const WordInsight(sourceText: 'a', targetText: 'b'));
  registerFallbackValue(const CompareEntry.success(helloResult));
  registerFallbackValue(
    HistoryEntry(
      id: 'fallback',
      text: '',
      translation: '',
      source: Language.auto,
      target: english,
      engineId: '',
      engineName: '',
      createdAt: DateTime(2026),
    ),
  );
}

/// Mocks and pumping for translate widget tests.
class TranslateHarness {
  new({
    TranslateState? state,
    AppSettings settings = const AppSettings(),
    HistoryState history = const HistoryState(),
  }) {
    when(() => translate.state).thenReturn(state ?? readyState());
    when(() => translate.isClosed).thenReturn(false);
    when(() => translate.loadEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async {});
    when(() => translate.selectEngine(any())).thenAnswer((_) async {});
    when(translate.translate).thenAnswer((_) async {});
    when(() => translate.applySuggestion(any())).thenAnswer((_) async {});
    when(translate.runCompare).thenAnswer((_) async {});
    when(() => translate.loadAlternatives(span: any(named: 'span')))
        .thenAnswer((_) async {});
    when(translate.loadInsights).thenAnswer((_) async {});
    when(translate.loadSuggestions).thenAnswer((_) async {});
    when(() => translate.explain(question: any(named: 'question')))
        .thenAnswer((_) async {});
    when(translate.lookUp).thenAnswer((_) async {});

    when(() => this.settings.state).thenReturn(settings);

    when(() => this.history.state).thenReturn(history);
    when(() => this.history.add(any())).thenAnswer((_) async {});
    when(() => this.history.toggleFavorite(any())).thenAnswer((_) async {});

    when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
    when(() => speech.current).thenReturn(null);
    when(
      () => speech.toggle(
        id: any(named: 'id'),
        text: any(named: 'text'),
        languageCode: any(named: 'languageCode'),
      ),
    ).thenAnswer((_) async {});
  }

  final translate = MockTranslateCubit();
  final settings = MockSettingsCubit();
  final history = MockHistoryCubit();
  final speech = MockSpeechService();
  final router = MockGoRouter();

  void setState(TranslateState state) =>
      when(() => translate.state).thenReturn(state);

  /// Pumps [child] (default [TranslateView]) inside the app-wide providers.
  Future<void> pump(
    WidgetTester tester, {
    Widget child = const TranslateView(),
    Size? size,
    double textScale = 1,
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    if (size != null) {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = size;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      InheritedGoRouter(
        goRouter: router,
        child: RepositoryProvider<SpeechService>.value(
          value: speech,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<TranslateCubit>.value(value: translate),
              BlocProvider<SettingsCubit>.value(value: settings),
              BlocProvider<HistoryCubit>.value(value: history),
            ],
            child: MaterialApp(
              theme: ThemeData(useMaterial3: true),
              darkTheme: ThemeData(
                useMaterial3: true,
                brightness: Brightness.dark,
              ),
              themeMode: themeMode,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: child is TranslateView || child is TranslatePage
                  ? child
                  : Scaffold(body: SingleChildScrollView(child: child)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Captures clipboard writes and serves [pasteText] to reads.
class FakeClipboard {
  new(WidgetTester tester, {this.pasteText}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            copied = (call.arguments as Map)['text'] as String?;
          case 'Clipboard.getData':
            return pasteText == null ? null : {'text': pasteText};
          case 'Clipboard.hasStrings':
            return {'value': pasteText != null};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  String? pasteText;
  String? copied;
}
