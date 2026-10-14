import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/on_device_ml.dart';

void main() {
  tearDown(() {
    debugMlKitIncludedOverride = null;
    debugDefaultTargetPlatformOverride = null;
  });

  group('on-device ML', () {
    test('follows the bindings unless overridden', () {
      expect(mlKitIncluded, isTrue);
      debugMlKitIncludedOverride = false;
      expect(mlKitIncluded, isFalse);
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      test('is supported on ${platform.name} when ML Kit is included', () {
        debugDefaultTargetPlatformOverride = platform;
        expect(onDeviceMlPlatform, isTrue);
        expect(onDeviceMlSupported, isTrue);

        debugMlKitIncludedOverride = false;
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
