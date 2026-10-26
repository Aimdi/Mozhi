import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_speech/src/file_hashing.dart';

import '../helpers/fake_models.dart';

void main() {
  late Directory root;
  late Uint8List bytes;
  late File input;

  setUp(() {
    root = Directory.systemTemp.createTempSync('whisper_hashing_');
    bytes = fakeModelBytes(3 * FileHashing.chunkSize + 123);
    input = File(p.join(root.path, 'ggml-tiny.bin'))..writeAsBytesSync(bytes);
  });

  tearDown(() => root.deleteSync(recursive: true));

  String digestOf(List<int> data) => sha256.convert(data).toString();
  String sha1Of(List<int> data) => sha1.convert(data).toString();
  FileDigest digest(List<int> data) =>
      FileDigest(size: data.length, sha1: sha1Of(data), sha256: digestOf(data));

  group(FileDigest, () {
    test('compares by value', () {
      const a = FileDigest(size: 1, sha1: 'cd', sha256: 'ab');
      expect(a, const FileDigest(size: 1, sha1: 'cd', sha256: 'ab'));
      expect(
        a.hashCode,
        const FileDigest(size: 1, sha1: 'cd', sha256: 'ab').hashCode,
      );
      expect(a, isNot(const FileDigest(size: 2, sha1: 'cd', sha256: 'ab')));
      expect(a, isNot(const FileDigest(size: 1, sha1: 'ce', sha256: 'ab')));
      expect(a.toString(), 'FileDigest(1, cd, ab)');
    });
  });

  for (final (name, hashing) in [
    ('isolate', const FileHashing.isolate()),
    ('inline', const FileHashing.inline()),
  ]) {
    group('FileHashing.$name', () {
      test('hashes a file', () async {
        expect(await hashing.hashFile(input.path), digest(bytes));
      });

      test('stops reading after the limit', () async {
        final digest = await hashing.hashFile(
          input.path,
          maxBytes: FileHashing.chunkSize,
        );
        expect(digest.size, greaterThan(FileHashing.chunkSize));
        expect(digest.size, lessThan(bytes.length));
      });

      test('fails for a missing file', () async {
        await expectLater(
          hashing.hashFile(p.join(root.path, 'missing')),
          throwsA(isA<FileSystemException>()),
        );
      });

      test('copies while hashing', () async {
        final output = p.join(root.path, 'copy.bin');
        File(output).writeAsBytesSync([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
        final copied = await hashing.copyFile(input.path, output);
        expect(copied, digest(bytes));
        expect(File(output).readAsBytesSync(), bytes);

        final short = await hashing.copyFile(input.path, output, maxBytes: 10);
        expect(short.size, greaterThan(10));
        expect(File(output).lengthSync(), short.size);
      });

      test('a copy fails when the target cannot be written', () async {
        await expectLater(
          hashing.copyFile(input.path, p.join(root.path, 'no', 'such', 'f')),
          throwsA(isA<FileSystemException>()),
        );
      });

      test('streams: a file first, then chunks', () async {
        final head = File(p.join(root.path, 'head'))
          ..writeAsBytesSync(bytes.sublist(0, 1000));
        final hasher = await hashing.stream();
        expect(await hasher.addFile(head.path), 1000);
        await hasher.add(bytes.sublist(1000, 5000));
        // Not typed data: converted.
        await hasher.add(List<int>.of(bytes.sublist(5000)));
        expect(await hasher.close(), digest(bytes));
        // Closed already.
        hasher.abort();
      });

      test('streams: a missing file fails, the hasher goes on', () async {
        final hasher = await hashing.stream();
        await expectLater(
          hasher.addFile(p.join(root.path, 'missing')),
          throwsA(isA<FileSystemException>()),
        );
        await hasher.add([1, 2, 3]);
        expect(await hasher.close(), digest([1, 2, 3]));
      });

      test('streams: an aborted hasher stops', () async {
        final hasher = await hashing.stream();
        await hasher.add([1, 2, 3]);
        hasher
          ..abort()
          ..abort();
        if (name == 'isolate') {
          await expectLater(hasher.add([4]), throwsStateError);
          await expectLater(hasher.close(), throwsStateError);
          await expectLater(hasher.addFile(input.path), throwsStateError);
        }
      });
    });
  }

  test('the isolate hasher holds a fast download back', () async {
    final hasher = await const FileHashing.isolate().stream();
    final chunk = Uint8List(4 << 20);
    var total = 0;
    var waited = false;
    for (var i = 0; i < 20; i++) {
      final added = hasher.add(chunk);
      total += chunk.length;
      // Completes at once while little waits; else once it caught up.
      var done = false;
      added.whenComplete(() => done = true).ignore();
      await Future<void>.value();
      if (!done) waited = true;
      await added;
    }
    final digest = await hasher.close();
    expect(digest.size, total);
    expect(digest.sha256, sha256.convert(Uint8List(total)).toString());
    expect(waited, isTrue);
  });
}
