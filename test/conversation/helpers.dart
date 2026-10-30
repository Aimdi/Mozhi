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
import 'package:mozhi/usage/usage.dart';
import 'package:mozhi/voice/speech_input_state.dart';
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
  when(
    () => speech.speak(
      id: any(named: 'id'),
      text: any(named: 'text'),
      languageCode: any(named: 'languageCode'),
      slow: any(named: 'slow'),
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
    UsageTracker? usageTracker,
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
          if (usageTracker != null)
            RepositoryProvider<UsageTracker>.value(value: usageTracker),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TranslateCubit>.value(value: translate),
            BlocProvider<SettingsCubit>.value(value: settings),
          ],
          child: MaterialApp(
            theme: theme ?? ThemeData(useMaterial3: true),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: content,
          ),
        ),
      ),
    );
  }
}

/// The tooltip of a listen button that offers the slow replay.
String listenTooltip(String label) => '$label\nLong-press to listen slowly';

/// Finds a [Tooltip] showing [message], also one excluded from semantics.
Finder findTooltipMessage(String message) => find.byWidgetPredicate(
  (widget) => widget is Tooltip && widget.message == message,
);

/// A scriptable [ConversationRecognizer]: records what it was asked to
/// listen for; tests drive the current utterance ([start], [say], ...).
class FakeConversationRecognizer implements ConversationRecognizer {
  /// Every [listen] call: the language and whether detection was asked.
  final listens = <({Language language, bool detectLanguage})>[];

  /// The pause of every [listen] call (null: none given).
  final pauses = <Duration?>[];
  StreamController<ConversationHearing>? _utterance;
  int cancels = 0;
  bool disposed = false;

  /// Whether an utterance is being listened to (the microphone is open).
  bool get open => _utterance != null;

  /// The language of the last [listen].
  Language get language => listens.last.language;

  @override
  Stream<ConversationHearing> listen(
    Language language, {
    bool detectLanguage = false,
    Duration? pause,
  }) {
    final previous = _utterance;
    if (previous != null) unawaited(previous.close());
    listens.add((language: language, detectLanguage: detectLanguage));
    pauses.add(pause);
    final utterance = _utterance = StreamController<ConversationHearing>();
    return utterance.stream;
  }

  void emit(ConversationHearing event) => _utterance!.add(event);

  void start({bool detectsLanguage = false}) =>
      emit(ConversationHeardStart(detectsLanguage: detectsLanguage));

  void level(double level) => emit(ConversationHeardLevel(level));

  /// Someone is heard speaking (words, or voice activity detection).
  void speech() => emit(const ConversationHeardSpeech());

  void partial(String text) => emit(ConversationHeardPartial(text));

  void transcribing() => emit(const ConversationHeardTranscribing());

  /// Ends the utterance with [text] (heard in [language], if detected).
  void say(String text, {String? language}) =>
      _end(ConversationHeardFinal(text, language: language));

  void fail(
    SpeechInputFailure failure, {
    bool onDevice = false,
    bool offlineSupported = false,
  }) => _end(
    ConversationHeardFailure(
      failure,
      onDevice: onDevice,
      offlineSupported: offlineSupported,
    ),
  );

  void end({bool interrupted = false}) =>
      _end(ConversationHeardEnd(interrupted: interrupted));

  void _end(ConversationHearing last) {
    final utterance = _utterance!;
    _utterance = null;
    utterance.add(last);
    unawaited(utterance.close());
  }

  @override
  Future<void> cancel() async {
    cancels++;
    final utterance = _utterance;
    _utterance = null;
    if (utterance != null) unawaited(utterance.close());
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await cancel();
  }
}

/// Timers that only fire when a test says so ([fire]).
class FakeTimers {
  final timers = <FakeTimer>[];

  Timer call(Duration duration, void Function() callback) {
    final timer = FakeTimer(duration, callback);
    timers.add(timer);
    return timer;
  }

  /// Whether a timer of [duration] is waiting.
  bool pending(Duration duration) =>
      timers.any((timer) => timer.isActive && timer.duration == duration);

  /// Fires the waiting timers of [duration].
  void fire(Duration duration) {
    for (final timer in [...timers]) {
      if (timer.isActive && timer.duration == duration) timer.fire();
    }
  }
}

class FakeTimer implements Timer {
  new(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;

  @override
  void cancel() => _active = false;
}

/// Lets streams and futures deliver what they have.
Future<void> settle() => Future<void>.delayed(Duration.zero);
