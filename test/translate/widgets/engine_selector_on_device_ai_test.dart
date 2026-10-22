import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/offline/offline.dart' show OfflineEngineBadge;
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_on_device_models.dart';
import '../helpers/helpers.dart';

const hyMt = TranslationEngine(
  id: 'ai:device-hy-mt2-1.8b-q4',
  kind: EngineKind.ai,
  name: 'Hy-MT2 1.8B (on this device)',
  subtitle: 'hy-mt2-1.8b-q4',
  providerId: 'device-hy-mt2-1.8b-q4',
  isLocal: true,
  onDevice: true,
  promptProfile: PromptProfile.hunyuanMt,
);

const _offline = TranslationEngine(
  id: TranslationEngine.offlineId,
  kind: EngineKind.offline,
  name: 'Offline (on-device)',
  isLocal: true,
);

void main() {
  setUpAll(registerTranslateFallbacks);

  group('on-device AI engines', () {
    test('count as on this device', () {
      expect(isOnDeviceEngine(hyMt), isTrue);
      expect(isOnDeviceEngine(_offline), isTrue);
      expect(isOnDeviceEngine(ollama), isFalse);
      expect(isOnDeviceEngine(claude), isFalse);
      // A stored provider with such an id is not.
      const lookalike = TranslationEngine(
        id: 'ai:device-hy-mt2-1.8b-q4',
        kind: EngineKind.ai,
        name: 'Lookalike',
      );
      expect(isOnDeviceEngine(lookalike), isFalse);
    });

    testWidgets('show a memory chip', (tester) async {
      await TranslateHarness(state: readyState(engine: hyMt))
          .pump(tester, child: const EngineSelectorButton());
      expect(find.byIcon(Icons.memory), findsOneWidget);
      expect(find.text('Hy-MT2 1.8B (on this device)'), findsOneWidget);
    });

    testWidgets('are "On this device" when the repository says so', (
      tester,
    ) async {
      final harness = TranslateHarness();
      when(() => harness.repository.destinationOf(hyMt.id))
          .thenReturn(const OnDeviceDestination());
      await harness.pump(
        tester,
        child: const Row(children: [PrivacyBadge(engine: hyMt)]),
      );
      expect(find.text('On this device'), findsOneWidget);
      expect(find.byIcon(Icons.memory), findsOneWidget);
    });

    testWidgets('trust the repository about where text goes', (tester) async {
      final harness = TranslateHarness();
      // A routing mistake would show, not be painted over.
      when(() => harness.repository.destinationOf(hyMt.id))
          .thenReturn(const CloudProviderDestination('Somewhere'));
      await harness.pump(
        tester,
        child: const Row(children: [PrivacyBadge(engine: hyMt)]),
      );
      expect(find.text('Cloud'), findsOneWidget);
    });

    testWidgets('are listed under "On this device" with offline translation', (
      tester,
    ) async {
      final harness = TranslateHarness(
        state: readyState().copyWith(
          engines: const [_offline, deepl, claude, hyMt],
        ),
      );
      await harness.pump(
        tester,
        child: const EngineSelectorButton(),
        size: const Size(800, 1400),
      );
      await tester.tap(find.byKey(const Key('translate_engine_selector')));
      await tester.pumpAndSettle();

      double top(Finder finder) => tester.getTopLeft(finder).dy;
      final name = find.text('Hy-MT2 1.8B (on this device)');
      expect(top(find.text('On this device')), lessThan(top(name)));
      expect(top(name), lessThan(top(find.text('AI models'))));
      // One badge for the whole section.
      expect(find.byType(OfflineEngineBadge), findsOneWidget);
      final tile = find.ancestor(of: name, matching: find.byType(ListTile));
      expect(
        find.descendant(of: tile, matching: find.byIcon(Icons.memory)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: tile,
          matching: find.text(
            'Private: your text stays on this device · hy-mt2-1.8b-q4',
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(name);
      await tester.pumpAndSettle();
      verify(() => harness.translate.selectEngine(hyMt)).called(1);
    });
  });
  group('Add on-device AI…', () {
    late FakeOnDeviceModels models;

    setUp(() {
      models = FakeOnDeviceModels(testCatalog);
      addTearDown(models.controller.close);
    });

    Future<TranslateHarness> open(
      WidgetTester tester, {
      bool provided = true,
    }) async {
      final harness = TranslateHarness();
      const button = EngineSelectorButton();
      await harness.pump(
        tester,
        child: provided
            ? RepositoryProvider<OnDeviceModels>.value(
                value: models,
                child: button,
              )
            : button,
        size: const Size(800, 1400),
      );
      await tester.tap(find.byKey(const Key('translate_engine_selector')));
      await tester.pumpAndSettle();
      return harness;
    }

    final row = find.byKey(const Key('translate_add_on_device_ai'));

    testWidgets('opens the On-device AI settings', (tester) async {
      final harness = await open(tester);
      expect(find.text('Add on-device AI…'), findsOneWidget);
      expect(
        find.text('AI that runs on this phone, without the network'),
        findsOneWidget,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      verify(() => harness.router.push<void>(AppRoutes.onDeviceAi)).called(1);
      // The sheet closed.
      expect(row, findsNothing);
    });

    testWidgets('is not offered once a model is installed', (tester) async {
      models.translationModel = 'hy-mt2-1.8b-q4';
      await open(tester);
      expect(row, findsNothing);
    });

    testWidgets('is not offered where nothing fits', (tester) async {
      models.fits = {
        'hy-mt2-1.8b-q4': OnDeviceFit.tooBig,
        'qwen3-1.7b-q4': OnDeviceFit.unknown,
      };
      await open(tester);
      expect(row, findsNothing);
    });

    testWidgets('is not offered where on-device AI does not run (web)', (
      tester,
    ) async {
      await open(tester, provided: false);
      expect(row, findsNothing);
    });
  });
}
