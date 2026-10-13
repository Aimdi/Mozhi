import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/onboarding/onboarding.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../helpers.dart';

void main() {
  const provider = AiProviderConfig(
    id: 'p1',
    name: 'Ollama',
    provider: LlmProvider.ollama,
    baseUrl: 'http://192.168.1.20:11434',
    model: 'gemma3',
  );

  Future<void> pump(
    WidgetTester tester, {
    AppSettings settings = testSettings,
    OnboardingState state = const OnboardingState(),
  }) async {
    tester.setScreenSize(const Size(500, 1400));
    await tester.pumpOnboarding(
      const DoneStep(),
      onboarding: createOnboardingCubit(state),
      settings: createSettings(settings),
    );
  }

  String subtitleOf(WidgetTester tester, String key) {
    final tile = tester.widget<ListTile>(find.byKey(Key(key)));
    return (tile.subtitle! as Text).data!;
  }

  group('DoneStep', () {
    testWidgets('summarises the preferred instance and AI', (tester) async {
      await pump(tester);

      expect(find.text('You are all set!'), findsOneWidget);
      expect(
        subtitleOf(tester, 'onboarding-summary-service'),
        'Alpha\n2 fallback instances',
      );
      expect(
        subtitleOf(tester, 'onboarding-summary-ai'),
        'Not set up. You can add one in Settings.',
      );
    });

    testWidgets('includes the measured latency', (tester) async {
      await pump(
        tester,
        state: OnboardingState(
          pings: {
            instanceA.url: const InstancePing.success(
              Duration(milliseconds: 85),
            ),
          },
        ),
        settings: const AppSettings(instances: [instanceA]),
      );
      expect(
        subtitleOf(tester, 'onboarding-summary-service'),
        'Alpha · 85 ms\nNo fallback instances',
      );
    });

    testWidgets('lists enabled AI providers', (tester) async {
      await pump(
        tester,
        settings: AppSettings(
          instances: const [],
          providers: [
            provider,
            provider.copyWith(enabled: false, name: 'Hidden'),
          ],
        ),
      );
      expect(
        subtitleOf(tester, 'onboarding-summary-service'),
        'No Mozhi instance configured',
      );
      expect(subtitleOf(tester, 'onboarding-summary-ai'), 'Ollama · gemma3');
    });
  });
}
