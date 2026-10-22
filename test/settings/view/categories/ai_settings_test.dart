import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/categories/ai_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../../on_device_ai/data/helpers.dart';
import '../helpers.dart';

const _claude = AiProviderConfig(
  id: 'p1',
  name: 'Claude',
  provider: LlmProvider.anthropic,
  baseUrl: 'https://api.anthropic.com/v1',
  model: 'claude-opus-5-5',
);

void main() {
  setUpAll(registerFallbacks);

  late FakeOnDeviceModels models;
  late OnDeviceAi ai;
  late MockSettingsCubit settings;
  late MockGoRouter router;

  setUp(() {
    settings = createSettingsCubit();
    router = createRouter();
  });

  Future<void> pump(
    WidgetTester tester, {
    AppSettings state = const AppSettings(providers: [_claude]),
    bool onDevice = true,
  }) async {
    when(() => settings.state).thenReturn(state);
    // Made in the test's zone, so that their streams deliver while it
    // pumps.
    models = FakeOnDeviceModels(
      translationModel: 'hy-mt2',
      assistantModel: 'gemma',
    );
    ai = OnDeviceAi(models: models, engine: FakeLlamaEngine());
    addTearDown(ai.dispose);
    final content = SingleChildScrollView(child: AiSettings(settings: state));
    await tester.pumpView(
      Scaffold(
        body: onDevice
            ? RepositoryProvider<OnDeviceAi>.value(value: ai, child: content)
            : content,
      ),
      settings: settings,
      router: router,
    );
    await tester.pump();
  }

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.text('AI assistant for insights'));
    await tester.pumpAndSettle();
  }

  group('AI assistant picker', () {
    testWidgets('offers the on-device assistant, not the translation model', (
      tester,
    ) async {
      await pump(tester);
      await openPicker(tester);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('Model gemma (on this device)'), findsOneWidget);
      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('Model hy-mt2 (on this device)'), findsNothing);
      expect(
        find.text(
          'The on-device model when your text should stay on this device, '
          'else the first enabled AI provider',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Model gemma (on this device)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      verify(() => settings.setAssistEngine('ai:device-gemma')).called(1);
    });

    testWidgets('names the chosen on-device assistant', (tester) async {
      await pump(
        tester,
        state: const AppSettings(assistEngineId: 'ai:device-gemma'),
      );
      expect(find.text('Model gemma (on this device)'), findsOneWidget);
    });

    testWidgets('opens with only an on-device assistant', (tester) async {
      await pump(tester, state: const AppSettings());
      expect(find.text('Automatic'), findsOneWidget);
      await openPicker(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      verifyNever(
        () => router.push<Object?>(any(), extra: any(named: 'extra')),
      );
    });

    testWidgets('follows the installed models', (tester) async {
      await pump(tester, state: const AppSettings());
      models
        ..assistantModel = null
        ..changed();
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Add an AI provider for alternatives, insights and explanations',
        ),
        findsOneWidget,
      );
    });

    testWidgets('without on-device AI, works as before', (tester) async {
      await pump(tester, onDevice: false);
      await openPicker(tester);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('First enabled AI provider'), findsOneWidget);
      expect(find.text('On this device'), findsNothing);
    });
  });
}
