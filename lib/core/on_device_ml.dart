import 'package:flutter/foundation.dart';
import 'package:mozhi/platform/mlkit_bindings.dart' as bindings;

/// Overrides [mlKitIncluded] in tests (null: use the build's value).
@visibleForTesting
bool? debugMlKitIncludedOverride;

/// Whether this build includes Google ML Kit. False in the F-Droid build
/// (see `tool/fdroid_prepare.sh`).
bool get mlKitIncluded => debugMlKitIncludedOverride ?? bindings.mlKitIncluded;

/// Whether ML Kit can run on this platform at all (Android and iOS, not the
/// web or desktop), whether or not this build includes it.
bool get onDeviceMlPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Whether on-device translation and text recognition work here: ML Kit is
/// in the build and the platform supports it.
bool get onDeviceMlSupported => mlKitIncluded && onDeviceMlPlatform;
