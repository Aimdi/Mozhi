import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/quick_translate/quick_translate.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository {}

class MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit {}

class MockHistoryCubit extends MockCubit<HistoryState>
    implements HistoryCubit {}

class MockSpeechService extends Mock implements SpeechService {}

class MockQuickTranslateCubit extends MockCubit<QuickTranslateState>
    implements QuickTranslateCubit {}

const google = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  subtitle: 'mozhi.example.org',
  mozhiEngine: 'google',
);

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
const french = Language(code: 'fr', name: 'French', nativeName: 'Français');
const german = Language(code: 'de', name: 'German', nativeName: 'Deutsch');
const japanese = Language(code: 'ja', name: 'Japanese', nativeName: '日本語');
const arabic = Language(code: 'ar', name: 'Arabic', nativeName: 'العربية');

const List<Language> mozhiTargets = [english, french, german, japanese];

TranslationResult result(
  String text, {
  String engineId = 'mozhi:google',
  String engineName = 'Google',
  bool isComplete = true,
  String? detectedSource = 'en',
}) => TranslationResult(
  engineId: engineId,
  engineName: engineName,
  text: text,
  isComplete: isComplete,
  detectedSource: detectedSource,
);

void registerQuickTranslateFallbacks() {
  registerFallbackValue(google);
  registerFallbackValue(english);
  registerFallbackValue(
    const TranslationRequest(text: 'x', source: Language.auto, target: english),
  );
  registerFallbackValue(
    HistoryEntry(
      id: '0',
      text: 'x',
      translation: 'y',
      source: Language.auto,
      target: english,
      engineId: 'mozhi:google',
      engineName: 'Google',
      createdAt: DateTime(2026),
    ),
  );
}

/// A settings cubit mock with [settings] as its state; mutations are no-ops
/// (verify them with `verify`).
MockSettingsCubit mockSettings([AppSettings settings = const AppSettings()]) {
  final cubit = MockSettingsCubit();
  when(() => cubit.state).thenReturn(settings);
  return cubit;
}

/// A ready quick translation (Google, auto -> French).
QuickTranslateState readyState({
  String text = 'Hello world',
  QuickTranslateStatus status = QuickTranslateStatus.success,
  TranslationResult? translation,
  Language target = french,
  TranslationEngine engine = google,
  List<TranslationEngine> engines = const [google, deepl, claude],
  Object? error,
}) => QuickTranslateState(
  text: text,
  target: target,
  status: status,
  engines: engines,
  engine: engine,
  targetLanguages: mozhiTargets,
  result: translation,
  error: error,
);

extension QuickPumpApp on WidgetTester {
  /// Pumps [child] in a localized Material 3 app inside a [Scaffold].
  Future<void> pumpQuick(
    Widget child, {
    Size size = const Size(400, 800),
    ThemeData? theme,
  }) async {
    view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(view.reset);
    await pumpWidget(
      MaterialApp(
        theme: theme ?? ThemeData(useMaterial3: true),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
  }
}

/// Provides [cubit] (and optionally [speech]) to a [QuickTranslateView].
Widget quickView(
  QuickTranslateCubit cubit, {
  SpeechService? speech,
  bool canReplace = false,
  ValueChanged<String>? onReplace,
  VoidCallback? onOpenInApp,
  VoidCallback? onClose,
}) {
  Widget child = BlocProvider<QuickTranslateCubit>.value(
    value: cubit,
    child: QuickTranslateView(
      canReplace: canReplace,
      onReplace: onReplace,
      onOpenInApp: onOpenInApp,
      onClose: onClose ?? () {},
    ),
  );
  if (speech != null) {
    child = RepositoryProvider<SpeechService>.value(
      value: speech,
      child: child,
    );
  }
  return Align(alignment: Alignment.topCenter, child: child);
}
