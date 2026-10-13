import 'package:mozhi/settings/models/app_settings.dart';

/// Location of the onboarding flow.
const onboardingLocation = '/onboarding';

/// Router redirect for the first run: returns [onboardingLocation] while
/// onboarding is incomplete and [location] is not already inside it,
/// otherwise null (no redirect).
String? onboardingRedirect(AppSettings s, String location) {
  if (s.onboardingComplete) return null;
  if (location.startsWith(onboardingLocation)) return null;
  return onboardingLocation;
}
