import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/on_device_ai_offer_cubit.dart';
import 'package:mozhi/translate/widgets/widgets.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers/fake_on_device_models.dart';
import '../helpers/helpers.dart';

const _title = 'Translate and explain with AI that stays on your phone';

void main() {
  setUpAll(registerTranslateFallbacks);

  late FakeOnDeviceModels models;
  late MemoryStore store;

  setUp(() {
    models = FakeOnDeviceModels(testCatalog);
    store = MemoryStore();
    addTearDown(models.controller.close);
  });

  Future<TranslateHarness> pump(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(),
    Widget? child,
    bool disableAnimations = false,
  }) async {
    final harness = TranslateHarness(settings: settings);
    await harness.pump(
      tester,
      child: child ?? OnDeviceAiOffer(models: models, store: store),
      disableAnimations: disableAnimations,
    );
    await tester.pumpAndSettle();
    return harness;
  }

  testWidgets('offers on-device AI with the smallest download', (tester) async {
    await pump(tester);
    expect(find.text(_title), findsOneWidget);
    expect(
      find.text(
        'Choose a model on the next screen (from 1.1 GB). Nothing '
        'downloads until you do, and your text never leaves the phone.',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.memory), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  });

  testWidgets('leaves the size out when the catalogue lacks it', (
    tester,
  ) async {
    models = FakeOnDeviceModels([catalogModel('hy-mt2')]);
    await pump(tester);
    expect(
      find.text(
        'Choose a model on the next screen. Nothing downloads until you do, '
        'and your text never leaves the phone.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('See models opens the settings, once', (tester) async {
    final harness = await pump(tester);
    await tester.tap(find.text('See models'));
    await tester.pumpAndSettle();
    verify(() => harness.router.push<void>(AppRoutes.onDeviceAi)).called(1);
    expect(find.text(_title), findsNothing);
    expect(store.values[OnDeviceAiOfferCubit.storeKey], 'never');
  });

  testWidgets('Not now hides it for a while', (tester) async {
    await pump(tester, disableAnimations: true);
    await tester.tap(find.text('Not now'));
    await tester.pump();
    expect(find.text(_title), findsNothing);
    expect(
      int.tryParse(store.values[OnDeviceAiOfferCubit.storeKey]!),
      isNotNull,
    );
  });

  testWidgets("Don't show again hides it for good", (tester) async {
    final harness = await pump(tester);
    await tester.tap(find.text('Don’t show again'));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
    expect(store.values[OnDeviceAiOfferCubit.storeKey], 'never');
    verifyNever(() => harness.router.push<void>(any()));
  });

  testWidgets('is not shown while an AI provider exists', (tester) async {
    await pump(
      tester,
      settings: const AppSettings(
        providers: [
          AiProviderConfig(
            id: 'p1',
            name: 'Claude',
            provider: LlmProvider.anthropic,
            baseUrl: 'https://api.anthropic.com',
            model: 'claude-opus-5-5',
          ),
        ],
      ),
    );
    expect(find.text(_title), findsNothing);
  });

  testWidgets('is shown with only a translation service', (tester) async {
    await pump(
      tester,
      settings: const AppSettings(
        providers: [
          AiProviderConfig(
            id: 'p1',
            name: 'DeepL',
            provider: LlmProvider.openAiCompatible,
            baseUrl: 'https://api-free.deepl.com',
            model: '',
            service: MtService.deepl,
          ),
        ],
      ),
    );
    expect(find.text(_title), findsOneWidget);
  });

  testWidgets('finds the app’s models and preferences', (tester) async {
    await pump(
      tester,
      child: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<OnDeviceModels>.value(value: models),
          RepositoryProvider<KeyValueStore>.value(value: store),
        ],
        child: const OnDeviceAiOffer(),
      ),
    );
    expect(find.text(_title), findsOneWidget);
    await tester.tap(find.text('Don’t show again'));
    await tester.pumpAndSettle();
    expect(store.values[OnDeviceAiOfferCubit.storeKey], 'never');
  });

  testWidgets('shows nothing without preferences to remember it', (
    tester,
  ) async {
    await pump(tester, child: OnDeviceAiOffer(models: models));
    expect(find.byType(OnDeviceAiOfferView), findsNothing);
  });

  testWidgets('shows nothing where on-device AI does not run', (tester) async {
    await pump(tester, child: const OnDeviceAiOffer());
    expect(find.byType(OnDeviceAiOfferView), findsNothing);
    expect(find.text(_title), findsNothing);
  });
}
