import 'dart:convert';

import 'package:mozhi_api/mozhi_api.dart';
import 'package:test/test.dart';

import '../fixtures.dart';

void main() {
  group(MozhiVersion, () {
    test('fromJson reads fiberversion and goversion', () {
      final version = MozhiVersion.fromJson(
        jsonDecode(versionJson) as Map<String, dynamic>,
      );

      expect(version.fiberVersion, 'v2.52.5');
      expect(version.goVersion, 'go1.23.1');
    });

    test('fromJson maps missing and mistyped fields to empty strings', () {
      final version = MozhiVersion.fromJson(const {'goversion': 1.23});

      expect(version.fiberVersion, isEmpty);
      expect(version.goVersion, isEmpty);
    });
  });
}
