import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/transcribe/transcribe.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/voice/voice.dart';
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
  late MockTranslationRepository repository;
  late MockOfflineSpeech offline;
  late MockHistoryCubit history;
  late _MockTranslateCubit translate;
  late _MockSettingsCubit settings;
  late _MockFiles files;
  late FakeTranscriber transcriber;
  late FakeScreenAwake awake;
  late List<String> shared;
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
    repository = MockTranslationRepository();
    offline = MockOfflineSpeech();
    history = MockHistoryCubit();
    translate = _MockTranslateCubit();
    settings = _MockSettingsCubit();
    files = _MockFiles();
    transcriber = FakeTranscriber();
    awake = FakeScreenAwake();
    shared = [];
    when(() => repository.privacyMode).thenReturn(PrivacyMode.online);
    when(() => repository.destinationOf(any()))
        .thenReturn(const CloudProviderDestination('DeepL'));
    when(() => repository.translate(any(), any())).thenAnswer(
      (_) => Stream.value(
        const TranslationResult(
          engineId: 'mozhi:deepl',
          engineName: 'DeepL',
          text: 'Hallo',
        ),
      ),
    );
    when(() => offline.isAvailable).thenReturn(true);
    when(offline.isReady).thenAnswer((_) async => true);
    when(() => offline.vadModel).thenReturn(null);
    when(() => history.state).thenReturn(const HistoryState());
    when(() => history.add(any())).thenAnswer((_) async {});
    when(() => translate.state).thenReturn(
      const TranslateState(
        engines: [deepl],
        engine: deepl,
        source: english,
        target: german,
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

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    bool withOffline = true,
    GoRouter? router,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget page = TranscribePage(
      transcriber: (_) => transcriber,
      screenAwake: awake,
      files: files,
      share: (text, {subject, origin}) async => shared.add(text),
    );
    if (router != null) page = InheritedGoRouter(goRouter: router, child: page);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<TranslationRepository>.value(value: repository),
          if (withOffline)
            RepositoryProvider<OfflineSpeech>.value(value: offline),
        ],
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

  Future<void> startListening(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('transcribe_mic')));
    await tester.pump();
    transcriber.emit(const TranscriberListening());
    await tester.pump();
  }

  testWidgets('starts empty and says where speech goes', (tester) async {
    await pump(tester);
    expect(find.text(l10n.transcribeTitle), findsOneWidget);
    expect(find.byKey(const Key('transcribe_empty')), findsOneWidget);
    expect(find.text(l10n.transcribeOnDevice), findsOneWidget);
    expect(find.text(l10n.transcribeTranslateOff), findsOneWidget);
    expect(find.text(l10n.transcribeStatusIdle), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('transcribe_mic')))
          .tooltip,
      l10n.transcribeStart,
    );
    // Nothing to copy yet.
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('transcribe_copy')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('listens, shows the phrases, pauses and stops', (tester) async {
    await pump(tester);
    await startListening(tester);
    expect(awake.calls, [true]);
    expect(find.text(l10n.transcribeStatusListening), findsOneWidget);
    expect(find.text(l10n.transcribeKeepsScreenOn), findsOneWidget);
    expect(find.byKey(const Key('transcribe_level')), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('transcribe_mic')))
          .tooltip,
      l10n.transcribePause,
    );

    transcriber
      ..emit(const TranscriberLevel(0.5, heardSpeech: true))
      ..emit(const TranscriberPartial('Welcome'))
      ..emit(const TranscriberPending(2));
    await tester.pump();
    expect(find.text(l10n.transcribeStatusHearing), findsOneWidget);
    expect(find.byKey(const Key('transcribe_partial')), findsOneWidget);
    expect(find.text(l10n.transcribePending(2)), findsOneWidget);

    transcriber
      ..heard('Welcome to the museum.', start: 65, end: 68)
      ..heard('', start: 70, end: 72, status: PhraseStatus.skipped)
      ..heard('', start: 72, end: 73, status: PhraseStatus.failed);
    await tester.pump();
    expect(find.text('Welcome to the museum.'), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    expect(find.bySemanticsLabel(l10n.transcribeTimeLabel('1:05')), findsOne);
    expect(find.text(l10n.transcribeSkipped), findsOneWidget);
    expect(find.text(l10n.transcribePhraseFailed), findsOneWidget);

    await tester.tap(find.byKey(const Key('transcribe_mic')));
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.transcribeStatusPaused), findsOneWidget);
    expect(transcriber.stops, 1);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('transcribe_mic')))
          .tooltip,
      l10n.transcribeResume,
    );

    await tester.tap(find.byKey(const Key('transcribe_stop')));
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.transcribeStatusIdle), findsOneWidget);
    expect(find.byKey(const Key('transcribe_stop')), findsNothing);
  });

  testWidgets('translation is off until turned on, then says where '
      'phrases go', (tester) async {
    await pump(tester);
    await startListening(tester);
    transcriber.heard('Hello.', start: 0, end: 1);
    await tester.pump();
    verifyNever(() => repository.translate(any(), any()));

    await tester.tap(find.byKey(const Key('transcribe_translate')));
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.transcribeTranslateInto('German')), findsOneWidget);
    expect(find.text(l10n.transcribeTranslatedBy('DeepL')), findsOneWidget);
    expect(find.text('Hallo'), findsOneWidget);
    expect(find.byKey(const Key('transcribe_target')), findsOneWidget);
  });

  testWidgets('says when phrases are translated on the device', (tester) async {
    when(() => repository.destinationOf(any()))
        .thenReturn(const OnDeviceDestination());
    await pump(tester);
    await tester.tap(find.byKey(const Key('transcribe_translate')));
    await tester.pump();
    expect(find.text(l10n.transcribeTranslatedOnDevice), findsOneWidget);
  });

  testWidgets('a failed translation offers a retry; one needing consent '
      'asks', (tester) async {
    var calls = 0;
    when(() => repository.translate(any(), any())).thenAnswer((_) {
      calls++;
      return calls == 1
          ? Stream.error(Exception('down'))
          : Stream.error(
              const ConsentRequiredException(
                kind: ConsentKind.cloudProvider,
                destination: CloudProviderDestination('DeepL'),
                engineId: 'mozhi:deepl',
              ),
            );
    });
    await pump(tester);
    await startListening(tester);
    transcriber.heard('Hello.', start: 0, end: 1);
    await tester.pump();
    await tester.tap(find.byKey(const Key('transcribe_translate')));
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.transcribeTranslationFailed), findsOneWidget);
    await tester.tap(find.byKey(const Key('transcribe_retry_0')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('transcribe_consent_0')), findsOneWidget);
  });

  testWidgets('copies, shares, saves files and saves to History', (
    tester,
  ) async {
    await pump(tester);
    await startListening(tester);
    transcriber.heard('Hello.', start: 0, end: 1);
    await tester.pump();

    await tester.tap(find.byKey(const Key('transcribe_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('transcribe_menu_share')));
    await tester.pumpAndSettle();
    expect(shared.single, contains('[0:00] Hello.'));

    await tester.tap(find.byKey(const Key('transcribe_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('transcribe_menu_saveSubtitles')));
    await tester.pumpAndSettle();
    final saved = verify(
      () => files.saveFile(
        fileName: captureAny(named: 'fileName'),
        bytes: any(named: 'bytes'),
        mimeType: captureAny(named: 'mimeType'),
      ),
    ).captured;
    expect(saved.first as String, endsWith('.srt'));
    expect(saved.last, TranscriptExport.srtMimeType);
    expect(find.text(l10n.transcribeFileSaved), findsOneWidget);

    when(
      () => files.saveFile(
        fileName: any(named: 'fileName'),
        bytes: any(named: 'bytes'),
        mimeType: any(named: 'mimeType'),
      ),
    ).thenThrow(Exception('disk'));
    await tester.tap(find.byKey(const Key('transcribe_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('transcribe_menu_saveText')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.transcribeFileFailed), findsOneWidget);

    await tester.tap(find.byKey(const Key('transcribe_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('transcribe_menu_history')));
    await tester.pumpAndSettle();
    verify(() => history.add(any())).called(1);
    expect(find.text(l10n.transcribeSavedHistory), findsOneWidget);

    await tester.tap(find.byKey(const Key('transcribe_copy')));
    await tester.pumpAndSettle();
  });

  testWidgets('clears the transcript after asking', (tester) async {
    await pump(tester);
    await startListening(tester);
    transcriber.heard('Hello.', start: 0, end: 1);
    await tester.pump();
    await tester.tap(find.byKey(const Key('transcribe_stop')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('transcribe_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('transcribe_menu_clear')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.transcribeClearTitle), findsOneWidget);
    await tester.tap(find.byKey(const Key('transcribe_clear_confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('transcribe_empty')), findsOneWidget);
  });

  testWidgets('explains a listening failure', (tester) async {
    await pump(tester);
    await startListening(tester);
    transcriber.emit(
      const TranscriberFailed(SpeechInputFailure.permissionDenied),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.voiceErrorPermission), findsOneWidget);
  });

  testWidgets('needs the offline model: opens the voice settings', (
    tester,
  ) async {
    when(offline.isReady).thenAnswer((_) async => false);
    final router = _MockRouter();
    when(() => router.push<void>(any())).thenAnswer((_) async {});
    await pump(tester, router: router);
    expect(find.text(l10n.transcribeNeedsModelTitle), findsOneWidget);
    expect(find.byKey(const Key('transcribe_copy')), findsNothing);
    await tester.tap(find.byKey(const Key('transcribe_download_model')));
    await tester.pump();
    verify(() => router.push<void>(voiceSettingsLocation)).called(1);
  });

  testWidgets('unavailable without any recogniser', (tester) async {
    await pump(tester, withOffline: false);
    expect(find.text(l10n.transcribeUnavailableTitle), findsOneWidget);
  });

  testWidgets('offers speech detection and downloads it', (tester) async {
    when(() => offline.vadModel).thenReturn(null);
    final cubit = TranscribeCubit(
      repository: repository,
      engine: () => deepl,
      source: english,
      target: german,
      offline: offline,
      screenAwake: awake,
      transcriber: (_) => transcriber,
    );
    when(
      () => offline.downloadVoiceDetection(
        overMeteredNetwork: any(named: 'overMeteredNetwork'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenThrow(const VoiceModelMeteredException());
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await cubit.load();
    cubit.emit(cubit.state.copyWith(voiceDetectionMissing: true));
    await tester.pumpWidget(
      RepositoryProvider<TranslationRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TranslateCubit>.value(value: translate),
            BlocProvider<SettingsCubit>.value(value: settings),
            BlocProvider<TranscribeCubit>.value(value: cubit),
          ],
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: TranscribeView(),
          ),
        ),
      ),
    );
    expect(find.text(l10n.transcribeVadMissing), findsOneWidget);
    await tester.tap(find.byKey(const Key('transcribe_vad_download')));
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.transcribeVadMetered), findsOneWidget);
    expect(find.text(l10n.transcribeVadDownloadAnyway), findsOneWidget);
    when(
      () => offline.downloadVoiceDetection(
        overMeteredNetwork: any(named: 'overMeteredNetwork'),
        onProgress: any(named: 'onProgress'),
      ),
    ).thenThrow(Exception('offline'));
    await tester.tap(find.byKey(const Key('transcribe_vad_download')));
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.transcribeVadFailed), findsWidgets);
    await cubit.close();
  });

  testWidgets('wide screens put the translation beside the phrase', (
    tester,
  ) async {
    await pump(tester, size: const Size(1200, 800));
    await startListening(tester);
    await tester.tap(find.byKey(const Key('transcribe_translate')));
    await tester.pump();
    transcriber.heard('Hello.', start: 0, end: 1);
    await tester.pump();
    await tester.pump();
    final hello = tester.getTopLeft(find.text('Hello.'));
    final hallo = tester.getTopLeft(find.text('Hallo'));
    expect(hallo.dy, hello.dy);
    expect(hallo.dx, greaterThan(hello.dx));
  });

  testWidgets('pauses when the app is hidden', (tester) async {
    await pump(tester);
    await startListening(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.transcribeStatusBackground), findsOneWidget);
    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('leaving the page stops listening', (tester) async {
    await pump(tester);
    await startListening(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(transcriber.cancels, 1);
    expect(awake.calls.last, isFalse);
  });
}
