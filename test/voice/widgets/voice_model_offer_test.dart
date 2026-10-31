import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/voice.dart';
import 'package:translation_repository/translation_repository.dart'
    show PrivacyMode;
import 'package:whisper_speech/whisper_speech.dart';

import '../../helpers/helpers.dart';
import '../helpers/fake_offline_recognizer.dart';
import '../helpers/fake_speech_recognizer.dart';

class _MockOfflineSpeech extends Mock implements OfflineSpeech;

class _MockGoRouter extends Mock implements GoRouter;

/// The catalogue's Fast model (`tiny`, 77,691,713 bytes: "74 MB").
final _tiny = WhisperCatalogModel(
  id: 'tiny',
  name: 'ggml-tiny.bin',
  url: Uri.parse('https://models.example/ggml-tiny.bin'),
  size: 77691713,
  sha1: 'a' * 40,
);
final _base = WhisperCatalogModel(
  id: 'base',
  name: 'ggml-base.bin',
  url: Uri.parse('https://models.example/ggml-base.bin'),
  size: 147951465,
  sha1: 'b' * 40,
);

void main() {
  late FakeSpeechRecognizer system;
  late FakeOfflineRecognizer whisper;
  late SpeechInputService service;
  late _MockOfflineSpeech offline;
  late _MockGoRouter router;
  late Set<String> installed;
  late List<(String, bool)> received;
  late Future<void> Function(String id, {required bool overMetered}) onDownload;
  late PrivacyMode privacy;

  final l10n = lookupAppLocalizations(const Locale('en'));
  const size = '74.1 MB';

  setUp(() {
    system = FakeSpeechRecognizer();
    whisper = FakeOfflineRecognizer()..ready = false;
    privacy = PrivacyMode.offlineFirst;
    service = SpeechInputService(
      store: MemoryStore(),
      adapter: system,
      offlineAdapter: whisper,
      privacyMode: () => privacy,
      platformSupported: true,
      onDeviceSupported: true,
    );
    // A de-Googled phone: no speech recognition service.
    system.initResult = false;
    offline = _MockOfflineSpeech();
    router = _MockGoRouter();
    installed = {};
    received = [];
    onDownload = (id, {required overMetered}) async {
      installed.add(id);
      whisper.ready = true;
    };
    when(() => router.push<void>(any(), extra: any(named: 'extra')))
        .thenAnswer((_) async {});
    when(() => offline.isAvailable).thenReturn(true);
    when(() => offline.models).thenReturn([_tiny, _base]);
    when(() => offline.memory).thenReturn(null);
    when(() => offline.vadModel).thenReturn(null);
    when(() => offline.engineBuild).thenReturn(null);
    when(offline.isVadReady).thenAnswer((_) async => false);
    when(offline.wifiOnly).thenAnswer((_) async => true);
    when(offline.installed).thenAnswer((_) async => {...installed});
    when(offline.selected)
        .thenAnswer((_) async => installed.isEmpty ? null : installed.last);
    when(
      () => offline.download(
        any(),
        overMeteredNetwork: any(named: 'overMeteredNetwork'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenAnswer((invocation) async {
      final progress =
          invocation.namedArguments[#onProgress] as void Function(double)?;
      progress?.call(0.5);
      await onDownload(
        invocation.positionalArguments.single as String,
        overMetered:
            invocation.namedArguments[#overMeteredNetwork] as bool? ?? false,
      );
    });
  });

  Future<void> pump(
    WidgetTester tester, {
    bool withRouter = true,
    bool withOffline = true,
  }) {
    Widget page = Scaffold(
      body: Center(
        child: VoiceInputButton.standalone(
          service: service,
          languageCode: 'en',
          onResult: (text, {required isFinal}) => received.add((text, isFinal)),
        ),
      ),
    );
    if (withOffline) {
      page = RepositoryProvider<OfflineSpeech>.value(
        value: offline,
        child: page,
      );
    }
    if (withRouter) page = InheritedGoRouter(goRouter: router, child: page);
    return tester.pumpApp(page);
  }

  Finder mic() => find.descendant(
    of: find.byType(VoiceInputButton),
    matching: find.byType(IconButton),
  );

  /// Pumps until the dialog came or went (the listening mic keeps
  /// pulsing, so it never settles).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tapMic(WidgetTester tester) async {
    await tester.tap(mic());
    await settle(tester);
  }

  Future<void> download(WidgetTester tester) async {
    await tester.tap(find.byKey(VoiceModelOfferDialog.downloadKey));
    await settle(tester);
  }

  group('without a speech recognition service', () {
    testWidgets('the mic offers the Fast model with its size', (tester) async {
      await pump(tester);
      await tapMic(tester);

      expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
      expect(find.text(l10n.voiceOfferTitle), findsOneWidget);
      expect(
        find.text(l10n.voiceOfferBodyNoRecognizer(l10n.voiceModelFast, size)),
        findsOneWidget,
      );
      expect(find.text(l10n.voiceOfferDownload(size)), findsOneWidget);
      // "Download over Wi-Fi only" is on.
      expect(find.text(l10n.voiceOfferWifiNote), findsOneWidget);
      // Not the snack bar of before.
      expect(find.text(l10n.voiceErrorUnavailableOfflineModel), findsNothing);
    });

    testWidgets('downloading installs it and starts listening', (tester) async {
      final gate = Completer<void>();
      onDownload = (id, {required overMetered}) async {
        await gate.future;
        installed.add(id);
        whisper.ready = true;
      };
      await pump(tester);
      await tapMic(tester);
      await tester.tap(find.byKey(VoiceModelOfferDialog.downloadKey));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(VoiceModelOfferDialog.progressKey), findsOneWidget);
      expect(find.text(l10n.voiceModelDownloading(50)), findsOneWidget);
      expect(find.text(l10n.voiceOfferBackground), findsOneWidget);
      expect(find.byKey(VoiceModelOfferDialog.downloadKey), findsNothing);

      gate.complete();
      await settle(tester);
      verify(
        () => offline.download('tiny', onProgress: any(named: 'onProgress')),
      ).called(1);
      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      // Whisper took over the session the user asked for.
      expect(whisper.requests.length, 1);
      expect(tester.widget<IconButton>(mic()).isSelected, isTrue);

      whisper.emitResult('Hello there', isFinal: true);
      await settle(tester);
      expect(received, [('Hello there', true)]);
    });

    testWidgets('a download that finishes in the background does not listen', (
      tester,
    ) async {
      final gate = Completer<void>();
      onDownload = (id, {required overMetered}) async {
        await gate.future;
        installed.add(id);
        whisper.ready = true;
      };
      await pump(tester);
      await tapMic(tester);
      await tester.tap(find.byKey(VoiceModelOfferDialog.downloadKey));
      await tester.pump();
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      gate.complete();
      await settle(tester);
      // Back in front: the download is in, and the microphone is still off.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);

      expect(installed, ['tiny']);
      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(whisper.requests, isEmpty);
      expect(tester.widget<IconButton>(mic()).isSelected, isFalse);
    });

    testWidgets('asks before using mobile data', (tester) async {
      onDownload = (id, {required overMetered}) async {
        if (!overMetered) throw const VoiceModelMeteredException();
        installed.add(id);
        whisper.ready = true;
      };
      await pump(tester);
      await tapMic(tester);
      await download(tester);

      expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
      expect(
        find.text(l10n.voiceModelMeteredBody(l10n.voiceModelFast, size)),
        findsOneWidget,
      );
      expect(find.text(l10n.offlineMeteredDownloadAnyway), findsOneWidget);
      expect(whisper.requests.length, 0);

      await download(tester);
      verify(
        () => offline.download(
          'tiny',
          overMeteredNetwork: true,
          onProgress: any(named: 'onProgress'),
        ),
      ).called(1);
      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(whisper.requests.length, 1);
    });

    testWidgets('a failed download is explained and can be tried again', (
      tester,
    ) async {
      var attempts = 0;
      onDownload = (id, {required overMetered}) async {
        if (attempts++ == 0) {
          throw const WhisperDownloadException('tiny', 'offline');
        }
        installed.add(id);
        whisper.ready = true;
      };
      await pump(tester);
      await tapMic(tester);
      await download(tester);

      expect(
        find.text(l10n.voiceModelErrorNetwork(l10n.voiceModelFast)),
        findsOneWidget,
      );
      expect(find.text(l10n.voiceOfferDownload(size)), findsOneWidget);
      await download(tester);
      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(whisper.requests.length, 1);
    });

    testWidgets('"Not now" closes it without listening', (tester) async {
      await pump(tester);
      await tapMic(tester);
      await tester.tap(find.text(l10n.voiceOfferNotNow));
      await tester.pumpAndSettle();
      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(whisper.requests.length, 0);
      verifyNever(
        () => offline.download(
          any(),
          overMeteredNetwork: any(named: 'overMeteredNetwork'),
          onProgress: any(named: 'onProgress'),
        ),
      );
      // Offered again on the next tap.
      await tapMic(tester);
      expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
    });

    testWidgets('"Other models" opens the voice input settings', (
      tester,
    ) async {
      await pump(tester);
      await tapMic(tester);
      await tester.tap(find.text(l10n.voiceOfferOtherModels));
      await tester.pumpAndSettle();
      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      verify(
        () => router.push<void>(
          VoiceInputButton.settingsLocation,
          extra: any(named: 'extra'),
        ),
      ).called(1);
    });

    testWidgets('without a router there is no "Other models"', (tester) async {
      await pump(tester, withRouter: false);
      await tapMic(tester);
      expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
      expect(find.text(l10n.voiceOfferOtherModels), findsNothing);
    });

    testWidgets('"Continue in background" lets the download go on', (
      tester,
    ) async {
      final gate = Completer<void>();
      onDownload = (id, {required overMetered}) async {
        await gate.future;
        installed.add(id);
        whisper.ready = true;
      };
      await pump(tester);
      await tapMic(tester);
      await tester.tap(find.byKey(VoiceModelOfferDialog.downloadKey));
      await tester.pump();
      await tester.tap(find.text(l10n.voiceOfferBackground));
      await tester.pumpAndSettle();
      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(whisper.requests.length, 0);

      gate.complete();
      await settle(tester);
      // The service was told: the next tap listens with Whisper.
      await tapMic(tester);
      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(whisper.requests.length, 1);
    });

    testWidgets('a model the device has no memory for is not offered', (
      tester,
    ) async {
      // Only the bigger model is listed (fastest first): it is the one.
      when(() => offline.models).thenReturn([_base]);
      await pump(tester);
      await tapMic(tester);
      expect(
        find.text(
          l10n.voiceOfferBodyNoRecognizer(l10n.voiceModelBetter, '141.1 MB'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the size includes the speech detector the first time', (
      tester,
    ) async {
      when(() => offline.vadModel).thenReturn(
        WhisperCatalogModel(
          id: 'silero-vad',
          name: 'ggml-silero-v6.2.0.bin',
          url: Uri.parse('https://models.example/vad.bin'),
          size: 885098,
          sha1: 'c' * 40,
        ),
      );
      await pump(tester);
      await tapMic(tester);
      expect(find.text(l10n.voiceOfferDownload('74.9 MB')), findsOneWidget);
    });

    testWidgets('where Whisper cannot run, the snack bar explains', (
      tester,
    ) async {
      when(() => offline.isAvailable).thenReturn(false);
      await pump(tester);
      await tapMic(tester);
      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(find.text(l10n.voiceErrorUnavailableOfflineModel), findsOneWidget);
    });

    testWidgets('without the offline speech, the snack bar explains', (
      tester,
    ) async {
      await pump(tester, withOffline: false);
      await tapMic(tester);
      expect(find.byType(VoiceModelOfferDialog), findsNothing);
      expect(find.text(l10n.voiceErrorUnavailableOfflineModel), findsOneWidget);
    });
  });

  testWidgets('Whisper chosen without a model offers it too', (tester) async {
    system.initResult = true;
    await service.setEngine(VoiceInputEngine.whisper);
    await pump(tester);
    await tapMic(tester);
    expect(
      find.text(l10n.voiceOfferBody(l10n.voiceModelFast, size)),
      findsOneWidget,
    );
    await download(tester);
    expect(whisper.requests.length, 1);
    expect(system.requests.length, 0);
  });

  testWidgets('Offline only without a model offers it', (tester) async {
    system.initResult = true;
    privacy = PrivacyMode.offlineOnly;
    await pump(tester);
    await tapMic(tester);
    expect(
      find.text(l10n.voiceOfferBody(l10n.voiceModelFast, size)),
      findsOneWidget,
    );
    expect(system.initCalls, 0);
  });

  testWidgets('a model that still does not work is explained, not offered '
      'again', (tester) async {
    // Listed as installed, but the engine does not take it.
    installed.add('tiny');
    await pump(tester);
    await tapMic(tester);
    expect(find.byType(VoiceModelOfferDialog), findsNothing);
    expect(find.text(l10n.voiceErrorUnavailableOfflineModel), findsOneWidget);
    expect(whisper.requests, isEmpty);
  });

  testWidgets('the snack bar\'s "Download model" opens the offer', (
    tester,
  ) async {
    await tester.pumpApp(
      RepositoryProvider<SpeechInputService>.value(
        value: service,
        child: RepositoryProvider<OfflineSpeech>.value(
          value: offline,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showVoiceInputErrorSnackBar(
                  context,
                  SpeechInputFailure.offlineModelMissing,
                  onDevice: false,
                  offlineSupported: true,
                ),
                child: const Text('fail'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('fail'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.voiceErrorOfflineModel), findsOneWidget);
    await tester.tap(
      find.widgetWithText(SnackBarAction, l10n.voiceDownloadModelAction),
    );
    await tester.pumpAndSettle();
    expect(find.byType(VoiceModelOfferDialog), findsOneWidget);
    await download(tester);
    expect(find.byType(VoiceModelOfferDialog), findsNothing);
    expect(installed, {'tiny'});
  });
}
