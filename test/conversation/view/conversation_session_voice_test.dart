import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/conversation/conversation.dart';
import 'package:mozhi/conversation/widgets/widgets.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/system_app_settings.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart';
import 'package:whisper_speech/whisper_speech.dart';

import '../../voice/helpers/fake_offline_recognizer.dart';
import '../../voice/helpers/fake_speech_recognizer.dart';
import '../helpers.dart';

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

Widget _fakeMic(BuildContext context, ConversationMicRequest request) =>
    const SizedBox.square(dimension: 48);

/// The catalogue's Fast model (`tiny`, 77,691,713 bytes: "74.1 MB").
final _tiny = WhisperCatalogModel(
  id: 'tiny',
  name: 'ggml-tiny.bin',
  url: Uri.parse('https://models.example/ggml-tiny.bin'),
  size: 77691713,
  sha1: 'a' * 40,
);

const Key _micKey = ConversationSessionMic.buttonKey;
const String _size = '74.1 MB';

/// The large microphone of a hands-free conversation over the app's own
/// recogniser, voice input service and model offer (only the platform's
/// recognisers and the Whisper runtime are fakes): tapping it either
/// listens or explains why not, with a way forward, like the translate
/// screen's microphone.
void main() {
  setUpAll(registerConversationFallbacks);

  final l10n = lookupAppLocalizations(const Locale('en'));

  late MockTranslateCubit translate;
  late MockSettingsCubit settings;
  late MockTranslationRepository repository;
  late MockSpeechService speech;
  late StreamController<String?> speaking;
  late FakeSpeechRecognizer system;
  late FakeOfflineRecognizer whisper;
  late PrivacyMode privacy;
  late SpeechInputService service;
  late _MockOfflineSpeech offline;
  late Set<String> installed;
  late Future<void> Function(String id) onDownload;

  setUp(() {
    translate = MockTranslateCubit();
    settings = MockSettingsCubit();
    repository = MockTranslationRepository();
    speech = MockSpeechService();
    speaking = stubSpeech(speech);
    when(() => translate.state).thenReturn(translateState());
    when(() => settings.state).thenReturn(const AppSettings());
    system = FakeSpeechRecognizer();
    whisper = FakeOfflineRecognizer();
    privacy = PrivacyMode.offlineFirst;
    service = SpeechInputService(
      store: MemoryStore(),
      adapter: system,
      offlineAdapter: whisper,
      privacyMode: () => privacy,
      platformSupported: true,
      onDeviceSupported: true,
    );
    offline = _MockOfflineSpeech();
    installed = {};
    onDownload = (id) async {
      installed.add(id);
      whisper.ready = true;
    };
    when(() => offline.isAvailable).thenReturn(true);
    when(() => offline.models).thenReturn([_tiny]);
    when(() => offline.memory).thenReturn(null);
    when(() => offline.vadModel).thenReturn(null);
    when(() => offline.engineBuild).thenReturn(null);
    when(offline.isVadReady).thenAnswer((_) async => false);
    when(offline.wifiOnly).thenAnswer((_) async => false);
    when(offline.installed).thenAnswer((_) async => {...installed});
    when(offline.selected)
        .thenAnswer((_) async => installed.isEmpty ? null : installed.last);
    when(
      () => offline.download(
        any(),
        overMeteredNetwork: any(named: 'overMeteredNetwork'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer(
      (invocation) =>
          onDownload(invocation.positionalArguments.single as String),
    );
    SystemAppSettings.debugIsSupported = true;
  });

  tearDown(() async {
    SystemAppSettings.debugIsSupported = null;
    await speaking.close();
    await service.dispose();
  });

  Future<void> pumpPage(WidgetTester tester, {bool withOffline = true}) async {
    Widget page = const ConversationPage(micBuilder: _fakeMic);
    if (withOffline) {
      page = RepositoryProvider<OfflineSpeech>.value(
        value: offline,
        child: page,
      );
    }
    await tester.pumpConversation(
      RepositoryProvider<SpeechInputService>.value(value: service, child: page),
      translate: translate,
      settings: settings,
      repository: repository,
      speech: speech,
    );
    await tester.pumpAndSettle();
  }

  ConversationCubit cubitOf(WidgetTester tester) =>
      tester.element(find.byKey(_micKey)).read<ConversationCubit>();

  /// Pumps while the session's rings may turn for ever.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tapMic(WidgetTester tester) async {
    await tester.tap(find.byKey(_micKey));
    await settle(tester);
  }

  String statusText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const Key('conversation_session_status_text')))
      .data!;

  Finder snackBarText(String text) =>
      find.descendant(of: find.byType(SnackBar), matching: find.text(text));

  group('without a speech recognition service', () {
    setUp(() {
      system.initResult = false;
      whisper.ready = false;
    });

    testWidgets('offers the offline speech model right away', (tester) async {
      await pumpPage(tester);
      await tapMic(tester);

      expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
      expect(
        find.text(l10n.voiceOfferBodyNoRecognizer(l10n.voiceModelFast, _size)),
        findsOneWidget,
      );
      expect(find.text(l10n.voiceOfferDownload(_size)), findsOneWidget);
      // Not the snack bar pointing to the settings.
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('downloading it starts listening with it', (tester) async {
      await pumpPage(tester);
      await tapMic(tester);
      await tester.tap(find.byKey(VoiceModelOfferDialog.downloadKey));
      await settle(tester);

      verify(
        () => offline.download('tiny', onProgress: any(named: 'onProgress')),
      ).called(1);
      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(whisper.requests, hasLength(1));
      expect(
        cubitOf(tester).state.session,
        const ConversationSessionListening(
          side: ConversationSide.a,
          stage: ConversationListenStage.listening,
        ),
      );
      expect(find.byKey(ConversationSessionMic.pulseKey), findsOneWidget);
    });

    testWidgets('Not now explains it, and the mic offers it again', (
      tester,
    ) async {
      await pumpPage(tester);
      await tapMic(tester);
      await tester.tap(find.text(l10n.voiceOfferNotNow));
      await settle(tester);

      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(
        statusText(tester),
        l10n.conversationSessionFailed(l10n.voiceErrorUnavailableOfflineModel),
      );
      expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
      expect(whisper.requests, isEmpty);

      await tapMic(tester);
      expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
    });

    testWidgets('a model that still does not work is explained, not offered '
        'again', (tester) async {
      // The download "succeeds", but the engine finds no model.
      onDownload = (id) async => installed.add(id);
      await pumpPage(tester);
      await tapMic(tester);
      await tester.tap(find.byKey(VoiceModelOfferDialog.downloadKey));
      await settle(tester);

      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(
        snackBarText(l10n.voiceErrorUnavailableOfflineModel),
        findsOneWidget,
      );
      expect(cubitOf(tester).state.session, isA<ConversationSessionFailed>());
    });

    testWidgets('where Whisper does not run it says so', (tester) async {
      await pumpPage(tester, withOffline: false);
      await tapMic(tester);

      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(
        snackBarText(l10n.voiceErrorUnavailableOfflineModel),
        findsOneWidget,
      );
    });
  });

  testWidgets('a recogniser that never answers offers the model', (
    tester,
  ) async {
    // speech_to_text initialises (Android 12+ names an on-device
    // recogniser no app provides), then listening ends with error_client.
    whisper.ready = false;
    await pumpPage(tester);
    await tapMic(tester);
    expect(system.requests, hasLength(1));
    system.emitError('error_client');
    await settle(tester);

    expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
    expect(
      find.text(l10n.voiceOfferBodyNoRecognizer(l10n.voiceModelFast, _size)),
      findsOneWidget,
    );

    await tester.tap(find.byKey(VoiceModelOfferDialog.downloadKey));
    await settle(tester);
    // Whisper takes over; the recogniser that never answered is not
    // asked again.
    expect(whisper.requests, hasLength(1));
    expect(system.requests, hasLength(1));
    expect(cubitOf(tester).state.session, isA<ConversationSessionListening>());
  });

  testWidgets('Offline only without the model offers it', (tester) async {
    privacy = PrivacyMode.offlineOnly;
    whisper.ready = false;
    await pumpPage(tester);
    await tapMic(tester);

    expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
    expect(
      find.text(l10n.voiceOfferBody(l10n.voiceModelFast, _size)),
      findsOneWidget,
    );
    expect(system.initCalls, 0);
  });

  testWidgets('a denied microphone offers the app settings', (tester) async {
    var opened = 0;
    final opener = SystemAppSettings.opener;
    SystemAppSettings.opener = () async {
      opened++;
      return true;
    };
    addTearDown(() => SystemAppSettings.opener = opener);
    whisper.ready = false;
    system
      ..initResult = false
      ..permission = false;
    await pumpPage(tester);
    await tapMic(tester);

    expect(find.byType(VoiceModelOfferDialog), findsNothing);
    expect(snackBarText(l10n.voiceErrorPermission), findsOneWidget);
    expect(
      statusText(tester),
      l10n.conversationSessionFailed(l10n.voiceErrorPermission),
    );
    await tester.tap(find.byKey(voiceOpenSettingsActionKey));
    await settle(tester);
    expect(opened, 1);
  });

  testWidgets('with the model installed it listens at once', (tester) async {
    system.initResult = false;
    await pumpPage(tester);
    await tapMic(tester);

    expect(find.byType(VoiceModelOfferDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(whisper.requests, hasLength(1));
    expect(find.byKey(ConversationSessionMic.pulseKey), findsOneWidget);
  });

  testWidgets('a German UI offers it in German', (tester) async {
    system.initResult = false;
    whisper.ready = false;
    tester.platformDispatcher.localesTestValue = const [Locale('de')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final de = lookupAppLocalizations(const Locale('de'));
    await pumpPage(tester);
    await tapMic(tester);

    expect(find.text(de.voiceOfferTitle), findsOneWidget);
    expect(find.text(de.voiceOfferDownload('74,1 MB')), findsOneWidget);
  });

  testWidgets('a browser without speech recognition shows the mic off and '
      'explains it without the privacy notice', (tester) async {
    await service.dispose();
    service = SpeechInputService(
      store: MemoryStore(),
      adapter: system,
      platformSupported: true,
      isWeb: true,
      browserRecognizerAvailable: false,
    );
    await pumpPage(tester, withOffline: false);

    expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
    expect(find.bySemanticsLabel(l10n.voiceInputUnavailable), findsOneWidget);

    await tapMic(tester);
    expect(find.byType(BrowserSpeechNoticeDialog), findsNothing);
    // In the web app this reads voiceErrorUnavailableBrowser (kIsWeb).
    expect(snackBarText(l10n.voiceErrorUnavailable), findsOneWidget);
    expect(cubitOf(tester).state.session, isA<ConversationSessionFailed>());
    expect(system.initCalls, 0);
  });
}
