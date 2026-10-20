import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/voice.dart';

import '../../helpers/helpers.dart';
import '../helpers/fake_speech_recognizer.dart';

class _MockGoRouter extends Mock implements GoRouter;

void main() {
  late FakeSpeechRecognizer recognizer;
  late MemoryStore store;
  late SpeechInputService service;
  late List<(String, bool)> received;
  late List<bool> listeningChanges;

  final l10n = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    recognizer = FakeSpeechRecognizer();
    store = MemoryStore();
    service = SpeechInputService(
      store: store,
      adapter: recognizer,
      platformSupported: true,
      onDeviceSupported: true,
    );
    received = [];
    listeningChanges = [];
  });

  void onResult(String text, {required bool isFinal}) =>
      received.add((text, isFinal));

  Widget button({
    Key? key,
    String? languageCode = 'en',
    bool? preferOnDevice,
    SpeechInputService? using,
    bool prominent = false,
  }) => VoiceInputButton.standalone(
    key: key,
    service: using ?? service,
    languageCode: languageCode,
    preferOnDevice: preferOnDevice,
    onResult: onResult,
    onListeningChanged: listeningChanges.add,
    prominent: prominent,
  );

  Future<void> pump(WidgetTester tester, Widget child, {GoRouter? router}) {
    Widget page = Scaffold(body: Center(child: child));
    if (router != null) page = InheritedGoRouter(goRouter: router, child: page);
    return tester.pumpApp(page);
  }

  Finder mic() => find.descendant(
    of: find.byType(VoiceInputButton),
    matching: find.byType(IconButton),
  );

  IconButton iconButton(WidgetTester tester, [int index = 0]) =>
      tester.widgetList<IconButton>(mic()).elementAt(index);

  Finder ring() => find.byKey(VoiceInputButton.levelRingKey);

  double ringScale(WidgetTester tester) =>
      tester.widget<AnimatedScale>(ring()).scale;

  double renderedScale(WidgetTester tester) => tester
      .widget<ScaleTransition>(
        find.descendant(of: ring(), matching: find.byType(ScaleTransition)),
      )
      .scale
      .value;

  Future<void> tapMic(WidgetTester tester) async {
    await tester.tap(mic().first);
    await tester.pump();
    await tester.pump();
  }

  /// Dismisses the snack bar at once (so the next one can be found).
  Future<void> dismissSnackBar(WidgetTester tester) async {
    ScaffoldMessenger.of(tester.element(mic())).removeCurrentSnackBar();
    await tester.pump();
  }

  void expectOff(WidgetTester tester) {
    expect(mic(), findsOneWidget);
    expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
    final off = iconButton(tester);
    expect(off.tooltip, l10n.voiceInputUnavailable);
    expect(off.onPressed, isNotNull);
    expect(tester.getSize(find.byType(VoiceInputButton)), const Size(48, 48));
  }

  group(VoiceInputButton, () {
    testWidgets('shows a mic button before the recogniser is initialised', (
      tester,
    ) async {
      await pump(tester, button());
      final mic = iconButton(tester);
      expect(mic.tooltip, l10n.voiceInputStart);
      expect(mic.isSelected, isFalse);
      expect(find.byIcon(Icons.mic_none_outlined), findsOneWidget);
      expect(ring(), findsNothing);
      expect(recognizer.initCalls, 0);
      expect(find.byTooltip(l10n.voiceInputStart), findsOneWidget);
      expect(tester.getSize(find.byType(VoiceInputButton)), const Size(48, 48));
    });

    testWidgets('is hidden on unsupported platforms', (tester) async {
      final unsupported = SpeechInputService(
        store: store,
        adapter: recognizer,
        platformSupported: false,
      );
      await pump(tester, button(using: unsupported));
      expect(mic(), findsNothing);
      expect(tester.getSize(find.byType(VoiceInputButton)), Size.zero);
    });

    testWidgets('stays as an off mic and explains when permission is '
        'denied', (tester) async {
      recognizer
        ..initResult = false
        ..permission = false;
      await pump(tester, button());
      await tapMic(tester);
      await tester.pump();

      expectOff(tester);
      expect(find.text(l10n.voiceErrorPermission), findsOneWidget);
      expect(find.byType(SnackBarAction), findsNothing);
      expect(received, isEmpty);
    });

    testWidgets('tapping the off mic tries again and explains again', (
      tester,
    ) async {
      recognizer
        ..initResult = false
        ..permission = false;
      await pump(tester, button());
      await tapMic(tester);
      await dismissSnackBar(tester);
      expect(find.text(l10n.voiceErrorPermission), findsNothing);

      await tapMic(tester);
      await tester.pump();
      expect(recognizer.initCalls, 2);
      expect(find.text(l10n.voiceErrorPermission), findsOneWidget);
      expectOff(tester);

      // Granted at the prompt this time.
      recognizer
        ..initResult = true
        ..permission = true;
      await tapMic(tester);
      expect(iconButton(tester).isSelected, isTrue);
      expect(find.byIcon(Icons.mic_off_outlined), findsNothing);
      expect(listeningChanges, [true]);
    });

    testWidgets('explains when no recogniser is available, without an '
        'offline model to offer', (tester) async {
      recognizer.initResult = false;
      final router = _MockGoRouter();
      await pump(tester, button(), router: router);
      await tapMic(tester);
      await tester.pump();

      expectOff(tester);
      expect(find.text(l10n.voiceErrorUnavailable), findsOneWidget);
      expect(find.byType(SnackBarAction), findsNothing);
    });

    testWidgets('is back to normal on resume once permission is granted', (
      tester,
    ) async {
      recognizer
        ..initResult = false
        ..permission = false;
      await pump(tester, button());
      await tapMic(tester);
      expectOff(tester);

      recognizer.permission = true;
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.mic_off_outlined), findsNothing);
      expect(find.byIcon(Icons.mic_none_outlined), findsOneWidget);
      expect(iconButton(tester).tooltip, l10n.voiceInputStart);
    });

    testWidgets('shows progress while starting; a second tap gives up', (
      tester,
    ) async {
      recognizer.initGate = Completer<void>();
      await pump(tester, button());
      await tester.tap(mic());
      await tester.pump();

      expect(find.byKey(VoiceInputButton.startingKey), findsOneWidget);
      expect(find.bySemanticsLabel(l10n.voiceInputStarting), findsOneWidget);
      expect(iconButton(tester).tooltip, l10n.voiceInputCancelStart);
      expect(iconButton(tester).isSelected, isFalse);
      expect(listeningChanges, isEmpty);

      await tapMic(tester);
      expect(find.byKey(VoiceInputButton.startingKey), findsNothing);
      expect(iconButton(tester).tooltip, l10n.voiceInputStart);

      recognizer.initGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(recognizer.requests, isEmpty);
      expect(service.isListening, isFalse);
      expect(find.byKey(VoiceInputButton.startingKey), findsNothing);
      expect(listeningChanges, isEmpty);
    });

    testWidgets('giving up a retry of the off mic shows no error', (
      tester,
    ) async {
      recognizer.initResult = false;
      await pump(tester, button());
      await tapMic(tester);
      await dismissSnackBar(tester);

      recognizer.initGate = Completer<void>();
      await tester.tap(mic());
      await tester.pump();
      // Trying again: progress instead of the off mic.
      expect(find.byKey(VoiceInputButton.startingKey), findsOneWidget);
      expect(find.byIcon(Icons.mic_off_outlined), findsNothing);

      await tapMic(tester);
      recognizer.initGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      expectOff(tester);
    });

    testWidgets('starts listening in the chosen language when the '
        'recogniser never lists its locales', (tester) async {
      recognizer.localesGate = Completer<void>();
      await pump(tester, button(languageCode: 'fr'));
      await tester.tap(mic());
      await tester.pump();
      expect(find.byKey(VoiceInputButton.startingKey), findsOneWidget);
      expect(recognizer.requests, isEmpty);

      await tester.pump(SpeechInputService.defaultQueryTimeout);
      await tester.pump();
      expect(recognizer.lastRequest.localeId, 'fr-FR');
      expect(iconButton(tester).isSelected, isTrue);
      expect(find.byKey(VoiceInputButton.startingKey), findsNothing);
      expect(listeningChanges, [true]);

      // The next session starts right away.
      await tapMic(tester);
      await tapMic(tester);
      expect(recognizer.requests, hasLength(2));
      expect(recognizer.localeCalls, 1);
    });

    testWidgets('cancels a session that is still starting when removed', (
      tester,
    ) async {
      recognizer.initGate = Completer<void>();
      await pump(tester, button());
      await tester.tap(mic());
      await tester.pump();
      await pump(tester, const SizedBox());

      recognizer.initGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(recognizer.requests, isEmpty);
      expect(service.isListening, isFalse);
    });

    testWidgets('listens, shows the level ring and forwards results', (
      tester,
    ) async {
      await pump(tester, button(languageCode: 'pt'));
      await tapMic(tester);

      expect(recognizer.lastRequest.localeId, 'pt_BR');
      expect(listeningChanges, [true]);
      final mic = iconButton(tester);
      expect(mic.isSelected, isTrue);
      expect(mic.tooltip, l10n.voiceInputStop);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(ring(), findsOneWidget);
      expect(ringScale(tester), 1);
      expect(find.bySemanticsLabel(l10n.voiceInputListening), findsOneWidget);

      recognizer.emitResult('olá');
      await tester.pump();
      expect(received, [('olá', false)]);

      recognizer.emitResult('Olá mundo', isFinal: true);
      await tester.pump();
      expect(received, [('olá', false), ('Olá mundo', true)]);
      expect(ring(), findsNothing);
      expect(iconButton(tester).isSelected, isFalse);
      expect(listeningChanges, [true, false]);
    });

    testWidgets('scales the ring with the sound level', (tester) async {
      await pump(tester, button());
      await tapMic(tester);

      recognizer
        ..emitLevel(0)
        ..emitLevel(10);
      await tester.pump();
      expect(ringScale(tester), 1.5);
      // The pulsing ring repeats, so wait for the scale instead of settling.
      await tester.pump(const Duration(milliseconds: 300));
      expect(renderedScale(tester), 1.5);

      recognizer.emitLevel(5);
      // The first pump delivers the state (no frame was scheduled), the
      // second builds it.
      await tester.pump();
      await tester.pump();
      expect(ringScale(tester), 1.25);

      // The scale animates rather than jumping.
      await tester.pump(const Duration(milliseconds: 60));
      expect(renderedScale(tester), inExclusiveRange(1.25, 1.5));
      // The pulsing ring repeats, so wait for the scale instead of settling.
      await tester.pump(const Duration(milliseconds: 300));
      expect(renderedScale(tester), 1.25);
    });

    testWidgets('pulses an accent ring while listening', (tester) async {
      await pump(tester, button());
      expect(find.byKey(VoiceInputButton.pulseRingKey), findsNothing);
      await tapMic(tester);
      expect(find.byKey(VoiceInputButton.pulseRingKey), findsOneWidget);
      double pulseScale() => tester
          .widget<Transform>(
            find.descendant(
              of: find.byKey(VoiceInputButton.pulseRingKey),
              matching: find.byType(Transform),
            ),
          )
          .transform
          .getMaxScaleOnAxis();
      final start = pulseScale();
      await tester.pump(const Duration(milliseconds: 700));
      expect(pulseScale(), greaterThan(start));
      expect(
        tester.widget<IconButton>(mic()).style?.backgroundColor?.resolve({}),
        Theme.of(tester.element(mic())).colorScheme.primary,
      );
      await tapMic(tester);
      expect(find.byKey(VoiceInputButton.pulseRingKey), findsNothing);
    });

    testWidgets('keeps the ring static when animations are disabled', (
      tester,
    ) async {
      await tester.pumpApp(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(body: Center(child: button())),
        ),
      );
      await tapMic(tester);
      recognizer
        ..emitLevel(0)
        ..emitLevel(10);
      await tester.pump();
      expect(ringScale(tester), 1.15);
      expect(find.byKey(VoiceInputButton.pulseRingKey), findsNothing);
    });

    testWidgets('stops listening when tapped again', (tester) async {
      await pump(tester, button());
      await tapMic(tester);
      await tapMic(tester);

      expect(recognizer.stopCalls, 1);
      expect(ring(), findsNothing);

      recognizer.emitResult('final words', isFinal: true);
      await tester.pump();
      expect(received, [('final words', true)]);
    });

    testWidgets('passes the on-device override', (tester) async {
      await pump(tester, button(preferOnDevice: true));
      await tapMic(tester);
      expect(recognizer.lastRequest.onDevice, isTrue);
    });

    testWidgets('shows a snackbar for session errors', (tester) async {
      await pump(tester, button());
      await tapMic(tester);
      recognizer.emitError('error_no_match');
      await tester.pump();
      await tester.pump();

      expect(find.text(l10n.voiceErrorNoMatch), findsOneWidget);
      expect(ring(), findsNothing);
      expect(mic(), findsOneWidget);
    });

    testWidgets('uses the on-device wording for missing languages', (
      tester,
    ) async {
      store.values[SpeechInputService.preferOnDeviceKey] = 'true';
      await pump(tester, button());
      await tapMic(tester);
      recognizer.emitError('error_language_unavailable');
      await tester.pump();
      await tester.pump();

      expect(find.text(l10n.voiceErrorLanguageOnDevice), findsOneWidget);
    });

    testWidgets('only the button that started listening reacts', (
      tester,
    ) async {
      await pump(
        tester,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            button(key: const Key('first')),
            VoiceInputButton.standalone(
              key: const Key('second'),
              service: service,
              languageCode: 'fr',
              onResult: (text, {required isFinal}) {},
            ),
          ],
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('second')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(ring(), findsOneWidget);
      expect(iconButton(tester).isSelected, isFalse);
      expect(iconButton(tester, 1).isSelected, isTrue);

      recognizer
        ..emitResult('bonjour', isFinal: true)
        ..emitError('error_no_match');
      await tester.pump();
      await tester.pump();
      expect(received, isEmpty);
      expect(listeningChanges, isEmpty);
    });

    testWidgets('cancels its session when removed', (tester) async {
      await pump(tester, button());
      await tapMic(tester);
      await pump(tester, const SizedBox());
      expect(recognizer.cancelCalls, 1);
      expect(service.isListening, isFalse);
    });

    testWidgets('stops listening when the app is hidden', (tester) async {
      await pump(tester, button());
      await tapMic(tester);
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(recognizer.stopCalls, 1);
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('switches to a new service', (tester) async {
      final other = SpeechInputService(
        store: store,
        adapter: FakeSpeechRecognizer()..initResult = false,
        platformSupported: false,
      );
      await pump(tester, button());
      await tapMic(tester);
      await pump(tester, button(using: other));
      expect(recognizer.cancelCalls, 1);
      expect(mic(), findsNothing);
    });

    testWidgets('reads the service from the context', (tester) async {
      await tester.pumpApp(
        RepositoryProvider.value(
          value: service,
          child: Scaffold(
            body: VoiceInputButton(languageCode: 'fr', onResult: onResult),
          ),
        ),
      );
      await tapMic(tester);
      expect(recognizer.lastRequest.localeId, 'fr_FR');
      recognizer.emitResult('salut', isFinal: true);
      await tester.pump();
      expect(received, [('salut', true)]);
    });

    testWidgets('works without a ScaffoldMessenger', (tester) async {
      recognizer.initResult = false;
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFF000000),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
            settings: settings,
            pageBuilder: (context, _, _) => builder(context),
          ),
          home: Material(child: Center(child: button())),
        ),
      );
      await tapMic(tester);
      await tester.pump();
      expect(mic(), findsOneWidget);
      expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('prominent VoiceInputButton', () {
    const size = Size.square(VoiceInputButton.prominentSize);

    ButtonStyle styleOf(WidgetTester tester) => iconButton(tester).style!;

    Color? background(WidgetTester tester) =>
        styleOf(tester).backgroundColor?.resolve(const {});

    testWidgets('is a large filled accent circle', (tester) async {
      await pump(tester, button(prominent: true));
      final scheme = Theme.of(tester.element(mic())).colorScheme;

      expect(tester.getSize(find.byType(VoiceInputButton)), size);
      expect(tester.getSize(mic()), size);
      expect(iconButton(tester).iconSize, 36);
      expect(iconButton(tester).tooltip, l10n.voiceInputStart);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(background(tester), scheme.primary);
      expect(
        styleOf(tester).foregroundColor?.resolve(const {}),
        scheme.onPrimary,
      );
    });

    testWidgets('sizes its rings while listening', (tester) async {
      await pump(tester, button(prominent: true));
      await tapMic(tester);

      expect(iconButton(tester).isSelected, isTrue);
      expect(iconButton(tester).tooltip, l10n.voiceInputStop);
      expect(tester.getSize(ring()), size);
      expect(tester.getSize(find.byKey(VoiceInputButton.pulseRingKey)), size);
      recognizer.emitResult('hi', isFinal: true);
      await tester.pump();
      expect(received, [('hi', true)]);
    });

    testWidgets('shows a large progress ring while starting', (tester) async {
      recognizer.initGate = Completer<void>();
      await pump(tester, button(prominent: true));
      await tester.tap(mic());
      await tester.pump();

      expect(
        tester.getSize(find.byKey(VoiceInputButton.startingKey)),
        const Size.square(VoiceInputButton.prominentSize - 4),
      );
      recognizer.initGate!.complete();
      await tester.pump();
      await tester.pump();
    });

    testWidgets('turns neutral while voice input is unavailable', (
      tester,
    ) async {
      recognizer.initResult = false;
      await pump(tester, button(prominent: true));
      await tapMic(tester);
      final scheme = Theme.of(tester.element(mic())).colorScheme;

      expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
      expect(background(tester), scheme.surfaceContainerHighest);
      expect(
        styleOf(tester).foregroundColor?.resolve(const {}),
        scheme.onSurfaceVariant,
      );
      expect(tester.getSize(find.byType(VoiceInputButton)), size);
    });
  });

  group('voiceInputErrorMessage', () {
    test('has a message for every failure', () {
      expect(
        {
          for (final failure in SpeechInputFailure.values)
            failure: voiceInputErrorMessage(l10n, failure),
        },
        {
          SpeechInputFailure.permissionDenied: l10n.voiceErrorPermission,
          SpeechInputFailure.languageUnavailable: l10n.voiceErrorLanguage,
          SpeechInputFailure.recognizerUnavailable: l10n.voiceErrorUnavailable,
          SpeechInputFailure.audio: l10n.voiceErrorAudio,
          SpeechInputFailure.noMatch: l10n.voiceErrorNoMatch,
          SpeechInputFailure.network: l10n.voiceErrorNetwork,
          SpeechInputFailure.busy: l10n.voiceErrorBusy,
          SpeechInputFailure.offlineModelMissing: l10n.voiceErrorOfflineModel,
          SpeechInputFailure.offlineUnavailable: l10n.voiceErrorOfflineOnly,
          SpeechInputFailure.unknown: l10n.voiceErrorGeneric,
        },
      );
      expect(
        voiceInputErrorMessage(
          l10n,
          SpeechInputFailure.languageUnavailable,
          onDevice: true,
        ),
        l10n.voiceErrorLanguageOnDevice,
      );
      expect(
        voiceInputErrorMessage(
          l10n,
          SpeechInputFailure.recognizerUnavailable,
          offlineModelDownloadable: true,
        ),
        l10n.voiceErrorUnavailableOfflineModel,
      );
    });

    test('an offline model helps when it is missing or replaces a missing '
        'recogniser', () {
      for (final offlineSupported in [true, false]) {
        expect(
          {
            for (final failure in SpeechInputFailure.values)
              if (voiceInputFailureNeedsOfflineModel(
                failure,
                offlineSupported: offlineSupported,
              ))
                failure,
          },
          {
            SpeechInputFailure.offlineModelMissing,
            if (offlineSupported) SpeechInputFailure.recognizerUnavailable,
          },
          reason: 'offlineSupported: $offlineSupported',
        );
      }
    });
  });
}
