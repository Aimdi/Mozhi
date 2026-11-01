import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/quick_improve/quick_improve.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockQuickImproveCubit extends MockCubit<QuickImproveState>
    implements QuickImproveCubit;

class MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class MockUsageTracker extends Mock implements UsageTracker;

class MockSettingsCubit extends MockCubit<AppSettings> implements SettingsCubit;

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
  name: 'Llama',
  subtitle: 'llama3',
  providerId: 'ollama',
  isLocal: true,
);

/// A dedicated translation model: it cannot proofread.
const hyMt = TranslationEngine(
  id: 'ai:hymt',
  kind: EngineKind.ai,
  name: 'Hy-MT',
  providerId: 'hymt',
  promptProfile: PromptProfile.hunyuanMt,
);

const google = TranslationEngine(
  id: 'mozhi:google',
  kind: EngineKind.mozhi,
  name: 'Google',
  mozhiEngine: 'google',
);

const sentence = 'I has a cat.';

/// The proofread of [sentence]: "has" -> "have".
const fixed = ProofreadResult(
  correctedText: 'I have a cat.',
  edits: [
    ProofreadEdit(
      original: 'has',
      replacement: 'have',
      explanation: 'Subject-verb agreement',
    ),
  ],
  detectedLanguage: 'en',
  summary: 'One grammar fix.',
);

const cloudDestination = CloudProviderDestination(
  'Anthropic',
  host: 'api.anthropic.com',
);

const consent = ConsentRequiredException(
  kind: ConsentKind.cloudProvider,
  destination: cloudDestination,
  engineId: 'ai:claude',
  source: 'auto',
  target: 'auto',
);

void registerQuickImproveFallbacks() {
  registerFallbackValue(claude);
  registerFallbackValue(WritingStyle.general);
  registerFallbackValue(CorrectionLevel.standard);
  registerFallbackValue(consent);
}

/// Stubs [repository]'s proofread of any text with [answer] (or [error]).
void stubProofread(
  MockTranslationRepository repository, {
  ProofreadResult answer = fixed,
  Object? error,
}) {
  when(
    () => repository.proofread(
      any(),
      any(),
      style: any(named: 'style'),
      level: any(named: 'level'),
      uiLanguage: any(named: 'uiLanguage'),
    ),
  ).thenAnswer(
    (_) => error == null ? Future.value(answer) : Future.error(error),
  );
}

/// A finished quick improve of [sentence] with [claude].
QuickImproveState improvedState({
  String text = sentence,
  String improved = 'I have a cat.',
  ProofreadResult result = fixed,
  List<TranslationEngine> engines = const [claude, ollama],
}) => QuickImproveState(
  text: text,
  status: QuickImproveStatus.success,
  engine: claude,
  engines: engines,
  result: result,
  improvedText: improved,
  segments: [
    for (final part
        in improved == text
            ? [(DiffType.unchanged, text)]
            : [
                (DiffType.unchanged, 'I '),
                (DiffType.removed, 'has'),
                (DiffType.inserted, 'have'),
                (DiffType.unchanged, ' a cat.'),
              ])
      DiffSegment(part.$1, part.$2),
  ],
);

extension QuickImprovePumpApp on WidgetTester {
  /// Pumps [child] in a localized app ([theme], default Material 3) inside
  /// a [Scaffold].
  Future<void> pumpImprove(
    Widget child, {
    Size size = const Size(400, 900),
    ThemeData? theme,
    ThemeData? darkTheme,
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(view.reset);
    await pumpWidget(
      MaterialApp(
        theme: theme ?? ThemeData(useMaterial3: true),
        darkTheme: darkTheme,
        themeMode: themeMode,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
  }
}

/// Provides [cubit] (and [repository], when given) to a [QuickImproveView].
Widget improveView(
  QuickImproveCubit cubit, {
  TranslationRepository? repository,
  ValueChanged<String>? onReplace,
  VoidCallback? onOpenInProofread,
  VoidCallback? onReloadEngines,
  VoidCallback? onAddProvider,
  VoidCallback? onSetUpOnDeviceAi,
  VoidCallback? onClose,
}) {
  Widget child = BlocProvider<QuickImproveCubit>.value(
    value: cubit,
    child: QuickImproveView(
      onReplace: onReplace,
      onOpenInProofread: onOpenInProofread,
      onReloadEngines: onReloadEngines,
      onAddProvider: onAddProvider,
      onSetUpOnDeviceAi: onSetUpOnDeviceAi,
      onClose: onClose ?? () {},
    ),
  );
  if (repository != null) {
    child = RepositoryProvider<TranslationRepository>.value(
      value: repository,
      child: child,
    );
  }
  return Align(alignment: Alignment.topCenter, child: child);
}
