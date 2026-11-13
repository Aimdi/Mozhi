import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/voice.dart';

import '../../helpers/helpers.dart';
import '../helpers/fake_speech_recognizer.dart';

/// Voice input in the web app: what is said about the browser's
/// recogniser.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('voiceInputErrorMessage in the web app', () {
    test('gives the browser advice, not the device one', () {
      String web(SpeechInputFailure failure, {bool onDevice = false}) =>
          voiceInputErrorMessage(
            l10n,
            failure,
            onDevice: onDevice,
            isWeb: true,
          );
      String android(SpeechInputFailure failure) =>
          voiceInputErrorMessage(l10n, failure, isWeb: false);

      expect(
        web(SpeechInputFailure.permissionDenied),
        l10n.voiceErrorPermissionWeb,
      );
      expect(
        android(SpeechInputFailure.permissionDenied),
        l10n.voiceErrorPermission,
      );
      expect(
        web(SpeechInputFailure.languageUnavailable, onDevice: true),
        l10n.voiceErrorLanguageWeb,
      );
      expect(
        android(SpeechInputFailure.languageUnavailable),
        l10n.voiceErrorLanguage,
      );
      expect(web(SpeechInputFailure.network), l10n.voiceErrorNetworkWeb);
      expect(android(SpeechInputFailure.network), l10n.voiceErrorNetwork);
    });
  });

  group('VoiceInputButton for Detect language in the web app', () {
    late FakeSpeechRecognizer recognizer;
    late SpeechInputService service;

    setUp(() {
      recognizer = FakeSpeechRecognizer()..localeList = const [];
      service = SpeechInputService(
        store: MemoryStore({SpeechInputService.browserNoticeKey: 'true'}),
        adapter: recognizer,
        platformSupported: true,
        isWeb: true,
        browserRecognizerAvailable: true,
        deviceLocale: () => 'de-DE',
      );
    });

    tearDown(() => service.dispose());

    Future<void> pump(WidgetTester tester, String language) => tester.pumpApp(
      Scaffold(
        body: Center(
          child: VoiceInputButton.standalone(
            service: service,
            languageCode: language,
            onResult: (_, {required isFinal}) {},
          ),
        ),
      ),
    );

    Finder mic() => find.descendant(
      of: find.byType(VoiceInputButton),
      matching: find.byType(IconButton),
    );

    testWidgets('says once in which language it listens', (tester) async {
      await pump(tester, 'auto');
      await tester.tap(mic());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final hint = l10n.voiceInputAssumedLanguage('German');
      expect(find.text(hint), findsOneWidget);
      expect(recognizer.lastRequest.localeId, 'de-DE');

      // Stop; the next session is not explained again.
      await tester.tap(mic());
      recognizer.emitStatus(SpeechRecognizerStatus.notListening);
      await tester.pump();
      ScaffoldMessenger.of(tester.element(find.byType(VoiceInputButton)))
          .removeCurrentSnackBar();
      await tester.pump();
      await tester.tap(mic());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(hint), findsNothing);
    });

    testWidgets('a chosen language needs no explanation', (tester) async {
      await pump(tester, 'fr');
      await tester.tap(mic());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
