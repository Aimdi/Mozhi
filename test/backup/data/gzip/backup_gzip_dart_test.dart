import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/gzip/backup_gzip_dart.dart';
import 'package:mozhi/backup/data/gzip/backup_gzip_io.dart' as io;

void main() {
  final text = Uint8List.fromList(utf8.encode('Guten Abend. ' * 10000));

  group('dartGzipEncode', () {
    test('writes standard gzip that the Android app opens', () async {
      final packed = await dartGzipEncode(text);

      expect(gzip.decode(packed), text);
      expect(await io.gzipDecode(packed, maxLength: text.length), text);
    });

    test('also for empty data and more than one stored block', () async {
      final large = Uint8List.fromList(List.generate(200000, (i) => i % 256));
      for (final data in [Uint8List(0), large]) {
        expect(gzip.decode(await dartGzipEncode(data)), data);
      }
    });
  });

  group('dartGzipDecode', () {
    test('opens a backup the Android app compressed', () async {
      final packed = await io.gzipEncode(text);

      expect(await dartGzipDecode(packed, maxLength: text.length), text);
    });

    test('opens its own output', () async {
      final packed = await dartGzipEncode(text);

      expect(await dartGzipDecode(packed, maxLength: text.length), text);
    });

    test('refuses data that is not gzip', () async {
      await expectLater(
        dartGzipDecode(Uint8List.fromList([1, 2, 3, 4]), maxLength: 100),
        throwsFormatException,
      );
    });

    test('refuses damaged gzip', () async {
      final packed = await io.gzipEncode(text);
      final damaged = Uint8List.fromList(packed)
        ..setAll(20, List.filled(40, 0xff));
      final truncated = Uint8List.sublistView(packed, 0, packed.length ~/ 2);

      for (final data in [damaged, truncated]) {
        await expectLater(
          dartGzipDecode(data, maxLength: text.length),
          throwsFormatException,
        );
      }
    });

    test('stops at maxLength', () async {
      final packed = await io.gzipEncode(text);

      await expectLater(
        dartGzipDecode(packed, maxLength: text.length - 1),
        throwsFormatException,
      );
    });
  });
}
