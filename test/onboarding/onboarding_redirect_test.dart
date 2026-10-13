import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/onboarding/onboarding.dart';
import 'package:mozhi/settings/models/app_settings.dart';

void main() {
  group('onboardingRedirect', () {
    const fresh = AppSettings();
    const done = AppSettings(onboardingComplete: true);

    test('sends first-run users to the onboarding', () {
      expect(onboardingRedirect(fresh, '/translate'), onboardingLocation);
      expect(onboardingRedirect(fresh, '/'), '/onboarding');
      expect(onboardingRedirect(fresh, '/settings/about'), '/onboarding');
    });

    test('does not redirect inside the onboarding', () {
      expect(onboardingRedirect(fresh, '/onboarding'), isNull);
      expect(onboardingRedirect(fresh, '/onboarding/ai'), isNull);
    });

    test('does nothing once onboarding is complete', () {
      expect(onboardingRedirect(done, '/translate'), isNull);
      expect(onboardingRedirect(done, '/onboarding'), isNull);
    });
  });
}
