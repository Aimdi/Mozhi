import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/onboarding/onboarding.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  setUpAll(registerOnboardingFallbacks);

  Future<MockOnboardingCubit> pump(
    WidgetTester tester, [
    OnboardingState state = const OnboardingState(),
    Size size = const Size(500, 4000),
  ]) async {
    tester.setScreenSize(size);
    final cubit = createOnboardingCubit(state);
    await tester.pumpOnboarding(const AiStep(), onboarding: cubit);
    return cubit;
  }

  OnboardingState presetState(String id, {String apiKey = ''}) {
    final preset = AiProviderPreset.byId(id)!;
    return OnboardingState(
      presetId: id,
      apiKey: apiKey,
      baseUrl: preset.baseUrl,
      model: preset.defaultModel,
    );
  }

  TextField field(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(Key(key)));

  group('AiStep', () {
    testWidgets('explains the benefits and lists every preset', (tester) async {
      await pump(tester);

      expect(find.text('Add an AI translator'), findsOneWidget);
      expect(find.text('Optional'), findsOneWidget);
      expect(find.text('Alternative translations'), findsOneWidget);
      expect(find.text('Word-by-word insights'), findsOneWidget);
      expect(find.text('Explanations of grammar and nuance'), findsOneWidget);
      expect(find.text('Proofreading'), findsOneWidget);
      expect(find.text('Custom styles, tone and formality'), findsOneWidget);
      for (final preset in AiProviderPreset.all) {
        expect(find.text(preset.name), findsOneWidget, reason: preset.id);
      }
      expect(
        find.text('Local'),
        findsNWidgets(AiProviderPreset.all.where((p) => p.isLocal).length),
      );
      expect(find.byType(ProviderForm), findsNothing);
    });

    testWidgets('uses several columns on wide screens', (tester) async {
      await pump(tester, const OnboardingState(), const Size(1200, 2000));
      final openAi = tester.getRect(
        find.byKey(const ValueKey('preset-openai')),
      );
      final anthropic = tester.getRect(
        find.byKey(const ValueKey('preset-anthropic')),
      );
      expect(anthropic.top, openAi.top);
      expect(anthropic.height, openAi.height);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a preset selects it', (tester) async {
      final cubit = await pump(tester);
      await tester.tap(find.text('Anthropic'));
      verify(() => cubit.selectPreset('anthropic')).called(1);
    });

    testWidgets('marks the selected preset', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, presetState('openai'));
      expect(
        tester.getSemantics(find.byKey(const ValueKey('preset-openai'))),
        isSemantics(isSelected: true, isInMutuallyExclusiveGroup: true),
      );
      handle.dispose();
    });

    group('cloud preset', () {
      testWidgets('shows an obscured API key field and a key link', (
        tester,
      ) async {
        Uri? opened;
        final original = LinkLauncher.launcher;
        addTearDown(() => LinkLauncher.launcher = original);
        LinkLauncher.launcher = (uri) async {
          opened = uri;
          return true;
        };
        final cubit = await pump(tester, presetState('openai'));

        expect(find.byType(ProviderForm), findsOneWidget);
        expect(field(tester, 'onboarding-api-key').obscureText, isTrue);
        expect(find.byKey(const Key('onboarding-base-url')), findsNothing);
        expect(
          field(tester, 'onboarding-model').controller!.text,
          'gpt-5-mini',
        );

        await tester.tap(find.byTooltip('Show API key'));
        await tester.pump();
        expect(field(tester, 'onboarding-api-key').obscureText, isFalse);
        expect(find.byTooltip('Hide API key'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('onboarding-api-key')),
          'sk',
        );
        verify(() => cubit.updateProviderDraft(apiKey: 'sk')).called(1);
        await tester.enterText(
          find.byKey(const Key('onboarding-model')),
          'gpt-5',
        );
        verify(() => cubit.updateProviderDraft(model: 'gpt-5')).called(1);

        await tester.tap(find.text('Get a key'));
        await tester.pump();
        expect(opened, Uri.parse('https://platform.openai.com/api-keys'));
      });

      testWidgets('suggested models fill the model field', (tester) async {
        final cubit = await pump(tester, presetState('openai'));
        await tester.tap(find.widgetWithText(ChoiceChip, 'gpt-5-nano'));
        await tester.pump();
        verify(() => cubit.updateProviderDraft(model: 'gpt-5-nano')).called(1);
        expect(
          field(tester, 'onboarding-model').controller!.text,
          'gpt-5-nano',
        );
      });

      testWidgets('shows validation errors', (tester) async {
        await pump(
          tester,
          presetState('openai').copyWith(showProviderErrors: true, model: ''),
        );
        expect(find.text('Required'), findsNWidgets(2));
      });

      testWidgets('Test and Save call the cubit', (tester) async {
        final cubit = await pump(tester, presetState('openai', apiKey: 'sk'));
        await tester.tap(find.text('Test'));
        verify(cubit.testProvider).called(1);
        await tester.tap(find.text('Save'));
        verify(cubit.saveProvider).called(1);
      });

      testWidgets('shows a running test', (tester) async {
        await pump(
          tester,
          presetState('openai')
              .copyWith(testStatus: ProviderTestStatus.running),
        );
        expect(find.text('Testing…'), findsOneWidget);
      });

      testWidgets('shows the test output', (tester) async {
        await pump(
          tester,
          presetState('openai').copyWith(
            testStatus: ProviderTestStatus.success,
            testOutput: () => 'Bonjour, le monde !',
          ),
        );
        expect(find.textContaining('Bonjour, le monde !'), findsOneWidget);
      });

      testWidgets('shows test errors and timeouts', (tester) async {
        await pump(
          tester,
          presetState('openai').copyWith(
            testStatus: ProviderTestStatus.failure,
            testError: () => '401: bad key',
          ),
        );
        expect(find.text('Test failed: 401: bad key'), findsOneWidget);

        await pump(
          tester,
          presetState('anthropic')
              .copyWith(testStatus: ProviderTestStatus.failure),
        );
        expect(
          find.text('Test failed: the provider took too long to answer.'),
          findsOneWidget,
        );
      });

      testWidgets('confirms a saved provider', (tester) async {
        const id = 'p1';
        final state = presetState('openai', apiKey: 'sk');
        final saved = state.draftConfig(id)!;
        await pump(tester, state.copyWith(saved: {'openai': saved}));

        expect(
          find.text('OpenAI saved. You can pick it in the translator.'),
          findsOneWidget,
        );
        final button = tester.widget<ButtonStyleButton>(
          find.ancestor(
            of: find.text('Save'),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        );
        expect(button.onPressed, isNull);
      });
    });

    group('local preset', () {
      testWidgets('asks for the server address with a LAN hint', (
        tester,
      ) async {
        final cubit = await pump(tester, presetState('ollama'));

        expect(find.byKey(const Key('onboarding-api-key')), findsNothing);
        expect(
          field(tester, 'onboarding-base-url').controller!.text,
          'http://localhost:11434',
        );
        expect(
          find.text(
            "On a phone, use your computer's LAN IP, e.g. "
            'http://192.168.1.20:11434',
          ),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const Key('onboarding-base-url')),
          'http://192.168.1.5:11434',
        );
        verify(
          () => cubit.updateProviderDraft(baseUrl: 'http://192.168.1.5:11434'),
        ).called(1);
      });

      testWidgets('loads models from the server', (tester) async {
        final cubit = await pump(tester, presetState('lmstudio'));
        await tester.tap(find.byTooltip('Load models'));
        verify(cubit.loadModels).called(1);
      });

      testWidgets('shows loaded models and loading state', (tester) async {
        await pump(
          tester,
          presetState('lmstudio').copyWith(
            modelsStatus: ProviderTestStatus.running,
            models: ['qwen3-8b'],
          ),
        );
        expect(find.widgetWithText(ChoiceChip, 'qwen3-8b'), findsOneWidget);
        expect(find.byTooltip('Load models'), findsNothing);
      });

      testWidgets('shows model list errors', (tester) async {
        await pump(
          tester,
          presetState('llamacpp').copyWith(
            modelsStatus: ProviderTestStatus.failure,
            modelsError: () => 'offline',
          ),
        );
        expect(find.text('Could not load models: offline'), findsOneWidget);

        await pump(
          tester,
          presetState('lmstudio')
              .copyWith(modelsStatus: ProviderTestStatus.failure),
        );
        expect(find.text('Could not load models: Timed out'), findsOneWidget);
      });
    });

    testWidgets('custom preset shows an optional key and an address', (
      tester,
    ) async {
      await pump(tester, presetState('custom'));
      expect(find.text('API key (optional)'), findsOneWidget);
      expect(find.text('Get a key'), findsNothing);
      expect(find.byKey(const Key('onboarding-base-url')), findsOneWidget);
    });

    test('lanExample swaps the host for a LAN IP', () {
      expect(
        lanExample(AiProviderPreset.byId('lmstudio')!),
        'http://192.168.1.20:1234/v1',
      );
      expect(
        lanExample(AiProviderPreset.byId('custom')!),
        'http://192.168.1.20:11434',
      );
    });
  });
}
