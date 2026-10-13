import 'dart:async';
import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/image_translate/image_translate.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

class MockTranslationRepository extends Mock implements TranslationRepository;

class MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class MockSettingsCubit extends MockCubit<AppSettings> implements SettingsCubit;

class MockImageTranslateCubit extends MockCubit<ImageTranslateState>
    implements ImageTranslateCubit;

class MockGoRouter extends Mock implements GoRouter;

/// A valid 1x1 PNG.
final Uint8List pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

/// JPEG signature (not decodable; only for MIME sniffing / cubit tests).
final jpegBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

/// HEIC signature (not decodable).
final heicBytes = Uint8List.fromList([
  0, 0, 0, 24, //
  ...'ftypheic'.codeUnits,
  0, 0, 0, 0,
]);

final encodedPng = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 9, 9]);

final jpegImage = PickedImage(
  bytes: jpegBytes,
  mimeType: 'image/jpeg',
  name: 'photo.jpg',
  path: '/tmp/photo.jpg',
);

final pngImage = PickedImage(
  bytes: pngBytes,
  mimeType: 'image/png',
  name: 'shot.png',
  path: '/tmp/shot.png',
);

final heicImage = PickedImage(
  bytes: heicBytes,
  mimeType: 'image/heic',
  name: 'photo.heic',
  path: '/tmp/photo.heic',
);

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
  mozhiEngine: 'deepl',
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
  providerId: 'ollama',
  isLocal: true,
);

const claudeProvider = AiProviderConfig(
  id: 'claude',
  name: 'Claude',
  provider: LlmProvider.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  model: 'claude-opus-5-5',
  supportsVision: true,
);

const ollamaProvider = AiProviderConfig(
  id: 'ollama',
  name: 'Ollama',
  provider: LlmProvider.ollama,
  baseUrl: 'http://localhost:11434',
  model: 'gemma3',
);

const List<TranslationEngine> allEngines = [google, deepl, claude, ollama];
const List<AiProviderConfig> allProviders = [claudeProvider, ollamaProvider];

const english = Language(code: 'en', name: 'English', nativeName: 'English');
const french = Language(code: 'fr', name: 'French', nativeName: 'Français');
const german = Language(code: 'de', name: 'German', nativeName: 'Deutsch');
const japanese = Language(code: 'ja', name: 'Japanese', nativeName: '日本語');

const List<Language> languages = [english, french, german, japanese];

const mozhiMethod = ImageTranslateMethod.mozhiLens(google);
const claudeMethod = ImageTranslateMethod.aiVision(claude);
const onDeviceMethod = ImageTranslateMethod.onDevice();

class FakeImagePickerService implements ImagePickerService {
  new({this.supportsCamera = true, this.image});

  @override
  bool supportsCamera;

  /// Returned by [pick] (null = dismissed).
  PickedImage? image;

  /// Thrown by [pick] when set.
  Exception? error;

  final picks = <ImagePickSource>[];

  @override
  Future<PickedImage?> pick(ImagePickSource source) async {
    picks.add(source);
    final failure = error;
    if (failure != null) throw failure;
    return image;
  }
}

class FakeImageEncoder implements ImageEncoder {
  new({Uint8List? output}) : output = output ?? encodedPng;

  Uint8List output;
  Exception? error;
  final inputs = <Uint8List>[];

  @override
  Future<Uint8List> encodePng(
    Uint8List bytes, {
    int maxSide = defaultMaxSide,
    int maxBytes = defaultMaxBytes,
  }) async {
    inputs.add(bytes);
    final failure = error;
    if (failure != null) throw failure;
    return output;
  }
}

class FakeTextRecognitionService implements TextRecognitionService {
  new({this.isSupported = true, this.text = ''});

  @override
  bool isSupported;
  String text;
  Exception? error;

  /// When set, [recognize] waits for it.
  Completer<void>? gate;
  final sources = <Language>[];

  @override
  Future<String> recognize(
    PickedImage image, {
    required Language source,
  }) async {
    sources.add(source);
    await gate?.future;
    final failure = error;
    if (failure != null) throw failure;
    return text;
  }
}

