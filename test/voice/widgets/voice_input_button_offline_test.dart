import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

import '../../helpers/helpers.dart';
import '../helpers/fake_offline_recognizer.dart';
import '../helpers/fake_speech_recognizer.dart';

class _MockGoRouter extends Mock implements GoRouter;

void main() {
  late FakeSpeechRecognizer system;
  late FakeOfflineRecognizer whisper;
  late PrivacyMode privacy;
  late SpeechInputService service;
  late List<(String, bool)> received;
  late List<bool> listeningChanges;
  late _MockGoRouter router;

  final l10n = lookupAppLocalizations(const Locale('en'));

  setUp(() {
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
    received = [];
    listeningChanges = [];
    router = _MockGoRouter();
    when(() => router.push<void>(any(), extra: any(named: 'extra')))
        .thenAnswer((_) async {});
  });

  Future<void> pump(WidgetTester tester, {bool withRouter = false}) {
    Widget page = Scaffold(
      body: Center(
        child: VoiceInputButton.standalone(
          service: service,
          languageCode: 'de',
          onResult: (text, {required isFinal}) => received.add((text, isFinal)),
          onListeningChanged: listeningChanges.add,
        ),
      ),
    );
    if (withRouter) page = InheritedGoRouter(goRouter: router, child: page);
    return tester.pumpApp(page);
  }

  Finder downloadAction() =>
      find.widgetWithText(SnackBarAction, l10n.voiceDownloadModelAction);

  Future<void> tapDownloadAction(WidgetTester tester) async {
    // Let the snack bar slide in.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(downloadAction());
    await tester.pump();
    verify(
      () => router.push<void>(
        VoiceInputButton.settingsLocation,
        extra: any(named: 'extra'),
      ),
    ).called(1);
  }

  Finder mic() => find.descendant(
    of: find.byType(VoiceInputButton),
    matching: find.byType(IconButton),
  );

  Future<void> tapMic(WidgetTester tester) async {
    await tester.tap(mic());
    await tester.pump();
    await tester.pump();
  }

  testWidgets('shows transcribing after stop until the result', (tester) async {
    await service.setEngine(VoiceInputEngine.whisper);
    await pump(tester);
    await tapMic(tester);
    expect(whisper.lastRequest.localeId, 'de');
    expect(listeningChanges, [true]);

    await tapMic(tester);
    expect(whisper.stopCalls, 1);
    expect(listeningChanges, [true, false]);
    expect(find.byKey(VoiceInputButton.transcribingKey), findsOneWidget);
    expect(find.bySemanticsLabel(l10n.voiceInputTranscribing), findsOneWidget);
    expect(
      tester.widget<IconButton>(mic()).tooltip,
      l10n.voiceInputCancelTranscription,
    );

    whisper.emitResult('Guten Tag', isFinal: true);
    await tester.pump();
    expect(received, [('Guten Tag', true)]);
    expect(find.byKey(VoiceInputButton.transcribingKey), findsNothing);
    expect(tester.widget<IconButton>(mic()).tooltip, l10n.voiceInputStart);
  });

  testWidgets('tapping while transcribing cancels', (tester) async {
    await service.setEngine(VoiceInputEngine.whisper);
    await pump(tester);
    await tapMic(tester);
    await tapMic(tester);
    await tapMic(tester);
    expect(whisper.cancelCalls, 1);
    expect(find.byKey(VoiceInputButton.transcribingKey), findsNothing);
    whisper.emitResult('late', isFinal: true);
    await tester.pump();
    expect(received, isEmpty);
  });

  testWidgets('leaving while transcribing cancels', (tester) async {
    await service.setEngine(VoiceInputEngine.whisper);
    await pump(tester);
    await tapMic(tester);
    await tapMic(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(whisper.cancelCalls, 1);
  });

  testWidgets('a missing model is explained and the button stays', (
    tester,
  ) async {
    whisper.ready = false;
    await service.setEngine(VoiceInputEngine.whisper);
    await pump(tester);
    await tapMic(tester);
    expect(find.text(l10n.voiceErrorOfflineModel), findsOneWidget);
    expect(mic(), findsOneWidget);
    // Nowhere to go without a router.
    expect(find.byType(SnackBarAction), findsNothing);
  });

  testWidgets('a missing model offers the voice settings, on every '
      'attempt', (tester) async {
    whisper.ready = false;
    await service.setEngine(VoiceInputEngine.whisper);
    await pump(tester, withRouter: true);
    await tapMic(tester);
    expect(find.text(l10n.voiceErrorOfflineModel), findsOneWidget);
    await tapDownloadAction(tester);

    ScaffoldMessenger.of(tester.element(mic())).removeCurrentSnackBar();
    await tester.pump();
    expect(find.text(l10n.voiceErrorOfflineModel), findsNothing);
    // The same failure again is explained again.
    await tapMic(tester);
    expect(find.text(l10n.voiceErrorOfflineModel), findsOneWidget);
    expect(downloadAction(), findsOneWidget);
  });

  testWidgets('without a system recogniser it offers to download the '
      'offline model', (tester) async {
    expect(VoiceInputButton.settingsLocation, '/settings/voice');
    system.initResult = false;
    whisper.ready = false;
    await pump(tester, withRouter: true);
    await tapMic(tester);

    expect(find.text(l10n.voiceErrorUnavailableOfflineModel), findsOneWidget);
    expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
    expect(
      tester.widget<IconButton>(mic()).tooltip,
      l10n.voiceInputUnavailable,
    );
    await tapDownloadAction(tester);
  });

  testWidgets('with an installed model, a denied microphone is explained', (
    tester,
  ) async {
    system.initResult = false;
    whisper
      ..initResultWhenReady = false
      ..permission = false;
    await pump(tester, withRouter: true);
    await tapMic(tester);

    expect(find.text(l10n.voiceErrorPermission), findsOneWidget);
    expect(find.byType(SnackBarAction), findsNothing);
    expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
  });

  testWidgets('a start another button took over does not repeat an old '
      'error', (tester) async {
    await service.setEngine(VoiceInputEngine.whisper);
    await tester.pumpApp(
      Scaffold(
        body: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final key in const ['first', 'second'])
                VoiceInputButton.standalone(
                  key: Key(key),
                  service: service,
                  languageCode: 'de',
                  onResult: (text, {required isFinal}) {},
                ),
            ],
          ),
        ),
      ),
    );
    Finder micOf(String key) => find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(IconButton),
    );
    Future<void> tapMicOf(String key) async {
      await tester.tap(micOf(key));
      await tester.pump();
    }

    await tapMicOf('first');
    await tester.pump();
    whisper.emitError('error_no_match', permanent: false);
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.voiceErrorNoMatch), findsOneWidget);
    ScaffoldMessenger.of(tester.element(micOf('first')))
        .removeCurrentSnackBar();
    await tester.pump();

    whisper.initGate = Completer<void>();
    await tapMicOf('first');
    await tapMicOf('second');
    whisper.initGate!.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text(l10n.voiceErrorNoMatch), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('first')),
        matching: find.byKey(VoiceInputButton.startingKey),
      ),
      findsNothing,
    );
    expect(tester.widget<IconButton>(micOf('second')).isSelected, isTrue);
  });

  testWidgets('Offline only without Whisper is explained', (tester) async {
    privacy = PrivacyMode.offlineOnly;
    service = SpeechInputService(
      store: MemoryStore(),
      adapter: system,
      privacyMode: () => privacy,
      platformSupported: true,
      onDeviceSupported: true,
    );
    await pump(tester, withRouter: true);
    await tapMic(tester);
    expect(find.text(l10n.voiceErrorOfflineOnly), findsOneWidget);
    expect(find.byType(SnackBarAction), findsNothing);
    expect(system.initCalls, 0);
  });
}
