import '../_tmp_w6e/debug.dart';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/offline/data/offline_model_file_picker.dart';
import 'package:mozhi/platform/free_space.dart' show storageChannelName;
import 'package:mozhi/platform/model_file_picker.dart';

class _MockFallback extends Mock implements OfflineModelFilePicker;

void main() {
  dumpFailures();
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(storageChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _MockFallback fallback;
  late Directory root;

  setUp(() {
    fallback = _MockFallback();
    when(() => fallback.pick(onCopying: any(named: 'onCopying')))
        .thenAnswer((_) async => const []);
    when(fallback.clearCopies).thenAnswer((_) async {});
    root = Directory.systemTemp.createTempSync('model_picker_');
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    root.deleteSync(recursive: true);
  });

  group('on Android', () {
    late List<MethodCall> calls;
    late Object? Function(MethodCall call) answer;

    setUp(() {
      calls = [];
      answer = (_) => null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return answer(call);
      });
    });

    ModelFilePicker picker() =>
        ModelFilePicker(isAndroid: true, fallback: fallback);

    test('picks documents in place and copies them on demand', () async {
      answer = (call) => switch (call.method) {
        'pickFiles' => [
          {'uri': 'content://a/1', 'name': 'model.gguf', 'size': 30},
          {'uri': 'content://a/2', 'name': 'other.bin', 'size': -1},
          {'uri': 3},
          'nonsense',
        ],
        'copyFile' => 30,
        _ => null,
      };
      final files = await picker().pick();
      expect(
        [for (final file in files) file.name],
        ['model.gguf', 'other.bin'],
      );
      expect(files.first.length, 30);
      expect(files.last.length, isNull);
      expect(files.first.path, isNull);
      expect(files.first.toString(), 'PickedModelFile(model.gguf, 30)');

      final target = File('${root.path}/staged.gguf');
      expect(await files.first.copyTo(target, maxBytes: 30), 30);
      expect(calls.last.method, 'copyFile');
      expect(calls.last.arguments, {
        'uri': 'content://a/1',
        'path': target.path,
        'maxBytes': 30,
      });
      verifyNever(() => fallback.pick(onCopying: any(named: 'onCopying')));
    });

    test('reports a failed copy as a file system error', () async {
      answer = (call) => switch (call.method) {
        'pickFiles' => [
          {'uri': 'content://a/1', 'name': 'model.gguf', 'size': 30},
        ],
        _ => throw PlatformException(code: 'io', message: 'disk full'),
      };
      final file = (await picker().pick()).single;
      await expectLater(
        file.copyTo(File('${root.path}/x'), maxBytes: 30),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            'disk full',
          ),
        ),
      );
      answer = (call) => call.method == 'pickFiles'
          ? [
              {'uri': 'content://a/1', 'name': 'model.gguf', 'size': 30},
            ]
          : null;
      final unanswered = (await picker().pick()).single;
      await expectLater(
        unanswered.copyTo(File('${root.path}/x'), maxBytes: 30),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('a cancelled pick is empty', () async {
      answer = (_) => const <Object?>[];
      expect(await picker().pick(), isEmpty);
      answer = (_) => null;
      expect(await picker().pick(), isEmpty);
    });

    test('falls back to the file picker without the platform side', () async {
      messenger.setMockMethodCallHandler(channel, null);
      final model = File('${root.path}/ggml-tiny.bin')
        ..writeAsBytesSync(List.filled(10, 1));
      when(() => fallback.pick(onCopying: any(named: 'onCopying')))
          .thenAnswer((_) async => [model.path]);
      final chooser = picker();
      final files = await chooser.pick();
      expect(files.single.path, model.path);
      expect(files.single.name, 'ggml-tiny.bin');
      expect(files.single.length, 10);
      await chooser.clearCopies();
      verify(fallback.clearCopies).called(1);
      // Only once per use of the fallback.
      await chooser.clearCopies();
      verifyNever(fallback.clearCopies);
    });
  });

  test('off Android it uses the file picker', () async {
    void copying() {}
    when(() => fallback.pick(onCopying: any(named: 'onCopying')))
        .thenAnswer((invocation) async {
          expect(invocation.namedArguments[#onCopying], same(copying));
          return ['${root.path}/missing.gguf'];
        });
    final chooser = ModelFilePicker(isAndroid: false, fallback: fallback);
    final files = await chooser.pick(onCopying: copying);
    expect(files.single.length, isNull);
    // Nothing copied on Android: nothing to clear before a pick.
    expect(ModelFilePicker().fallback, isA<OfflineModelFilePicker>());
  });

  group('PickedModelFile.local', () {
    test('copies at most one byte more than asked', () async {
      final source = File('${root.path}/model.gguf')
        ..writeAsBytesSync(List.generate(5000, (i) => i & 0xff));
      final file = PickedModelFile.local(source.path);
      final target = File('${root.path}/copy.gguf');
      expect(await file.copyTo(target, maxBytes: 5000), 5000);
      expect(target.readAsBytesSync(), source.readAsBytesSync());
      expect(await file.copyTo(target, maxBytes: 100), 101);
      expect(target.lengthSync(), 101);
    });
  });
}
