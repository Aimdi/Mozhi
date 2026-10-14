import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';

void main() {
  group('InstancePing', () {
    test('named constructors', () {
      expect(const InstancePing.pending().status, PingStatus.pending);
      const success = InstancePing.success(Duration(milliseconds: 5));
      expect(success.isSuccess, isTrue);
      expect(success.latency, const Duration(milliseconds: 5));
      expect(const InstancePing.failure('x').error, 'x');
      expect(const InstancePing.timedOut().isSuccess, isFalse);
      expect(const InstancePing.failure('x'), const InstancePing.failure('x'));
    });
  });

  group('OnboardingState', () {
    test('toString masks the API key', () {
      const state = OnboardingState(apiKey: 'sk-ant-secret', model: 'm1');
      expect(state.toString(), isNot(contains('sk-ant-secret')));
      expect(state.toString(), contains('<redacted>'));
      expect(state.toString(), contains('m1'));
      expect(const OnboardingState().toString(), isNot(contains('redacted')));
    });

    test('fastestUrl picks the lowest latency among answers', () {
      const state = OnboardingState(
        pings: {
          'a': InstancePing.success(Duration(milliseconds: 30)),
          'b': InstancePing.failure('x'),
          'c': InstancePing.success(Duration(milliseconds: 10)),
          'd': InstancePing.pending(),
          'e': InstancePing(status: PingStatus.success),
        },
      );
      expect(state.fastestUrl, 'c');
      expect(const OnboardingState().fastestUrl, isNull);
    });

    test('noneReachable needs finished, failed pings', () {
      const failed = {'a': InstancePing.timedOut()};
      expect(
        const OnboardingState(
          serviceStatus: ServiceStatus.done,
          pings: failed,
        ).noneReachable,
        isTrue,
      );
      expect(const OnboardingState(pings: failed).noneReachable, isFalse);
      expect(
        const OnboardingState(serviceStatus: ServiceStatus.done).noneReachable,
        isFalse,
      );
    });

    test('form visibility depends on the preset', () {
      expect(const OnboardingState().preset, isNull);
      expect(const OnboardingState().needsBaseUrl, isFalse);
      expect(const OnboardingState().showsApiKey, isFalse);

      const cloud = OnboardingState(presetId: 'anthropic');
      expect(cloud.needsBaseUrl, isFalse);
      expect(cloud.showsApiKey, isTrue);

      const local = OnboardingState(presetId: 'ollama');
      expect(local.needsBaseUrl, isTrue);
      expect(local.showsApiKey, isFalse);

      const custom = OnboardingState(presetId: 'custom');
      expect(custom.needsBaseUrl, isTrue);
      expect(custom.showsApiKey, isTrue);
    });

    test('normalizedBaseUrl adds a scheme and strips slashes', () {
      String normalize(String url) =>
          OnboardingState(baseUrl: url).normalizedBaseUrl;
      expect(normalize(''), '');
      expect(normalize(' https://x.example/v1// '), 'https://x.example/v1');
      expect(normalize('localhost:1234/v1'), 'http://localhost:1234/v1');
      expect(normalize('api.example.com'), 'https://api.example.com');
    });

    test('providerErrors and errorFor', () {
      const empty = OnboardingState(presetId: 'custom');
      expect(empty.providerErrors, {
        ProviderField.baseUrl: ProviderFieldError.required,
        ProviderField.model: ProviderFieldError.required,
      });
      expect(empty.errorFor(ProviderField.model), isNull);
      expect(
        empty.copyWith(showProviderErrors: true).errorFor(ProviderField.model),
        ProviderFieldError.required,
      );
      expect(
        const OnboardingState(
          presetId: 'custom',
          baseUrl: 'mailto:me',
          model: 'm',
        ).providerErrors,
        {ProviderField.baseUrl: ProviderFieldError.invalidUrl},
      );
      expect(const OnboardingState().providerErrors, isEmpty);
    });

    test('draftConfig builds a provider from the preset', () {
      expect(const OnboardingState().draftConfig('x'), isNull);
      final config = const OnboardingState(
        presetId: 'groq',
        apiKey: ' key ',
        baseUrl: 'https://api.groq.com/openai/v1',
        model: ' m ',
      ).draftConfig('id');
      expect(config?.id, 'id');
      expect(config?.apiKey, 'key');
      expect(config?.model, 'm');
      expect(config?.presetId, 'groq');
    });

    test('savedDraft is null without a saved provider', () {
      expect(const OnboardingState().savedDraft, isNull);
      expect(const OnboardingState(presetId: 'groq').savedDraft, isNull);
    });

    test('copyWith keeps and resets values', () {
      const state = OnboardingState(
        selectedUrl: 'a',
        ownInstanceError: OwnInstanceError.empty,
        ownInstanceMessage: 'm',
        ownInstanceLatency: Duration(seconds: 1),
        presetId: 'groq',
        testOutput: 'o',
        testError: 'e',
        modelsError: 'me',
      );
      expect(state.copyWith(), state);
      final reset = state.copyWith(
        selectedUrl: () => null,
        ownInstanceError: () => null,
        ownInstanceMessage: () => null,
        ownInstanceLatency: () => null,
        presetId: () => null,
        testOutput: () => null,
        testError: () => null,
        modelsError: () => null,
      );
      expect(reset, const OnboardingState());
    });
  });
}
