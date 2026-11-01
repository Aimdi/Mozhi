import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/voice.dart';

import '../../helpers/helpers.dart';
import '../helpers/fake_speech_recognizer.dart';

/// The translate screen's microphone in a browser without speech
/// recognition (Firefox and its forks).
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  late FakeSpeechRecognizer recognizer;
  late SpeechInputService service;

  setUp(() {
    recognizer = FakeSpeechRecognizer();
    service = SpeechInputService(
      store: MemoryStore(),
      adapter: recognizer,
      platformSupported: true,
      isWeb: true,
      browserRecognizerAvailable: false,
    );
  });

  tearDown(() => service.dispose());

  Finder mic() => find.descendant(
    of: find.byType(VoiceInputButton),
    matching: find.byType(IconButton),
  );

  Future<void> pump(WidgetTester tester) => tester.pumpApp(
    Scaffold(
      body: Center(
        child: VoiceInputButton.standalone(
          service: service,
          languageCode: 'en',
          onResult: (_, {required isFinal}) {},
        ),
      ),
    ),
  );

  testWidgets('shows a crossed-out mic before the first tap', (tester) async {
    await pump(tester);

    expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
    expect(
      tester.widget<IconButton>(mic()).tooltip,
      l10n.voiceInputUnavailable,
    );
  });

  testWidgets('a tap explains it without the privacy notice', (tester) async {
    await pump(tester);
    await tester.tap(mic());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(BrowserSpeechNoticeDialog), findsNothing);
    // In the web app this reads voiceErrorUnavailableBrowser (kIsWeb).
    expect(find.text(l10n.voiceErrorUnavailable), findsOneWidget);
    expect(recognizer.initCalls, 0);
  });
}
