import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/on_device_ml.dart';
import 'package:mozhi/platform/mlkit_bindings.dart' as bindings;

void main() {
  tearDown(() {
    debugMlKitIncludedOverride = null;
    debugOfflineEngineIncludedOverride = null;
    debugDefaultTargetPlatformOverride = null;
  });

  group('on-device ML', () {
    test('follows the bindings unless overridden', () {
      // False in the default build, true in the Play variant.
      expect(mlKitIncluded, bindings.mlKitIncluded);
      debugMlKitIncludedOverride = !bindings.mlKitIncluded;
      expect(mlKitIncluded, !bindings.mlKitIncluded);
    });

    test('always includes the offline engine unless overridden', () {
      expect(offlineEngineIncluded, isTrue);
      debugOfflineEngineIncludedOverride = false;
      expect(offlineEngineIncluded, isFalse);
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      test('supports offline translation on ${platform.name}', () {
        debugDefaultTargetPlatformOverride = platform;
        expect(onDeviceMlPlatform, isTrue);
        expect(onDeviceMlSupported, isTrue);

        // Independent of ML Kit (the engine is Mozilla's Bergamot).
        debugMlKitIncludedOverride = true;
        expect(onDeviceMlSupported, isTrue);

        debugOfflineEngineIncludedOverride = false;
        expect(onDeviceMlPlatform, isTrue);
        expect(onDeviceMlSupported, isFalse);
      });
    }

    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      test('is not supported on ${platform.name}', () {
        debugDefaultTargetPlatformOverride = platform;
        expect(onDeviceMlPlatform, isFalse);
        expect(onDeviceMlSupported, isFalse);
      });
    }
  });
}
