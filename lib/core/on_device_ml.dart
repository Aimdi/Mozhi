import 'package:flutter/foundation.dart';
import 'package:mozhi/platform/mlkit_bindings.dart' as bindings;

/// Overrides [mlKitIncluded] in tests (null: use the build's value).
@visibleForTesting
bool? debugMlKitIncludedOverride;

/// Whether this build includes Google ML Kit (on-device text recognition).
/// False in the default build, true in the Play variant (see
/// `tool/play_prepare.sh`).
bool get mlKitIncluded => debugMlKitIncludedOverride ?? bindings.mlKitIncluded;

/// Overrides [offlineEngineIncluded] in tests (null: use the build's
/// value).
@visibleForTesting
bool? debugOfflineEngineIncludedOverride;

/// Whether this build includes an on-device translation engine: Mozilla's
/// Bergamot engine is in every build (default and Play), so only tests
/// turn it off.
bool get offlineEngineIncluded => debugOfflineEngineIncludedOverride ?? true;

/// Whether on-device engines can run on this platform at all (Android and
/// iOS, not the web or desktop), whether or not this build includes them.
bool get onDeviceMlPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Whether on-device (offline) translation can work here: the build has an
/// engine and the platform supports it. The engine may still be
/// unavailable on a particular device (`OfflineTranslator.isAvailable`,
/// e.g. an old 32-bit ARM CPU), which the Offline languages screen explains.
bool get onDeviceMlSupported => offlineEngineIncluded && onDeviceMlPlatform;
