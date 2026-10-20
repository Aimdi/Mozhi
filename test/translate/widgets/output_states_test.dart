import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/translate.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_offline.dart';
import '../helpers/helpers.dart';

const _consent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: PublicInstanceDestination('mozhi.example.org', engine: 'google'),
  engineId: 'mozhi:google',
  source: 'en',
  target: 'fr',
);

const _offlineEngine = TranslationEngine(
  id: 'offline:bergamot',
  kind: EngineKind.offline,
  name: 'On this device',
  isLocal: true,
);

TranslateState _waiting({List<TranslationEngine>? engines}) =>
    readyState(input: 'Hello world').copyWith(
      engines: engines,
      consent: () => const ConsentRequest(exception: _consent, id: 1),
    );

TranslateState _failed() => readyState(input: 'Hello').copyWith(
  status: TranslateStatus.failure,
  error: () => const MozhiApiException('Connection refused'),
);

const _instances = [
  MozhiInstance(url: 'https://one.example', label: 'One'),
  MozhiInstance(url: 'https://two.example', label: 'Two'),
];

void main() {
  setUpAll(registerTranslateFallbacks);

  group('haptics', () {
    testWidgets('copy ticks lightly', (tester) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.byTooltip('Copy'));
      await tester.pump();
      expect(clipboard.haptics, ['HapticFeedbackType.lightImpact']);
      expect(clipboard.copied, 'Bonjour le monde');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('favourite ticks lightly', (tester) async {
      final clipboard = FakeClipboard(tester);
      final harness = TranslateHarness(state: translatedState());
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.byTooltip('Add to favourites'));
      await tester.pump();
      expect(clipboard.haptics, ['HapticFeedbackType.lightImpact']);
    });
  });

  group('fade through', () {
    Future<StreamController<TranslateState>> listen(
      TranslateHarness harness,
      TranslateState initial,
    ) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      whenListen(harness.translate, states.stream, initialState: initial);
      return states;
    }

    final next = translatedState(
      input: 'Good night',
      result: const TranslationResult(
        engineId: 'mozhi:deepl',
        engineName: 'DeepL',
        text: 'Bonne nuit',
      ),
    );

    testWidgets('a new result replaces the old one with a fade', (
      tester,
    ) async {
      final harness = TranslateHarness(state: translatedState());
      final states = await listen(harness, translatedState());
      await harness.pump(tester, child: const OutputCard());
      states.add(next);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Both for a moment; the old one is hidden from screen readers.
      expect(find.text('Bonjour le monde'), findsOneWidget);
      expect(find.text('Bonne nuit'), findsOneWidget);
      final fades = tester.widgetList<FadeTransition>(
        find.ancestor(
          of: find.text('Bonne nuit'),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fades.any((fade) => fade.opacity.value < 1), isTrue);
      expect(
        find.ancestor(
          of: find.text('Bonjour le monde'),
          matching: find.byWidgetPredicate(
            (widget) => widget is ExcludeSemantics && widget.excluding,
          ),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Bonjour le monde'), findsNothing);
      expect(find.text('Bonne nuit'), findsOneWidget);
    });

    testWidgets('a streaming result keeps its place', (tester) async {
      final partial = readyState(
        engine: claude,
        input: 'Hello world',
        status: TranslateStatus.translating,
        result: const TranslationResult(
          engineId: 'ai:claude',
          engineName: 'Claude',
          text: 'Bon',
          isComplete: false,
        ),
      ).copyWith(resultInput: () => 'Hello world');
      final harness = TranslateHarness(state: partial);
      final states = await listen(harness, partial);
      await harness.pump(tester, child: const OutputCard());
      states.add(
        partial.copyWith(
          result: () => const TranslationResult(
            engineId: 'ai:claude',
            engineName: 'Claude',
            text: 'Bonjour',
            isComplete: false,
          ),
        ),
      );
      await tester.pump();
      // No transition: the text just grows.
      expect(find.text('Bon'), findsNothing);
      expect(find.text('Bonjour'), findsOneWidget);
    });

    testWidgets('switches at once with reduced motion', (tester) async {
      final harness = TranslateHarness(state: translatedState());
      final states = await listen(harness, translatedState());
      await harness.pump(
        tester,
        child: const OutputCard(),
        disableAnimations: true,
      );
      states.add(next);
      await tester.pump();
      await tester.pump();
      expect(find.text('Bonjour le monde'), findsNothing);
      expect(find.text('Bonne nuit'), findsOneWidget);
    });
  });

  group('the on-device alternative to sending', () {
    testWidgets('offers to download the language that is missing', (
      tester,
    ) async {
      final harness = TranslateHarness(state: _waiting());
      when(() => harness.repository.instances).thenReturn(const []);
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: FakeOfflineTranslator(),
      );
      await tester.pump();
      expect(find.byKey(const Key('translate_consent_prompt')), findsOneWidget);
      // The fake engine knows no sizes.
      expect(find.text('Download French'), findsOneWidget);
      await tester.tap(find.byKey(const Key('translate_offline_download')));
      verify(() => harness.router.push<void>('/settings/offline')).called(1);
    });

    testWidgets('switches to the device once the pair is there', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: _waiting(engines: const [deepl, google, _offlineEngine]),
      );
      when(() => harness.repository.instances).thenReturn(const []);
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: FakeOfflineTranslator(downloaded: {'fr'}),
      );
      await tester.pump();
      await tester.tap(find.text('Translate on this device'));
      verify(() => harness.translate.selectEngine(_offlineEngine)).called(1);
    });

    testWidgets('follows the language pair that is held back', (tester) async {
      final states = StreamController<TranslateState>();
      addTearDown(states.close);
      final harness = TranslateHarness(state: _waiting());
      when(() => harness.repository.instances).thenReturn(const []);
      whenListen(harness.translate, states.stream, initialState: _waiting());
      await harness.pump(
        tester,
        child: const OutputCard(),
        offline: FakeOfflineTranslator(),
      );
      await tester.pump();
      expect(find.text('Download French'), findsOneWidget);
      states.add(
        readyState(input: 'Hello world').copyWith(
          consent: () => const ConsentRequest(
            exception: ConsentRequiredException(
              kind: ConsentKind.pair,
              destination: PublicInstanceDestination('mozhi.example.org'),
              engineId: 'mozhi:google',
              source: 'de',
              target: 'ja',
            ),
            id: 2,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Download German, Japanese'), findsOneWidget);
    });

    testWidgets('is not offered when the device cannot help', (tester) async {
      for (final offline in <FakeOfflineTranslator?>[
        null,
        FakeOfflineTranslator(isAvailable: false),
        FakeOfflineTranslator(supportedLanguages: const {'en', 'de'}),
        // Downloaded, but there is no on-device engine to switch to.
        FakeOfflineTranslator(downloaded: {'fr'}),
      ]) {
        final harness = TranslateHarness(state: _waiting());
        when(() => harness.repository.instances).thenReturn(const []);
        await harness.pump(tester, child: const OutputCard(), offline: offline);
        await tester.pump();
        expect(
          find.byKey(const Key('translate_offline_download')),
          findsNothing,
        );
        expect(find.byKey(const Key('translate_offline_use')), findsNothing);
      }
    });
  });

  group('switch instance', () {
    testWidgets('the instance in use is the first without a repository', (
      tester,
    ) async {
      String? current;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            current = currentInstanceUrl(context, _instances);
            return const SizedBox();
          },
        ),
      );
      expect(current, 'https://one.example');
    });

    testWidgets('picks another instance and translates again', (tester) async {
      final harness = TranslateHarness(
        state: _failed(),
        settings: const AppSettings(instances: _instances),
      );
      await harness.pump(tester, child: const OutputCard());
      expect(find.text('Manage instances'), findsNothing);
      await tester.tap(find.text('Switch instance'));
      await tester.pumpAndSettle();
      expect(find.text('Translate with another instance'), findsOneWidget);
      expect(find.text('In use'), findsOneWidget);
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      verify(() => harness.settings.preferInstance('https://two.example'))
          .called(1);
      verify(harness.translate.translate).called(1);
    });

    testWidgets('marks the instance a failover switched to', (tester) async {
      final harness = TranslateHarness(
        state: _failed(),
        settings: const AppSettings(instances: _instances),
      );
      when(() => harness.repository.activeInstance).thenReturn(_instances[1]);
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.text('Switch instance'));
      await tester.pumpAndSettle();
      // Picking the one in use changes nothing.
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      verifyNever(() => harness.settings.preferInstance(any()));
      verifyNever(harness.translate.translate);
    });

    testWidgets('links to the instance settings', (tester) async {
      final harness = TranslateHarness(
        state: _failed(),
        settings: const AppSettings(instances: _instances),
      );
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.text('Switch instance'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('translate_instance_manage')));
      await tester.pumpAndSettle();
      verify(() => harness.router.push<void>('/settings/instances')).called(1);
    });

    testWidgets('dismissing changes nothing', (tester) async {
      final harness = TranslateHarness(
        state: _failed(),
        settings: const AppSettings(instances: _instances),
      );
      await harness.pump(tester, child: const OutputCard());
      await tester.tap(find.text('Switch instance'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      verifyNever(() => harness.settings.preferInstance(any()));
    });
  });
}
