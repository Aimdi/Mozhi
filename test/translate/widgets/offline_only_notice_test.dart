import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

/// A Mozhi request (DeepL, English → German) "Offline only" stopped.
const _offlineOnly = ConsentRequiredException(
  kind: ConsentKind.offlineOnly,
  destination: PublicInstanceDestination('mozhi.example.org', engine: 'deepl'),
  engineId: 'mozhi:deepl',
  source: 'en',
  target: 'de',
);

/// The engine list "Offline only" kept from loading (no language pair).
const _offlineOnlyLists = ConsentRequiredException(
  kind: ConsentKind.offlineOnly,
  destination: PublicInstanceDestination('mozhi.example.org'),
  engineId: 'mozhi:',
);

const _noPacks =
    'No language packs on this device yet. Download one to translate '
    'offline.';
const _web =
    'Offline translation isn’t available in the web app. Switch to Offline '
    'first or Online in Settings › Privacy.';
const _device =
    'This device can’t run offline translation. Switch to Offline first or '
    'Online in Settings › Privacy.';
const _needsNetwork = 'Offline only is on, and this engine needs the network.';

/// Not the Android app (the web app: no on-device engine at all).
final _notAndroid = TargetPlatformVariant.only(TargetPlatform.linux);

TranslateState _held(
  ConsentRequiredException consent, {
  bool automatic = true,
}) => readyState(input: 'Hello world', target: german).copyWith(
  consent: () =>
      ConsentRequest(exception: consent, id: 1, automatic: automatic),
);

