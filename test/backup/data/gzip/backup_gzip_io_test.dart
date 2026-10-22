import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/data/gzip/backup_gzip_io.dart';

void main() {
  final text = Uint8List.fromList(utf8.encode('Guten Abend. ' * 1000));

  test('compresses to standard gzip and back', () async {
    final packed = await gzipEncode(text);

    expect(packed.length, lessThan(text.length ~/ 10));
    expect(gzip.decode(packed), text);
    expect(await gzipDecode(packed, maxLength: text.length), text);
  });

  test('refuses data that is not gzip', () async {
    await expectLater(
      gzipDecode(Uint8List.fromList([1, 2, 3, 4]), maxLength: 100),
      throwsFormatException,
    );
  });

  test('stops at maxLength', () async {
    final packed = await gzipEncode(text);

    await expectLater(
      gzipDecode(packed, maxLength: text.length - 1),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('too large'),
        ),
      ),
    );
  });
}
