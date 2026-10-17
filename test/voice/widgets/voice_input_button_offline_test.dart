import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

import '../../helpers/helpers.dart';
import '../helpers/fake_offline_recognizer.dart';
import '../helpers/fake_speech_recognizer.dart';

void main() {
  late FakeSpeechRecognizer system;
  late FakeOfflineRecognizer whisper;
  late PrivacyMode privacy;
  late SpeechInputService service;
  late List<(String, bool)> received;
  late List<bool> listeningChanges;

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
  });

  Future<void> pump(WidgetTester tester) => tester.pumpApp(
    Scaffold(
      body: Center(
        child: VoiceInputButton.standalone(
          service: service,
          languageCode: 'de',
          onResult: (text, {required isFinal}) => received.add((text, isFinal)),
          onListeningChanged: listeningChanges.add,
        ),
      ),
    ),
  );

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
    await pump(tester);
    await tapMic(tester);
    expect(find.text(l10n.voiceErrorOfflineOnly), findsOneWidget);
    expect(system.initCalls, 0);
  });
}
