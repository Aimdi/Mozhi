import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;

import '../../helpers/helpers.dart';
import '../helpers/fake_speech_recognizer.dart';

class _ThrowingStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async => throw StateError('read');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('write');

  @override
  Future<void> delete(String key) async {}
}

void main() {
  late FakeSpeechRecognizer browser;
  late MemoryStore store;
  late PrivacyMode privacy;

  final l10n = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    browser = FakeSpeechRecognizer();
    store = MemoryStore();
    privacy = PrivacyMode.online;
  });

  SpeechInputService build({bool isWeb = true, KeyValueStore? keyValueStore}) =>
      SpeechInputService(
        store: keyValueStore ?? store,
        adapter: browser,
        privacyMode: () => privacy,
        platformSupported: true,
        onDeviceSupported: false,
        isWeb: isWeb,
      );

  group('SpeechInputService', () {
    test('the web app tells about the browser once', () async {
      final service = build();
      expect(service.usesBrowserRecognizer, isTrue);
      expect(await service.needsBrowserNotice(), isTrue);
      await service.acceptBrowserNotice();
      expect(await service.needsBrowserNotice(), isFalse);
      expect(store.values[SpeechInputService.browserNoticeKey], 'true');
      // Also after a restart.
      expect(await build().needsBrowserNotice(), isFalse);
    });

    test('the Android app has no browser to tell about', () async {
      final service = build(isWeb: false);
      expect(service.usesBrowserRecognizer, isFalse);
      expect(await service.needsBrowserNotice(), isFalse);
    });

    test('nothing to tell in Offline only (no browser recogniser)', () async {
      privacy = PrivacyMode.offlineOnly;
      expect(await build().needsBrowserNotice(), isFalse);
    });

    test(
      'a failing store asks, and remembers the answer for the run',
      () async {
        final service = build(keyValueStore: _ThrowingStore());
        expect(await service.needsBrowserNotice(), isTrue);
        await service.acceptBrowserNotice();
        expect(await service.needsBrowserNotice(), isFalse);
      },
    );

    test('"Delete all local data" asks again', () async {
      final service = build(keyValueStore: _ThrowingStore());
      await service.acceptBrowserNotice();
      service.forgetSettings();
      expect(await service.needsBrowserNotice(), isTrue);
    });

    test('a disposed service asks nothing', () async {
      final service = build();
      await service.dispose();
      expect(await service.needsBrowserNotice(), isFalse);
    });
  });

  group('VoiceInputButton in the web app', () {
    late SpeechInputService service;

    setUp(() => service = build());

    Future<void> pump(WidgetTester tester) => tester.pumpApp(
      Scaffold(
        body: Center(
          child: VoiceInputButton.standalone(
            service: service,
            languageCode: 'en',
            onResult: (text, {required isFinal}) {},
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
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('says where the audio goes before the first session', (
      tester,
    ) async {
      await pump(tester);
      await tapMic(tester);
      expect(find.byType(BrowserSpeechNoticeDialog), findsOneWidget);
      expect(find.text(l10n.voiceBrowserNoticeTitle), findsOneWidget);
      expect(find.text(l10n.voiceBrowserNoticeBody), findsOneWidget);
      // Nothing listens before the answer.
      expect(browser.initCalls, 0);

      await tester.tap(find.byKey(BrowserSpeechNoticeDialog.continueKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(browser.requests, hasLength(1));
      expect(tester.widget<IconButton>(mic()).isSelected, isTrue);

      // Stop, and the next session starts right away.
      await tapMic(tester);
      await tapMic(tester);
      expect(find.byType(BrowserSpeechNoticeDialog), findsNothing);
      expect(browser.requests, hasLength(2));
    });

    testWidgets('Cancel does not listen and asks again next time', (
      tester,
    ) async {
      await pump(tester);
      await tapMic(tester);
      await tester.tap(find.text(l10n.commonCancel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(BrowserSpeechNoticeDialog), findsNothing);
      expect(browser.initCalls, 0);
      expect(store.values, isEmpty);

      await tapMic(tester);
      expect(find.byType(BrowserSpeechNoticeDialog), findsOneWidget);
    });
  });

  group('voiceInputErrorMessage', () {
    test('a browser without speech recognition says so', () {
      expect(
        voiceInputErrorMessage(
          l10n,
          SpeechInputFailure.recognizerUnavailable,
          isWeb: true,
        ),
        l10n.voiceErrorUnavailableBrowser,
      );
      expect(
        voiceInputErrorMessage(
          l10n,
          SpeechInputFailure.recognizerUnavailable,
          isWeb: false,
        ),
        l10n.voiceErrorUnavailable,
      );
    });
  });
}
