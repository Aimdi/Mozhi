import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockSpeechService extends Mock implements SpeechService;

class MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class MockSettingsCubit extends MockCubit<AppSettings> implements SettingsCubit;

const deepl = TranslationEngine(
  id: 'mozhi:deepl',
  kind: EngineKind.mozhi,
  name: 'DeepL',
  subtitle: 'mozhi.example.org',
  mozhiEngine: 'deepl',
);

const claude = TranslationEngine(
  id: 'ai:claude',
  kind: EngineKind.ai,
  name: 'Claude',
  subtitle: 'claude-opus-5-5',
  providerId: 'claude',
);

const english = Language(code: 'en', name: 'English', nativeName: 'English');
const spanish = Language(code: 'es', name: 'Spanish', nativeName: 'Español');
const french = Language(code: 'fr', name: 'French', nativeName: 'Français');
const german = Language(code: 'de', name: 'German', nativeName: 'Deutsch');

const List<Language> languages = [english, french, german, spanish];

final sentAt = DateTime(2026, 10, 13, 14, 5);

TranslationResult resultOf(
  String text, {
  TranslationEngine engine = deepl,
  bool isComplete = true,
}) => TranslationResult(
  engineId: engine.id,
  engineName: engine.name,
  text: text,
  isComplete: isComplete,
);

ConversationTurn turnOf({
  int id = 0,
  ConversationSide side = ConversationSide.a,
  String original = 'Hello',
  String translation = 'Hola',
  ConversationTurnStatus status = ConversationTurnStatus.complete,
  Object? error,
  String? engineName = 'DeepL',
}) {
  final fromA = side == ConversationSide.a;
  return ConversationTurn(
    id: id,
    side: side,
    original: original,
    translation: translation,
    source: fromA ? english : spanish,
    target: fromA ? spanish : english,
    createdAt: sentAt,
    engineId: engineName == null ? null : 'mozhi:deepl',
    engineName: engineName,
    status: status,
    error: error,
  );
}

/// A ready translate screen on DeepL, English -> Spanish.
TranslateState translateState({
  TranslationEngine? engine = deepl,
  List<TranslationEngine> engines = const [deepl, claude],
  EnginesStatus enginesStatus = EnginesStatus.ready,
  Language source = english,
  Language target = spanish,
  List<Language> targetLanguages = languages,
  TranslationResult? result,
}) => TranslateState(
  enginesStatus: enginesStatus,
  engines: engines,
  engine: engine,
  sourceLanguages: [Language.auto, ...targetLanguages],
  targetLanguages: targetLanguages,
  source: source,
  target: target,
  result: result,
);

void registerConversationFallbacks() {
  registerFallbackValue(deepl);
  registerFallbackValue(
    const TranslationRequest(text: 'x', source: english, target: spanish),
  );
  registerFallbackValue(english);
}

/// Stubs [speech] as idle with a controllable `speaking` stream.
StreamController<String?> stubSpeech(MockSpeechService speech) {
  final speaking = StreamController<String?>.broadcast();
  when(() => speech.speaking).thenAnswer((_) => speaking.stream);
  when(() => speech.current).thenReturn(null);
  when(
    () => speech.toggle(
      id: any(named: 'id'),
      text: any(named: 'text'),
      languageCode: any(named: 'languageCode'),
    ),
  ).thenAnswer((_) async {});
  when(speech.stop).thenAnswer((_) async {});
  return speaking;
}

extension PumpConversation on WidgetTester {
  /// Pumps [child] in a localized Material 3 app with the app-wide
  /// providers conversation mode needs.
  Future<void> pumpConversation(
    Widget child, {
    required TranslateCubit translate,
    required SettingsCubit settings,
    TranslationRepository? repository,
    SpeechService? speech,
    ConversationCubit? conversation,
    Size size = const Size(400, 800),
    ThemeData? theme,
  }) async {
    view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(view.reset);
    var content = child;
    if (conversation != null) {
      content = BlocProvider<ConversationCubit>.value(
        value: conversation,
        child: content,
      );
    }
    await pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<TranslationRepository>.value(
            value: repository ?? MockTranslationRepository(),
          ),
          RepositoryProvider<SpeechService>.value(
            value: speech ?? MockSpeechService(),
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TranslateCubit>.value(value: translate),
            BlocProvider<SettingsCubit>.value(value: settings),
          ],
          child: MaterialApp(
            theme: theme ?? ThemeData(useMaterial3: true),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: content,
          ),
        ),
      ),
    );
  }
}
