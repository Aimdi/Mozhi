import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app/shared_files.dart';

const _token = '0123456789abcdef0123456789abcdef';
const _other = 'ffffffffffffffffffffffffffffffff';

void main() {
  late Directory cache;
  late DateTime now;

  setUp(() {
    cache = Directory.systemTemp.createTempSync('shared_files_test');
    now = DateTime.now();
  });

  tearDown(() => cache.deleteSync(recursive: true));

  File share(String token, String name, List<int> bytes) {
    final folder = Directory('${cache.path}/${SharedFiles.folder}/$token')
      ..createSync(recursive: true);
    return File('${folder.path}/$name')..writeAsBytesSync(bytes);
  }

  Future<SharedFile?> take(String? token, {bool keep = false}) =>
      SharedFiles.take(
        token,
        keep: keep,
        cacheDirectory: () async => cache.path,
        clock: () => now,
      );

  test('tokens are 32 lower-case hex digits', () {
    expect(SharedFiles.isToken(_token), isTrue);
    expect(SharedFiles.isToken(null), isFalse);
    expect(SharedFiles.isToken('../../etc'), isFalse);
    expect(SharedFiles.isToken(_token.toUpperCase()), isFalse);
    expect(SharedFiles.isToken('${_token}0'), isFalse);
  });

  test('reads a shared document once and deletes it', () async {
    share(_token, 'talk.srt', [49, 10]);

    final file = await take(_token);

    expect(file!.name, 'talk.srt');
    expect(file.bytes, [49, 10]);
    expect(file.path, isNull);
    expect(file.toString(), 'SharedFile(talk.srt, 2 bytes)');
    expect(
      Directory('${cache.path}/${SharedFiles.folder}/$_token').existsSync(),
      isFalse,
    );
    expect(await take(_token), isNull);
  });

  test('keeps a shared image for on-device text recognition', () async {
    final stored = share(_token, 'photo.png', [1, 2, 3]);

    final file = await take(_token, keep: true);

    expect(file!.path, stored.path);
    expect(stored.existsSync(), isTrue);
  });

  test('ignores malformed and unknown tokens', () async {
    share(_token, 'a.txt', [1]);
    expect(await take('nope'), isNull);
    expect(await take(_other), isNull);
    expect(await take(null), isNull);
  });

  test('nothing was shared yet', () async {
    expect(await take(_token), isNull);
  });

  test('an empty folder is removed', () async {
    Directory('${cache.path}/${SharedFiles.folder}/$_token')
        .createSync(recursive: true);
    expect(await take(_token), isNull);
    expect(
      Directory('${cache.path}/${SharedFiles.folder}/$_token').existsSync(),
      isFalse,
    );
  });

  test('deletes other shares older than an hour', () async {
    share(_other, 'old.txt', [1]);
    share(_token, 'new.txt', [2]);
    now = now.add(SharedFiles.maxAge + const Duration(minutes: 1));

    final file = await take(_token);

    expect(file!.name, 'new.txt');
    expect(
      Directory('${cache.path}/${SharedFiles.folder}/$_other').existsSync(),
      isFalse,
    );
  });

  test('a failing cache directory means nothing was shared', () async {
    final file = await SharedFiles.take(
      _token,
      cacheDirectory: () async => throw const FileSystemException('no'),
    );
    expect(file, isNull);
  });
}
