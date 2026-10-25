import 'package:mozhi/l10n/l10n.dart';

/// "Engine build: i8mm" ([build]: the build of an on-device engine's
/// library that runs on this processor, e.g. `baseline`, `dotprod`,
/// `i8mm`), or, when a faster build ([skipped]) crashed the app and was
/// turned off, a line that says so. For support (On-device AI and voice
/// input settings).
String engineBuildText(
  AppLocalizations l10n,
  String build, {
  String? skipped,
}) => skipped == null
    ? l10n.commonEngineBuild(build)
    : l10n.commonEngineBuildFallback(build, skipped);
