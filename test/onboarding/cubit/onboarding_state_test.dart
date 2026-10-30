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
      const untranslated = InstancePing.noTranslation('500');
      expect(untranslated.status, PingStatus.noTranslation);
      expect(untranslated.error, '500');
      expect(untranslated.isSuccess, isFalse);
      expect(untranslated, isNot(const InstancePing.failure('500')));
    });
  });

  group('OnboardingState', () {
    test('isLastStep is true on the service step only', () {
      expect(const OnboardingState().isLastStep, isFalse);
      expect(
        const OnboardingState(step: OnboardingStep.languages).isLastStep,
        isFalse,
      );
      expect(
        const OnboardingState(step: OnboardingStep.service).isLastStep,
        isTrue,
      );
    });

    test('steps leave out the privacy step without an on-device engine', () {
      expect(const OnboardingState().steps, OnboardingStep.values);
      expect(const OnboardingState(onDevice: false).steps, [
        OnboardingStep.welcome,
        OnboardingStep.languages,
        OnboardingStep.service,
      ]);
      expect(
        const OnboardingState(onDevice: false).copyWith(),
        const OnboardingState(onDevice: false),
      );
      expect(
        const OnboardingState().copyWith(onDevice: false).onDevice,
        isFalse,
      );
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

    test('noneTranslates when a server answered without translating', () {
      const done = ServiceStatus.done;
      expect(
        const OnboardingState(
          serviceStatus: done,
          pings: {
            'a': InstancePing.noTranslation('500'),
            'b': InstancePing.failure('x'),
          },
        ).noneTranslates,
        isTrue,
      );
      expect(
        const OnboardingState(
          serviceStatus: done,
          pings: {'a': InstancePing.failure('x')},
        ).noneTranslates,
        isFalse,
      );
      expect(
        const OnboardingState(
          serviceStatus: done,
          pings: {
            'a': InstancePing.noTranslation('500'),
            'b': InstancePing.success(Duration(milliseconds: 9)),
          },
        ).noneTranslates,
        isFalse,
      );
      expect(
        const OnboardingState(pings: {'a': InstancePing.noTranslation('500')})
            .noneTranslates,
        isFalse,
      );
    });

    test('copyWith keeps and resets values', () {
      const state = OnboardingState(
        selectedUrl: 'a',
        ownInstanceError: OwnInstanceError.empty,
        ownInstanceMessage: 'm',
        ownInstanceLatency: Duration(seconds: 1),
      );
      expect(state.copyWith(), state);
      final reset = state.copyWith(
        selectedUrl: () => null,
        ownInstanceError: () => null,
        ownInstanceMessage: () => null,
        ownInstanceLatency: () => null,
      );
      expect(reset, const OnboardingState());
    });
  });
}
