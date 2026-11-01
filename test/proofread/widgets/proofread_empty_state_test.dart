import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/on_device_ai_setup_button.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';

import '../../helpers/helpers.dart';
import '../../translate/helpers/fake_on_device_models.dart';
import '../helpers/proofread_helpers.dart';

void main() {
  late MockGoRouter router;

  setUp(() {
    router = MockGoRouter();
    when(() => router.push<void>(any())).thenAnswer((_) async {});
  });

  Future<void> pump(WidgetTester tester, {OnDeviceModels? models}) {
    Widget tree = const Scaffold(body: ProofreadEmptyState());
    if (models != null) {
      tree = RepositoryProvider<OnDeviceModels>.value(
        value: models,
        child: tree,
      );
    }
    return tester.pumpApp(InheritedGoRouter(goRouter: router, child: tree));
  }

  const onDeviceKey = Key('proofread_set_up_on_device_ai');
  const providerKey = Key('proofread_add_provider');

  group('ProofreadEmptyState', () {
    testWidgets('offers only an AI provider where on-device AI does not run', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('Proofreading needs an AI provider'), findsOneWidget);
      expect(find.byKey(onDeviceKey), findsNothing);
      expect(find.byType(OnDeviceAiSetupButton), findsNothing);
      expect(tester.widget(find.byKey(providerKey)), isA<FilledButton>());
      await tester.tap(find.text('Add AI provider'));
      verify(() => router.push<void>('/settings/providers')).called(1);
    });

    testWidgets('offers on-device AI first where it runs and fits', (
      tester,
    ) async {
      await pump(tester, models: FakeOnDeviceModels(testCatalog));

      expect(
        find.text(
          'Download an AI model that runs on this phone, or add an '
          'OpenAI-compatible, Anthropic, Gemini or Ollama provider, to check '
          'grammar, spelling and style. Dedicated translation models, such '
          "as Hy-MT or TranslateGemma, can't proofread.",
        ),
        findsOneWidget,
      );
      expect(find.byKey(onDeviceKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(onDeviceKey),
          matching: find.byType(FilledButton),
        ),
        findsOneWidget,
      );
      expect(tester.widget(find.byKey(providerKey)), isA<OutlinedButton>());
      final onDevice = tester.getTopLeft(find.byKey(onDeviceKey));
      final provider = tester.getTopLeft(find.byKey(providerKey));
      expect(onDevice.dx < provider.dx || onDevice.dy < provider.dy, isTrue);

      await tester.tap(find.text('Set up on-device AI'));
      verify(() => router.push<void>(AppRoutes.onDeviceAi)).called(1);
      await tester.tap(find.text('Add AI provider'));
      verify(() => router.push<void>('/settings/providers')).called(1);
    });

    testWidgets('leaves on-device AI out when no model fits the phone', (
      tester,
    ) async {
      await pump(
        tester,
        models: FakeOnDeviceModels(
          testCatalog,
          fits: {for (final model in testCatalog) model.id: OnDeviceFit.tooBig},
        ),
      );
      expect(find.byKey(onDeviceKey), findsNothing);
      expect(tester.widget(find.byKey(providerKey)), isA<FilledButton>());
    });

    testWidgets('the on-device button can be outlined', (tester) async {
      await tester.pumpApp(
        InheritedGoRouter(
          goRouter: router,
          child: const Scaffold(body: OnDeviceAiSetupButton()),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(OnDeviceAiSetupButton),
          matching: find.byType(OutlinedButton),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.memory), findsOneWidget);
    });
  });
}
