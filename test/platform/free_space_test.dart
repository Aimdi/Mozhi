import 'package:bergamot_translator/bergamot_translator.dart'
    show ModelInsufficientSpaceException;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_engine/llama_engine.dart'
    show LlamaInsufficientSpaceException;
import 'package:mozhi/l10n/gen/app_localizations_en.dart';
import 'package:mozhi/platform/engine_build_text.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:tesseract_ocr/tesseract_ocr.dart'
    show TessdataInsufficientSpaceException;
import 'package:whisper_speech/whisper_speech.dart'
    show WhisperInsufficientSpaceException;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(storageChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final l10n = AppLocalizationsEn();
  const mebibyte = 1024 * 1024;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group(FreeSpace, () {
    test('asks Android for the free bytes of a path', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 1234;
      });
      final space = FreeSpace(isAndroid: true, isWeb: false);
      expect(await space.availableBytes('/data/models'), 1234);
      expect(await space.call('/x'), 1234);
      expect(await space.availableBytes(), 1234);
      expect(calls.map((call) => call.method), everyElement('freeBytes'));
      expect(calls.first.arguments, {'path': '/data/models'});
      expect(calls.last.arguments, <String, Object?>{});
    });

    test('counts what Android cannot tell as unknown', () async {
      final space = FreeSpace(isAndroid: true, isWeb: false);
      messenger.setMockMethodCallHandler(channel, (_) async => -1);
      expect(await space.availableBytes(), isNull);
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await space.availableBytes(), isNull);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'statfs'),
      );
      expect(await space.availableBytes(), isNull);
      messenger.setMockMethodCallHandler(channel, (_) async => 'nonsense');
      expect(await space.availableBytes(), isNull);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await space.availableBytes(), isNull);
    });

    test('is unknown off Android and asks the browser on the web', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => fail('asked'));
      expect(await FreeSpace(isAndroid: false, isWeb: false).call('/'), isNull);
      expect(await FreeSpace().availableBytes(), isNull);
      expect(
        await FreeSpace(isWeb: true, browser: () async => 99).availableBytes(),
        99,
      );
      expect(
        await FreeSpace(
          isWeb: true,
          browser: () async => throw StateError('no estimate'),
        ).availableBytes(),
        isNull,
      );
      expect(await FreeSpace(isWeb: true).availableBytes(), isNull);
    });
  });

  test('a download needs its bytes plus 5 %, at least 50 MiB', () {
    expect(requiredFreeSpace(0), freeSpaceMarginBytes);
    expect(requiredFreeSpace(mebibyte), mebibyte + freeSpaceMarginBytes);
    const large = 3 << 30;
    expect(requiredFreeSpace(large), large + large ~/ 20);
  });

  group('ensureFreeSpace', () {
    FreeSpace answering(int? bytes) =>
        FreeSpace(isWeb: true, browser: () async => bytes);

    test('passes with room, nothing to write or an unknown space', () async {
      await ensureFreeSpace(
        mebibyte,
        freeSpace: answering(requiredFreeSpace(mebibyte)),
      );
      await ensureFreeSpace(0, freeSpace: answering(0));
      await ensureFreeSpace(mebibyte, freeSpace: answering(null));
      // The app's instance: unknown in tests.
      await ensureFreeSpace(mebibyte);
    });

    test('refuses without room', () async {
      await expectLater(
        ensureFreeSpace(mebibyte, freeSpace: answering(10)),
        throwsA(
          isA<NotEnoughSpaceException>()
              .having((e) => e.availableBytes, 'available', 10)
              .having(
                (e) => e.requiredBytes,
                'required',
                requiredFreeSpace(mebibyte),
              )
              .having(
                (e) => e.toString(),
                'toString',
                startsWith('NotEnoughSpaceException(needs'),
              ),
        ),
      );
    });
  });

  group(SpaceShortfall, () {
    test("reads every manager's exception", () {
      const shortfall = SpaceShortfall(requiredBytes: 2, availableBytes: 1);
      for (final error in const <Object>[
        NotEnoughSpaceException(requiredBytes: 2, availableBytes: 1),
        LlamaInsufficientSpaceException(
          'hy',
          'x',
          requiredBytes: 2,
          availableBytes: 1,
        ),
        WhisperInsufficientSpaceException(
          'tiny',
          'x',
          requiredBytes: 2,
          availableBytes: 1,
        ),
        TessdataInsufficientSpaceException(
          'deu',
          'x',
          requiredBytes: 2,
          availableBytes: 1,
        ),
        ModelInsufficientSpaceException(
          'en-de',
          'x',
          requiredBytes: 2,
          availableBytes: 1,
        ),
      ]) {
        expect(SpaceShortfall.of(error), shortfall);
      }
      expect(SpaceShortfall.of(null), isNull);
      expect(SpaceShortfall.of(StateError('x')), isNull);
      expect(shortfall.hashCode, isA<int>());
      expect(shortfall.toString(), 'SpaceShortfall(2, 1)');
      expect(
        shortfall,
        isNot(const SpaceShortfall(requiredBytes: 2, availableBytes: 0)),
      );
    });

    test('says how much it needs and has', () {
      const shortfall = SpaceShortfall(
        requiredBytes: 1288490189, // 1.2 GiB
        availableBytes: 300 * mebibyte,
      );
      expect(
        shortfall.message(l10n),
        'Not enough free space: needs 1.2 GB, 300 MB free.',
      );
    });
  });

  test('formats storage sizes', () {
    expect(formatStorageSize(l10n, 3 << 30), '3.0 GB');
    expect(formatStorageSize(l10n, 640 * mebibyte), '640 MB');
    expect(formatStorageSize(l10n, (4.5 * mebibyte).round()), '4.5 MB');
    expect(formatStorageSize(l10n, 300 * 1024), '0.3 MB');
  });

  test('names the engine build', () {
    expect(engineBuildText(l10n, 'i8mm'), 'Engine build: i8mm');
    expect(
      engineBuildText(l10n, 'baseline', skipped: 'i8mm'),
      contains('the faster i8mm build'),
    );
  });
}
