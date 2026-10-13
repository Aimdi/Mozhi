import 'dart:async';

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
import 'package:mozhi/presets/presets.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class MockSettingsCubit extends MockCubit<AppSettings> implements SettingsCubit;

class MockHistoryCubit extends MockCubit<HistoryState> implements HistoryCubit;

class MockSpeechService extends Mock implements SpeechService;

class MockGoRouter extends Mock implements GoRouter;

class MockPresetsCubit extends MockCubit<PresetsState> implements PresetsCubit;

class MockSpeechInputService extends Mock implements SpeechInputService;

/// A [MockSpeechInputService] that is idle and reports every started
/// session on [states]; push recognised text with [say].
class FakeSpeechInput {
  new() {
    when(() => service.isPlatformSupported).thenReturn(true);
    when(() => service.state).thenReturn(const SpeechInputIdle());
    when(() => service.states).thenAnswer((_) => states.stream);
    when(() => service.results).thenAnswer((_) => results.stream);
    when(() => service.preferOnDevice).thenReturn(ValueNotifier(false));
    when(service.refreshAvailability).thenAnswer((_) async {});
    when(service.cancel).thenAnswer((_) async {});
    when(service.stop).thenAnswer((_) async {
      states.add(const SpeechInputIdle());
    });
    when(
      () => service.listen(
        any(),
        preferOnDevice: any(named: 'preferOnDevice'),
        owner: any(named: 'owner'),
      ),
    ).thenAnswer((invocation) async {
      owner = invocation.namedArguments[#owner];
      languages.add(invocation.positionalArguments.first as String?);
      states.add(SpeechInputListening(owner: owner));
      return true;
    });
    addTearDown(states.close);
    addTearDown(results.close);
  }

  final service = MockSpeechInputService();
  final states = StreamController<SpeechInputState>.broadcast();
  final results = StreamController<SpeechInputResult>.broadcast();

  /// Owner of the last started session.
  Object? owner;

  /// Language of every started session.
  final languages = <String?>[];

  void say(String text, {bool isFinal = false}) =>
      results.add(SpeechInputResult(text, isFinal: isFinal, owner: owner));

  /// Ends the session.
  void finish() => states.add(const SpeechInputIdle());
}

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
    this.presets,
    this.speechInput,
  }) {
    when(() => translate.state).thenReturn(state ?? readyState());
    when(() => translate.isClosed).thenReturn(false);
    when(() => translate.loadEngines(refresh: any(named: 'refresh')))
        .thenAnswer((_) async {});
    when(() => translate.selectEngine(any())).thenAnswer((_) async {});
    when(translate.translate).thenAnswer((_) async {});
    when(() => translate.applySuggestion(any())).thenAnswer((_) async {});
    when(translate.runCompare).thenAnswer((_) async {});
    when(
      () => translate.loadAlternatives(
        span: any(named: 'span'),
        spanStart: any(named: 'spanStart'),
      ),
    ).thenAnswer((_) async {});
    when(translate.loadInsights).thenAnswer((_) async {});
    when(translate.loadSuggestions).thenAnswer((_) async {});
    when(() => translate.explain(question: any(named: 'question')))
        .thenAnswer((_) async {});
    when(translate.lookUp).thenAnswer((_) async {});

    when(() => this.settings.state).thenReturn(settings);

    when(() => this.history.state).thenReturn(history);
    when(() => this.history.add(any())).thenAnswer((_) async {});
    when(() => this.history.toggleFavorite(any())).thenAnswer((_) async {});

    when(() => router.push<void>(any(), extra: any(named: 'extra')))
        .thenAnswer((_) async {});
    when(() => router.push<Object?>(any(), extra: any(named: 'extra')))
        .thenAnswer((_) async => null);

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

  /// Provided above the app when set (the preset picker needs it).
  final PresetsCubit? presets;

  /// Provided above the app when set (voice input needs it).
  final SpeechInputService? speechInput;

  void setState(TranslateState state) =>
      when(() => translate.state).thenReturn(state);

  /// Pumps [child] (default [TranslateView]) inside the app-wide providers.
  ///
  /// [supportsAnnounce] overrides whether the platform supports semantic
  /// announcements (false in tests by default, like Android), [locale] the
  /// UI locale and [disableAnimations] the reduced-motion setting.
  Future<void> pump(
    WidgetTester tester, {
    Widget child = const TranslateView(),
    Size? size,
    double textScale = 1,
    ThemeMode themeMode = ThemeMode.light,
    bool? supportsAnnounce,
    bool disableAnimations = false,
    Locale? locale,
    TargetPlatform? platform,
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
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<SpeechService>.value(value: speech),
            if (speechInput case final speechInput?)
              RepositoryProvider<SpeechInputService>.value(value: speechInput),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<TranslateCubit>.value(value: translate),
              BlocProvider<SettingsCubit>.value(value: settings),
              BlocProvider<HistoryCubit>.value(value: history),
              if (presets case final presets?)
                BlocProvider<PresetsCubit>.value(value: presets),
            ],
            child: MaterialApp(
              theme: ThemeData(useMaterial3: true, platform: platform),
              darkTheme: ThemeData(
                useMaterial3: true,
                brightness: Brightness.dark,
                platform: platform,
              ),
              themeMode: themeMode,
              locale: locale,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) {
                final data = MediaQuery.of(context);
                return MediaQuery(
                  data: data.copyWith(
                    textScaler: TextScaler.linear(textScale),
                    supportsAnnounce: supportsAnnounce ?? data.supportsAnnounce,
                    disableAnimations: disableAnimations,
                  ),
                  child: child!,
                );
              },
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
