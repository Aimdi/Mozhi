import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_captions/cubit/live_captions_cubit.dart';
import 'package:mozhi/live_captions/data/captions_host.dart';
import 'package:mozhi/live_captions/view/live_captions_page.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_picker_sheet.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';
import 'package:mozhi/voice/widgets/voice_error_message.dart'
    show voiceSettingsLocation;
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

class _MockTranslateCubit extends MockCubit<TranslateState>
    implements TranslateCubit;

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

class _MockFiles extends Mock implements DocumentFileService;

class _MockRouter extends Mock implements GoRouter;

class _FakeHistoryEntry extends Fake implements HistoryEntry;

void main() {
  late FakeCaptionsHost host;
  late FakeCaptionRecognizer recognizer;
  late FakeOverlayControls overlay;
  late MockTranslationRepository repository;
  late MockDeviceConditions conditions;
  late MockHistoryCubit history;
  late _MockTranslateCubit translate;
  late _MockSettingsCubit settings;
  late _MockFiles files;
  late List<String> shared;
  late int pickerOpened;
  late AppLocalizations l10n;

  setUpAll(() {
    registerFallbackValue(deepl);
    registerFallbackValue(
      const TranslationRequest(text: '', source: english, target: german),
    );
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(_FakeHistoryEntry());
  });

  setUp(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
    host = FakeCaptionsHost();
    recognizer = FakeCaptionRecognizer();
    overlay = FakeOverlayControls();
    repository = MockTranslationRepository();
    conditions = MockDeviceConditions();
    history = MockHistoryCubit();
    translate = _MockTranslateCubit();
    settings = _MockSettingsCubit();
    files = _MockFiles();
    shared = [];
    pickerOpened = 0;
    when(() => conditions.latest).thenReturn(DeviceConditionsSnapshot.unknown);
    when(() => conditions.changes).thenAnswer((_) => const Stream.empty());
    when(() => repository.destinationOf(any())).thenAnswer(
      (invocation) => invocation.positionalArguments.first == deepl.id
          ? const PublicInstanceDestination('mozhi.example.org')
          : const OnDeviceDestination(),
    );
    when(() => repository.translate(any(), any())).thenAnswer((invocation) {
      final request = invocation.positionalArguments[1] as TranslationRequest;
      return Stream.value(resultOf('Hello (${request.text})'));
    });
    when(() => history.state).thenReturn(const HistoryState());
    when(() => history.add(any())).thenAnswer((_) async {});
    when(() => translate.state).thenReturn(
      TranslateState(
        engines: [offlineEngine, deepl],
        engine: deepl,
        source: spanish,
      ),
    );
    when(() => settings.state).thenReturn(const AppSettings());
    when(
      () => files.saveFile(
        fileName: any(named: 'fileName'),
        bytes: any(named: 'bytes'),
        mimeType: any(named: 'mimeType'),
      ),
    ).thenAnswer((_) async => true);
  });

  tearDown(() => host.dispose());

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(420, 900),
    GoRouter? router,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget page = LiveCaptionsPage(
      host: () async => host,
      recognizer: recognizer,
      overlay: overlay,
      conditions: conditions,
      files: files,
      share: (text, {subject, origin}) async => shared.add(text),
      openEnginePicker: (context) async => pickerOpened++,
    );
    if (router != null) page = InheritedGoRouter(goRouter: router, child: page);
    await tester.pumpWidget(
      RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TranslateCubit>.value(value: translate),
            BlocProvider<SettingsCubit>.value(value: settings),
            BlocProvider<HistoryCubit>.value(value: history),
          ],
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: page,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  LiveCaptionsCubit cubitOf(WidgetTester tester) =>
      tester.element(find.byType(LiveCaptionsView)).read<LiveCaptionsCubit>();

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('live_captions_start')));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('explains what is captured, with the languages and engine', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text(l10n.liveCaptionsTitle), findsOneWidget);
    expect(find.byKey(const Key('live_captions_about')), findsOneWidget);
    expect(find.text(l10n.liveCaptionsAboutPrivacy), findsOneWidget);
    expect(find.text(l10n.liveCaptionsAboutConsent), findsOneWidget);
    expect(
      find.text(l10n.liveCaptionsSourceValue(Language.auto.name)),
      findsOneWidget,
    );
    expect(find.text(l10n.liveCaptionsTargetValue('English')), findsOneWidget);
    // The offline engine by default: nothing leaves the phone.
    expect(find.text(offlineEngine.name), findsOneWidget);
    expect(find.text(l10n.liveCaptionsEngineOnDevice), findsOneWidget);
    expect(find.text(l10n.liveCaptionsStatusIdle), findsOneWidget);
    // Nothing to copy yet.
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('live_captions_copy')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('the engine chip opens the live engine picker', (tester) async {
    when(() => settings.state).thenReturn(AppSettings(liveEngineId: deepl.id));
    await pump(tester);
    expect(find.text('DeepL'), findsOneWidget);
    expect(
      find.text(l10n.liveCaptionsEngineSent('mozhi.example.org')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('live_captions_engine')));
    await tester.pump();
    expect(pickerOpened, 1);
  });

  testWidgets('the language chips open the language picker', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('live_captions_target')));
    await tester.pumpAndSettle();
    expect(find.byType(LanguagePickerSheet), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live_captions_source')));
    await tester.pumpAndSettle();
    expect(find.byType(LanguagePickerSheet), findsOneWidget);
  });

  testWidgets('captions, shows the transcript and stops', (tester) async {
    await pump(tester);
    await start(tester);
    expect(host.starts, 1);
    expect(find.text(l10n.liveCaptionsStatusListening), findsOneWidget);
    expect(find.byKey(const Key('live_captions_stop')), findsOneWidget);
    // The source cannot change while captioning.
    expect(
      tester
          .widget<ActionChip>(find.byKey(const Key('live_captions_source')))
          .onPressed,
      isNull,
    );

    recognizer.recording.phrase('Hola', language: 'es');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('live_captions_transcript')), findsOneWidget);
    expect(find.text('Hola'), findsOneWidget);
    expect(find.text('Hello (Hola)'), findsOneWidget);
    expect(find.text(l10n.liveCaptionsDetected('Spanish')), findsOneWidget);

    await tester.tap(find.byKey(const Key('live_captions_stop')));
    await tester.pump();
    expect(host.stops, 1);
    expect(find.text(l10n.liveCaptionsStatusIdle), findsOneWidget);
    // The transcript stays.
    expect(find.text('Hola'), findsOneWidget);
  });

  testWidgets('says why it pauses and what it waits for', (tester) async {
    await pump(tester);
    await start(tester);
    host.sendEvent(CaptionBarEvent.deviceLocked);
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.liveCaptionsStatusLocked), findsOneWidget);
    host.sendEvent(CaptionBarEvent.deviceUnlocked);
    await tester.pump();
    recognizer.recording.pending = 3;
    host.sendAudio(block());
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.liveCaptionsPending(3)), findsOneWidget);
    for (var i = 0; i < 200; i++) {
      host.sendAudio(block(0));
    }
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('live_captions_silence')), findsOneWidget);
    expect(find.text(l10n.liveCaptionsSilenceHint), findsOneWidget);
  });

  testWidgets('a hot phone pauses the captions', (tester) async {
    when(
      () => conditions.latest,
    ).thenReturn(const DeviceConditionsSnapshot(thermal: ThermalStatus.severe));
    await pump(tester);
    await start(tester);
    expect(find.text(l10n.liveCaptionsStatusHot), findsOneWidget);
    expect(host.bar, CaptionLine.notice(l10n.liveCaptionsBarHot));
  });

  testWidgets('the bar speaks the app language', (tester) async {
    await pump(tester);
    await start(tester);
    expect(host.bar, CaptionLine.notice(l10n.liveCaptionsBarListening));
    for (var i = 0; i < 200; i++) {
      host.sendAudio(block(0));
    }
    await tester.pump();
    expect(host.bar, CaptionLine.notice(l10n.liveCaptionsBarSilence));
  });

  group('the caption bar permission', () {
    setUp(() => overlay.canDrawOverlays = false);

    testWidgets('"Only on this screen" captions here', (tester) async {
      host.startResult = const CaptureStarted(captionBar: false);
      await pump(tester);
      await start(tester);
      expect(find.text(l10n.liveCaptionsOverlayTitle), findsOneWidget);
      await tester.tap(find.byKey(const Key('live_captions_overlay_skip')));
      await tester.pumpAndSettle();
      expect(overlay.overlayRequests, 0);
      expect(find.byKey(const Key('live_captions_no_bar')), findsOneWidget);
      expect(find.text(l10n.liveCaptionsNoBar), findsOneWidget);
    });

    testWidgets('"Open the setting" asks Android, then captions', (
      tester,
    ) async {
      await pump(tester);
      await start(tester);
      await tester.tap(find.byKey(const Key('live_captions_overlay_allow')));
      await tester.pumpAndSettle();
      expect(overlay.overlayRequests, 1);
      expect(find.byKey(const Key('live_captions_stop')), findsOneWidget);
      expect(find.byKey(const Key('live_captions_no_bar')), findsNothing);
    });

    testWidgets('dismissed, nothing starts', (tester) async {
      await pump(tester);
      await start(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(host.starts, 0);
      expect(find.byKey(const Key('live_captions_start')), findsOneWidget);
    });
  });

  group('messages', () {
    for (final (result, message) in [
      (const CaptureDeclined(), 'declined'),
      (const CaptureFailed(CaptureFailure.permission), 'permission'),
      (const CaptureFailed(CaptureFailure.audio), 'failed'),
    ]) {
      testWidgets('a start that does not happen: $message', (tester) async {
        host.startResult = result;
        await pump(tester);
        await start(tester);
        await tester.pump();
        expect(
          find.text(switch (message) {
            'declined' => l10n.liveCaptionsDeclined,
            'permission' => l10n.liveCaptionsPermissionDenied,
            _ => l10n.liveCaptionsStartFailed,
          }),
          findsOneWidget,
        );
      });
    }

    testWidgets('a capture that ends by itself', (tester) async {
      await pump(tester);
      await start(tester);
      host.sendEvent(CaptionBarEvent.captureEnded);
      await tester.pump();
      await tester.pump();
      expect(find.text(l10n.liveCaptionsEnded), findsOneWidget);
    });
  });

  group('the transcript', () {
    Future<void> withPhrase(WidgetTester tester) async {
      await pump(tester);
      await start(tester);
      recognizer.recording
        ..phrase('Hola', language: 'es')
        ..phrase('', status: PhraseStatus.skipped)
        ..phrase('', status: PhraseStatus.failed);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('shows skipped and failed phrases', (tester) async {
      await withPhrase(tester);
      expect(find.text(l10n.transcribeSkipped), findsOneWidget);
      expect(find.text(l10n.transcribePhraseFailed), findsOneWidget);
    });

    testWidgets('is saved to History only when asked', (tester) async {
      await withPhrase(tester);
      verifyNever(() => history.add(any()));
      await tester.tap(find.byKey(const Key('live_captions_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_captions_menu_history')));
      await tester.pumpAndSettle();
      verify(() => history.add(any())).called(1);
      expect(find.text(l10n.transcribeSavedHistory), findsOneWidget);
    });

    testWidgets('is saved as text and subtitles, and shared', (tester) async {
      await withPhrase(tester);
      for (final action in ['saveText', 'saveSubtitles']) {
        await tester.tap(find.byKey(const Key('live_captions_menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('live_captions_menu_$action')));
        await tester.pumpAndSettle();
      }
      final names = verify(
        () => files.saveFile(
          fileName: captureAny(named: 'fileName'),
          bytes: any(named: 'bytes'),
          mimeType: any(named: 'mimeType'),
        ),
      ).captured;
      expect(names.first as String, endsWith('.txt'));
      expect(names.last as String, endsWith('.srt'));
      expect(find.text(l10n.transcribeFileSaved), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_captions_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_captions_menu_share')));
      await tester.pumpAndSettle();
      expect(shared.single, contains('Hola'));
      expect(shared.single, contains('Hello (Hola)'));
    });

    testWidgets('a file that cannot be saved says so', (tester) async {
      when(
        () => files.saveFile(
          fileName: any(named: 'fileName'),
          bytes: any(named: 'bytes'),
          mimeType: any(named: 'mimeType'),
        ),
      ).thenThrow(StateError('disk'));
      await withPhrase(tester);
      await tester.tap(find.byKey(const Key('live_captions_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_captions_menu_saveText')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.transcribeFileFailed), findsOneWidget);
    });

    testWidgets('is copied', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
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
      await withPhrase(tester);
      await tester.tap(find.byKey(const Key('live_captions_copy')));
      await tester.pumpAndSettle();
      expect(copied.single, contains('Hello (Hola)'));
    });

    testWidgets('is cleared after a confirmation, once stopped', (
      tester,
    ) async {
      await withPhrase(tester);
      await tester.tap(find.byKey(const Key('live_captions_stop')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('live_captions_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_captions_menu_clear')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.transcribeClearTitle), findsOneWidget);
      await tester.tap(find.byKey(const Key('live_captions_clear_confirm')));
      await tester.pumpAndSettle();
      expect(cubitOf(tester).state.entries, isEmpty);
      expect(find.byKey(const Key('live_captions_about')), findsOneWidget);
    });

    testWidgets('a failed translation offers Retry', (tester) async {
      var fail = true;
      when(() => repository.translate(any(), any())).thenAnswer((_) {
        if (fail) return Stream.error(StateError('offline'));
        return Stream.value(resultOf('Hello'));
      });
      await pump(tester);
      await start(tester);
      recognizer.recording.phrase('Hola', language: 'es');
      await tester.pump();
      await tester.pump();
      expect(find.text(l10n.transcribeTranslationFailed), findsOneWidget);
      fail = false;
      await tester.tap(find.byKey(const Key('live_captions_retry_0')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Hello'), findsOneWidget);
    });

    testWidgets('a translation waiting for consent asks inline', (
      tester,
    ) async {
      when(() => repository.translate(any(), any())).thenAnswer(
        (_) => Stream.error(
          const ConsentRequiredException(
            kind: ConsentKind.pair,
            destination: PublicInstanceDestination('mozhi.example.org'),
            engineId: 'mozhi:deepl',
            source: 'es',
            target: 'en',
          ),
        ),
      );
      await pump(tester);
      await start(tester);
      recognizer.recording
        ..phrase('Hola', language: 'es')
        ..phrase('Adiós', language: 'es', index: 1);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('live_captions_consent_1')), findsOneWidget);
      expect(find.text(l10n.transcribeTranslationWaiting), findsOneWidget);
    });

    testWidgets('an old phrase that was skipped says so', (tester) async {
      await pump(tester);
      await start(tester);
      for (var i = 0; i < 5; i++) {
        recognizer.recording.phrase('$i', language: 'es', index: i);
      }
      await tester.pump();
      await tester.pump();
      expect(find.text(l10n.liveCaptionsBehind), findsNWidgets(2));
    });

    testWidgets('sits beside the translation on wide screens', (tester) async {
      await pump(tester, size: const Size(1200, 900));
      await start(tester);
      recognizer.recording.phrase('Hola', language: 'es');
      await tester.pump();
      await tester.pump();
      final original = tester.getTopLeft(find.text('Hola'));
      final translated = tester.getTopLeft(find.text('Hello (Hola)'));
      expect(translated.dx, greaterThan(original.dx));
      expect(translated.dy, original.dy);
    });
  });

  group('unavailable', () {
    testWidgets('off Android 10+', (tester) async {
      host = FakeCaptionsHost(isSupported: false);
      await pump(tester);
      expect(
        find.byKey(const Key('live_captions_unavailable_unsupported')),
        findsOneWidget,
      );
      expect(find.text(l10n.liveCaptionsUnsupportedTitle), findsOneWidget);
      expect(find.byKey(const Key('live_captions_menu')), findsNothing);
    });

    testWidgets('without the speech model: the voice settings offer one', (
      tester,
    ) async {
      recognizer.ready = false;
      final router = _MockRouter();
      when(() => router.push<void>(any())).thenAnswer((_) async {
        recognizer.ready = true;
      });
      await pump(tester, router: router);
      expect(find.text(l10n.liveCaptionsNeedsModelTitle), findsOneWidget);
      await tester.tap(find.byKey(const Key('live_captions_download_model')));
      await tester.pumpAndSettle();
      verify(() => router.push<void>(voiceSettingsLocation)).called(1);
      expect(find.byKey(const Key('live_captions_start')), findsOneWidget);
    });

    testWidgets('loading, the page waits for the host', (tester) async {
      final pending = Completer<FakeCaptionsHost>();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LiveCaptionsPage(host: () => pending.future),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text(l10n.liveCaptionsTitle), findsOneWidget);
    });
  });

  testWidgets('leaving the page stops the captions', (tester) async {
    await pump(tester);
    await start(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(host.stops, 1);
  });

  testWidgets('captions go on while the app is in the background', (
    tester,
  ) async {
    await pump(tester);
    await start(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(host.stops, 0);
    expect(cubitOf(tester).state.isRunning, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });
}