void main() {
  setUpAll(registerTranslateFallbacks);

  TranslateHarness harnessFor(TranslateState state) {
    final harness = TranslateHarness(state: state);
    when(() => harness.repository.instances).thenReturn(const []);
    return harness;
  }

  group('offlineOnlyGap', () {
    test('no language pack yet on a device that runs the engine', () async {
      expect(
        await offlineOnlyGap(FakeOfflineTranslator()),
        OfflineOnlyGap.noLanguagePacks,
      );
      // Unreadable storage: nothing to translate with either.
      expect(
        await offlineOnlyGap(
          FakeOfflineTranslator(downloaded: {'de'}, fails: true),
        ),
        OfflineOnlyGap.noLanguagePacks,
      );
    });

    test('nothing once a language pack is there', () async {
      expect(
        await offlineOnlyGap(FakeOfflineTranslator(downloaded: {'de'})),
        isNull,
      );
    });

    test('the Android app on a device that cannot run the engine', () async {
      expect(
        await offlineOnlyGap(FakeOfflineTranslator(isAvailable: false)),
        OfflineOnlyGap.unsupportedDevice,
      );
      expect(offlineEngineGap(null), OfflineOnlyGap.unsupportedDevice);
      expect(offlineEngineGap(FakeOfflineTranslator()), isNull);
    });

    test('the web app has no engine', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        expect(await offlineOnlyGap(null), OfflineOnlyGap.webApp);
        expect(
          offlineEngineGap(FakeOfflineTranslator(isAvailable: false)),
          OfflineOnlyGap.webApp,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('TranslateErrorView', () {
    testWidgets('no language packs: offers the download', (tester) async {
      final offline = FakeOfflineTranslator();
      final harness = harnessFor(readyState());
      await harness.pump(
        tester,
        child: const TranslateErrorView(error: _offlineOnly),
        offline: offline,
      );
      // The device is checked first.
      expect(find.text(_noPacks), findsNothing);
      await tester.pump();
      expect(find.text(_noPacks), findsOneWidget);
      expect(find.text(_needsNetwork), findsNothing);
      expect(
        find.byKey(const Key('translate_offline_only_notice')),
        findsOneWidget,
      );
      // The pair's language.
      expect(find.text('Download German'), findsOneWidget);

      // Back from the offline languages with German: the usual prompt.
      offline.downloaded.add('de');
      await tester.tap(
        find.byKey(const Key('translate_offline_only_download')),
      );
      verify(() => harness.router.push<void>('/settings/offline')).called(1);
      await tester.pump();
      await tester.pump();
      expect(find.text(_noPacks), findsNothing);
      expect(find.text(_needsNetwork), findsOneWidget);
    });

    testWidgets('names the download size when the engine knows it', (
      tester,
    ) async {
      final harness = harnessFor(readyState());
      await harness.pump(
        tester,
        child: const TranslateErrorView(error: _offlineOnly),
        offline: fakeBergamot(),
      );
      await tester.pump();
      expect(find.text(_noPacks), findsOneWidget);
      expect(find.text('Download German (24.0 MB)'), findsOneWidget);
    });

    testWidgets('"Download languages" without a language pair', (tester) async {
      for (final consent in [
        _offlineOnlyLists,
        // A pair the engine does not support.
        const ConsentRequiredException(
          kind: ConsentKind.offlineOnly,
          destination: PublicInstanceDestination('mozhi.example.org'),
          engineId: 'mozhi:deepl',
          source: 'en',
          target: 'ko',
        ),
      ]) {
        final harness = harnessFor(readyState());
        await harness.pump(
          tester,
          child: TranslateErrorView(error: consent),
          offline: FakeOfflineTranslator(),
        );
        await tester.pump();
        expect(find.text(_noPacks), findsOneWidget);
        expect(find.text('Download languages'), findsOneWidget);
      }
    });

    testWidgets('the usual prompt once a language pack is there', (
      tester,
    ) async {
      final harness = harnessFor(readyState());
      await harness.pump(
        tester,
        child: const TranslateErrorView(error: _offlineOnly),
        offline: FakeOfflineTranslator(downloaded: {'fr'}),
      );
      await tester.pump();
      expect(find.text(_needsNetwork), findsOneWidget);
      expect(find.byKey(const Key('translate_error_consent')), findsOneWidget);
      expect(find.text(_noPacks), findsNothing);
    });

    testWidgets(
      'on the web: offline translation is unavailable, change the mode',
      (tester) async {
        final harness = harnessFor(readyState());
        await harness.pump(
          tester,
          child: const TranslateErrorView(error: _offlineOnly),
          offline: FakeOfflineTranslator(isAvailable: false),
        );
        // Known at once: nothing to check.
        expect(find.text(_web), findsOneWidget);
        expect(find.text(_needsNetwork), findsNothing);
        expect(find.text('Download languages'), findsNothing);
        await tester.tap(find.text('Change privacy mode'));
        verify(() => harness.router.push<void>('/settings')).called(1);
        expect(
          find.bySemanticsLabel(RegExp('isn’t available in the web app')),
          findsOneWidget,
        );
      },
      variant: _notAndroid,
    );

    testWidgets('an Android device that cannot run the engine', (tester) async {
      final harness = harnessFor(readyState());
      await harness.pump(
        tester,
        child: const TranslateErrorView(error: _offlineOnly),
        offline: FakeOfflineTranslator(isAvailable: false),
      );
      expect(find.text(_device), findsOneWidget);
      expect(
        find.byKey(const Key('translate_offline_only_privacy')),
        findsOneWidget,
      );
    });

    testWidgets('other consents keep the usual prompt', (tester) async {
      final harness = harnessFor(readyState());
      await harness.pump(
        tester,
        child: const TranslateErrorView(
          error: ConsentRequiredException(
            kind: ConsentKind.pair,
            destination: PublicInstanceDestination('mozhi.example.org'),
            engineId: 'mozhi:deepl',
            source: 'en',
            target: 'de',
          ),
        ),
        offline: FakeOfflineTranslator(isAvailable: false),
      );
      expect(find.byKey(const Key('translate_error_consent')), findsOneWidget);
      expect(
        find.byKey(const Key('translate_offline_only_notice')),
        findsNothing,
      );
    });
  });

  group('translate screen', () {
    testWidgets(
      'the web app with no engine list says why, not "needs the network"',
      (tester) async {
        final harness = harnessFor(
          const TranslateState(
            enginesStatus: EnginesStatus.failure,
            error: _offlineOnlyLists,
          ),
        );
        await harness.pump(
          tester,
          offline: FakeOfflineTranslator(isAvailable: false),
        );
        expect(
          find.byKey(const Key('translate_no_engines_consent')),
          findsOneWidget,
        );
        expect(find.text(_web), findsOneWidget);
        expect(find.text(_needsNetwork), findsNothing);
      },
      variant: _notAndroid,
    );

    testWidgets('the output says no language pack is downloaded', (
      tester,
    ) async {
      final harness = harnessFor(_held(_offlineOnly));
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: FakeOfflineTranslator(),
      );
      await tester.pump();
      expect(find.text(_noPacks), findsOneWidget);
      expect(find.text(_needsNetwork), findsNothing);
      // One way out, not also the pair offer's.
      expect(find.text('Download German'), findsOneWidget);
      expect(find.byKey(const Key('translate_offline_download')), findsNothing);
    });

    testWidgets('the output keeps the prompt and the on-device offer', (
      tester,
    ) async {
      final harness = harnessFor(_held(_offlineOnly));
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: FakeOfflineTranslator(downloaded: {'fr'}),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate_consent_prompt')), findsOneWidget);
      expect(find.text(_needsNetwork), findsOneWidget);
      expect(find.text('Download German'), findsOneWidget);
      expect(
        find.byKey(const Key('translate_offline_download')),
        findsOneWidget,
      );
    });
  });

  group('TranslateConsentListener', () {
    Future<StreamController<TranslateState>> pumpListener(
      WidgetTester tester,
      TranslateHarness harness,
      OfflineTranslator offline,
    ) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(
        harness.translate,
        states.stream,
        initialState: readyState(input: 'Hello world'),
      );
      await harness.pump(
        tester,
        child: const TranslateConsentListener(child: SizedBox()),
        offline: offline,
      );
      return states;
    }

    testWidgets('opens no dialog when nothing can translate offline', (
      tester,
    ) async {
      final harness = harnessFor(readyState(input: 'Hello world'));
      final states = await pumpListener(
        tester,
        harness,
        FakeOfflineTranslator(),
      );
      states.add(_held(_offlineOnly, automatic: false));
      await tester.pumpAndSettle();
      expect(find.text('Offline only is on'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('still explains "Offline only" with a language pack', (
      tester,
    ) async {
      final harness = harnessFor(readyState(input: 'Hello world'));
      final states = await pumpListener(
        tester,
        harness,
        FakeOfflineTranslator(downloaded: {'fr'}),
      );
      states.add(_held(_offlineOnly, automatic: false));
      await tester.pumpAndSettle();
      expect(find.text('Offline only is on'), findsOneWidget);
    });
  });
}