void registerImageTranslateFallbacks() {
  registerFallbackValue(google);
  registerFallbackValue(ImagePickSource.gallery);
  registerFallbackValue(onDeviceMethod);
  registerFallbackValue(english);
  registerFallbackValue(Uint8List(0));
  registerFallbackValue(const TranslationOptions());
  registerFallbackValue(
    const TranslationRequest(text: 'x', source: english, target: french),
  );
}

/// A ready translator on DeepL, auto -> French.
TranslateState translateState({
  List<TranslationEngine> engines = allEngines,
  TranslationEngine? engine = deepl,
  Language source = Language.auto,
  Language target = french,
}) => TranslateState(
  enginesStatus: EnginesStatus.ready,
  engines: engines,
  engine: engine,
  sourceLanguages: const [Language.auto, ...languages],
  targetLanguages: languages,
  source: source,
  target: target,
);

/// Mocks and pumping for image translation widget tests.
class ImageTranslateHarness {
  new({
    TranslateState? translate,
    AppSettings settings = const AppSettings(providers: allProviders),
  }) {
    when(() => this.translate.state).thenReturn(translate ?? translateState());
    when(() => this.settings.state).thenReturn(settings);
    when(() => router.go(any())).thenReturn(null);
    when(() => router.push<Object?>(any(), extra: any(named: 'extra')))
        .thenAnswer((_) async => null);
  }

  final repository = MockTranslationRepository();
  final translate = MockTranslateCubit();
  final settings = MockSettingsCubit();
  final router = MockGoRouter();
  final picker = FakeImagePickerService();
  final encoder = FakeImageEncoder();
  final recognizer = FakeTextRecognitionService(isSupported: false);

  /// Pumps [child] inside the app-wide providers.
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size? size,
    ThemeMode themeMode = ThemeMode.light,
  }) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = size ?? const Size(600, 1800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      InheritedGoRouter(
        goRouter: router,
        child: RepositoryProvider<TranslationRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<TranslateCubit>.value(value: translate),
              BlocProvider<SettingsCubit>.value(value: settings),
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
              home: child,
            ),
          ),
        ),
      ),
    );
  }

  /// Pumps the real page with the fake platform services.
  Future<void> pumpPage(
    WidgetTester tester, {
    ImagePickSource? initialSource,
    Size? size,
    ThemeMode themeMode = ThemeMode.light,
  }) => pump(
    tester,
    ImageTranslatePage(
      initialSource: initialSource,
      picker: picker,
      encoder: encoder,
      recognizer: recognizer,
    ),
    size: size,
    themeMode: themeMode,
  );

  /// Pumps [child] (default [ImageTranslateView]) with [cubit].
  Future<void> pumpWithCubit(
    WidgetTester tester,
    ImageTranslateCubit cubit, {
    Widget child = const ImageTranslateView(),
    Size? size,
  }) => pump(
    tester,
    BlocProvider<ImageTranslateCubit>.value(
      value: cubit,
      child: child is ImageTranslateView
          ? child
          : Scaffold(body: SingleChildScrollView(child: child)),
    ),
    size: size,
  );
}

/// A mock image cubit stuck in [state].
MockImageTranslateCubit mockImageCubit(ImageTranslateState state) {
  final cubit = MockImageTranslateCubit();
  when(() => cubit.state).thenReturn(state);
  when(() => cubit.isClosed).thenReturn(false);
  when(cubit.translate).thenAnswer((_) async {});
  when(() => cubit.translateText(any())).thenAnswer((_) async {});
  when(() => cubit.pickImage(any())).thenAnswer((_) async {});
  when(() => cubit.selectMethod(any())).thenAnswer((_) async {});
  when(() => cubit.setSource(any())).thenAnswer((_) async {});
  when(() => cubit.setTarget(any())).thenAnswer((_) async {});
  return cubit;
}

/// Captures clipboard writes.
class FakeClipboard {
  new(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
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

  String? copied;
}
