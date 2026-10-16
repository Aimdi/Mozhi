import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/voice.dart';

import '../../helpers/helpers.dart';
import '../helpers/fake_speech_recognizer.dart';

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
  }) => VoiceInputButton.standalone(
    key: key,
    service: using ?? service,
    languageCode: languageCode,
    preferOnDevice: preferOnDevice,
    onResult: onResult,
    onListeningChanged: listeningChanges.add,
  );

  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpApp(Scaffold(body: Center(child: child)));

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

    testWidgets('hides itself and explains when permission is denied', (
      tester,
    ) async {
      recognizer
        ..initResult = false
        ..permission = false;
      await pump(tester, button());
      await tapMic(tester);
      await tester.pump();

      expect(mic(), findsNothing);
      expect(find.text(l10n.voiceErrorPermission), findsOneWidget);
      expect(received, isEmpty);
    });

    testWidgets('explains when no recogniser is available', (tester) async {
      recognizer.initResult = false;
      await pump(tester, button());
      await tapMic(tester);
      await tester.pump();

      expect(mic(), findsNothing);
      expect(find.text(l10n.voiceErrorUnavailable), findsOneWidget);
    });

    testWidgets('reappears on resume once permission is granted', (
      tester,
    ) async {
      recognizer
        ..initResult = false
        ..permission = false;
      await pump(tester, button());
      await tapMic(tester);
      expect(mic(), findsNothing);

      recognizer.permission = true;
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(mic(), findsOneWidget);
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
      expect(mic(), findsNothing);
      expect(tester.takeException(), isNull);
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
    });
  });
}
