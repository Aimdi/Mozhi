import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/app.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../../app/mocks.dart';
import '../../voice/helpers/fake_offline_recognizer.dart';
import '../../voice/helpers/fake_speech_recognizer.dart';

class _MockEngine extends Mock implements WhisperEngine;

/// The CI emulator's sequence on the whole app: Offline only, no speech
/// recognition service, no speech model; Translate's mic offers the model
/// ("Not now"), then the Conversation tab's large mic must offer it too.
void main() {
  setUpAll(() {
    registerAppFallbacks();
    registerFallbackValue(const AppSettings());
  });

  final l10n = lookupAppLocalizations(const Locale('en'));

  late TestEnvironment env;
  late Directory root;
  late SpeechInputService speechInput;
  late OfflineSpeech offline;

  setUp(() {
    env = TestEnvironment();
    when(() => env.settingsRepository.save(any())).thenAnswer((_) async {});
    when(env.historyRepository.load).thenAnswer((_) async => const []);
    when(
      () => env.translationRepository.updateConfiguration(
        instances: any(named: 'instances'),
        providers: any(named: 'providers'),
      ),
    ).thenReturn(null);
    when(() => env.translationRepository.privacyMode)
        .thenReturn(PrivacyMode.offlineOnly);
    root = Directory.systemTemp.createTempSync('conversation_app_voice_');
    final bytes = Uint8List(3000);
    final engine = _MockEngine();
    when(() => engine.release(any())).thenAnswer((_) async {});
    when(engine.dispose).thenAnswer((_) async {});
    offline = OfflineSpeech(
      whisper: WhisperSpeech(
        catalog: WhisperModelCatalog(
          models: [
            WhisperCatalogModel(
              id: 'tiny',
              name: 'ggml-tiny.bin',
              url: Uri.parse('https://models.example/ggml-tiny.bin'),
              size: bytes.length,
              sha1: sha1.convert(bytes).toString(),
            ),
          ],
        ),
        root: root,
        httpClient: MockClient((_) async => http.Response('', 404)),
        engine: engine,
        isAvailable: true,
      ),
      store: env.preferences,
      isMeteredConnection: () async => false,
    );
    speechInput = SpeechInputService(
      store: env.preferences,
      // A de-Googled phone: no speech recognition service.
      adapter: FakeSpeechRecognizer()..initResult = false,
      offlineAdapter: FakeOfflineRecognizer()..ready = false,
      privacyMode: () => PrivacyMode.offlineOnly,
      platformSupported: true,
      onDeviceSupported: true,
    );
  });

  tearDown(() async {
    await speechInput.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester tester, [int steps = 20]) async {
    for (var i = 0; i < steps; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(411, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final deps = env.dependencies();
    await tester.pumpWidget(
      App(
        dependencies: AppDependencies(
          translationRepository: deps.translationRepository,
          settingsRepository: deps.settingsRepository,
          historyRepository: deps.historyRepository,
          speechService: deps.speechService,
          sharedTextService: deps.sharedTextService,
          settings: deps.settings,
          preferences: deps.preferences,
          secrets: deps.secrets,
          speechInputService: speechInput,
          offlineTranslator: deps.offlineTranslator,
          usageTracker: deps.usageTracker,
          offlineSpeech: offline,
        ),
      ),
    );
    await settle(tester);
  }

  Finder mic() => find.byKey(ConversationSessionMic.buttonKey);

  void goTo(WidgetTester tester, String location) =>
      GoRouter.of(tester.element(find.byType(NavigationBar).first))
          .go(location);

  testWidgets('Translate offers the model, then Conversation does too', (
    tester,
  ) async {
    await pumpApp(tester);
    // Translate: the mic offers the model; "Not now".
    await tester.tap(find.byType(VoiceInputButton).first);
    await settle(tester);
    expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
    await tester.tap(find.text(l10n.voiceOfferNotNow));
    await settle(tester);
    // Explained once: no snack bar was left under the offer.
    expect(find.byType(SnackBar), findsNothing);

    // mozhi://conversation, then "Start conversation".
    goTo(tester, AppRoutes.conversation);
    await settle(tester);
    await tester.tap(mic());
    await settle(tester);

    expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
    expect(find.text(l10n.voiceOfferTitle), findsOneWidget);
    expect(
      tester.element(mic()).read<ConversationCubit>().state.session,
      isA<ConversationSessionFailed>(),
    );
  });

  testWidgets("another screen's snack bar does not cover the large mic", (
    tester,
  ) async {
    await pumpApp(tester);
    // A message with an action, which accessibility services keep up.
    ScaffoldMessenger.of(tester.element(find.byType(VoiceInputButton).first))
        .showSnackBar(
          SnackBar(
            content: const Text('From Translate'),
            duration: const Duration(days: 1),
            action: SnackBarAction(label: 'Undo', onPressed: () {}),
          ),
        );
    await settle(tester);
    expect(find.text('From Translate'), findsOneWidget);

    goTo(tester, AppRoutes.conversation);
    await settle(tester);
    expect(find.text('From Translate'), findsNothing);

    await tester.tap(mic());
    await settle(tester);
    expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
  });
}
