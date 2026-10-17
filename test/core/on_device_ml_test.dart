import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/on_device_ml.dart';

void main() {
  tearDown(() {
    debugMlKitIncludedOverride = null;
    debugOfflineEngineIncludedOverride = null;
    debugDefaultTargetPlatformOverride = null;
  });

  group('on-device ML', () {
    test('follows the bindings unless overridden', () {
      // The default build has no ML Kit (tool/play_prepare.sh adds it).
      expect(mlKitIncluded, isFalse);
      debugMlKitIncludedOverride = true;
      expect(mlKitIncluded, isTrue);
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
