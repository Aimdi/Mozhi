import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_codec.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_worker.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_worker_io.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_worker_web.dart' as web;

import '../helpers/fake_packs.dart';

void main() {
  final a = List.generate(32, (i) => i);
  final b = List.generate(32, (i) => 100 + i);
  const deflate = ZLibPairingDeflate();

  /// One side's codec ([sender]: keys a→b) and the other's.
  PairingFrameCodec codec({bool sender = true, PairingDeflate? deflating}) =>
      PairingFrameCodec(
        outgoing: sender ? a : b,
        incoming: sender ? b : a,
        deflate: deflating,
      );

  /// [frame] without its 4-byte length.
  Uint8List body(Uint8List frame) {
    expect(ByteData.sublistView(frame).getUint32(0), frame.length - 4);
    return Uint8List.sublistView(frame, 4);
  }

  /// [length] bytes that do not compress.
  Uint8List noise(int length, [int seed = 1]) {
    final random = Random(seed);
    return Uint8List.fromList([
      for (var i = 0; i < length; i++) random.nextInt(256),
    ]);
  }

  /// [length] bytes that compress well (text-like).
  Uint8List text(int length) => Uint8List.fromList([
    for (var i = 0; i < length; i++) 'the quick brown fox '.codeUnitAt(i % 20),
  ]);

  group('PairingFrameCodec', () {
    test('seals and opens messages and data', () {
      final frame = codec().seal(0, PairingFrameType.message, [1, 2, 3]);
      final (type, payload) = codec(sender: false).open(0, body(frame));
      expect(type, PairingFrameType.message);
      expect(payload, [1, 2, 3]);
    });

    test('refuses a frame under another number or key', () {
      final frame = body(codec().seal(3, PairingFrameType.data, [1]));
      expect(
        () => codec(sender: false).open(2, frame),
        throwsA(isA<PairingAuthenticationException>()),
      );
      expect(
        () => codec().open(3, frame),
        throwsA(isA<PairingAuthenticationException>()),
      );
      expect(
        () => codec().open(0, Uint8List(16)),
        throwsA(isA<PairingProtocolException>()),
      );
    });

    test('numbers frames beyond 32 bits', () {
      expect(PairingFrameCodec.nonceOf(0x100000001), [
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        1,
      ]);
    });

    test('compresses data that gets smaller, round trip', () {
      final data = text(64 * 1024);
      final sealed = codec(deflating: deflate)
          .sealData(0, data, compress: true);
      expect(sealed.sent, lessThan(data.length ~/ 10));
      expect(sealed.frame.length, lessThan(data.length ~/ 10));
      final (type, payload) = codec(
        sender: false,
        deflating: deflate,
      ).open(0, body(sealed.frame));
      expect(type, PairingFrameType.data);
      expect(payload, data);
    });

    test('sends as it is what does not compress, or when not asked', () {
      final data = noise(64 * 1024);
      final sealed = codec(deflating: deflate)
          .sealData(0, data, compress: true);
      expect(sealed.sent, data.length);
      final plain = text(1000);
      expect(
        codec(deflating: deflate).sealData(0, plain, compress: false).sent,
        plain.length,
      );
      // Without compression, nothing is compressed.
      expect(codec().sealData(0, plain, compress: true).sent, plain.length);
      // Either way the other side reads it.
      final (_, payload) = codec(sender: false)
          .open(0, body(codec().sealData(0, plain, compress: true).frame));
      expect(payload, plain);
    });

    test('a phone without compression refuses compressed data', () {
      final sealed = codec(deflating: deflate)
          .sealData(0, text(4096), compress: true);
      expect(
        () => codec(sender: false).open(0, body(sealed.frame)),
        throwsA(isA<PairingProtocolException>()),
      );
    });

    test('refuses data that inflates beyond a frame', () {
      // 16 MiB of zeros compress to a few KiB.
      final bomb = deflate.compress(Uint8List(16 << 20));
      expect(bomb.length, lessThan(PairingFrameCodec.maxPayload));
      final frame = codec().seal(0, PairingFrameType.compressedData, bomb);
      expect(
        () => codec(sender: false, deflating: deflate).open(0, body(frame)),
        throwsA(isA<PairingProtocolException>()),
      );
    });

    test('refuses data that does not inflate, and unknown types', () {
      final broken = codec().seal(0, PairingFrameType.compressedData, [
        0xff,
        0xff,
        0xff,
      ]);
      expect(
        () => codec(sender: false, deflating: deflate).open(0, body(broken)),
        throwsA(isA<PairingProtocolException>()),
      );
      final unknown = codec().seal(0, 9, [1]);
      expect(
        () => codec(sender: false).open(0, body(unknown)),
        throwsA(isA<PairingProtocolException>()),
      );
    });

    test('hashes the file data it opens, inflated', () {
      final sending = codec(deflating: deflate);
      final receiving = codec(sender: false, deflating: deflate);
      final first = text(70000);
      final second = noise(5000);
      receiving
        ..startHash(sha256: true, sha1: true)
        ..open(0, body(sending.sealData(0, first, compress: true).frame))
        // Messages are not file data.
        ..open(1, body(sending.seal(1, PairingFrameType.message, [1])))
        ..open(2, body(sending.sealData(2, second, compress: true).frame));
      final all = [...first, ...second];
      expect(receiving.finishHash(), (
        sha256: sha256Of(all),
        sha1: sha1Of(all),
      ));
      // Hashing stopped, and only what is asked for is hashed.
      receiving
        ..open(3, body(sending.sealData(3, first, compress: true).frame))
        ..startHash(sha256: false, sha1: true);
      expect(receiving.finishHash(), (sha256: null, sha1: sha1Of(const [])));
    });
  });

  group('ZLibPairingDeflate', () {
    test('inflates what it compressed, at any level', () {
      final data = text(100000);
      const best = ZLibPairingDeflate(level: 9);
      expect(deflate.inflate(best.compress(data), limit: data.length), data);
      expect(
        () => deflate.inflate(best.compress(data), limit: data.length - 1),
        throwsA(isA<PairingProtocolException>()),
      );
    });
  });

  group('IsolatePairingFrameWorker', () {
    late IsolatePairingFrameWorker sending;
    late IsolatePairingFrameWorker receiving;

    setUp(() {
      sending = IsolatePairingFrameWorker(outgoing: a, incoming: b);
      receiving = IsolatePairingFrameWorker(outgoing: b, incoming: a);
    });

    tearDown(() {
      sending.close();
      receiving.close();
    });

    test('round-trips frames through its isolate', () async {
      final frame = await sending.seal(
        0,
        PairingFrameType.message,
        Uint8List.fromList([7]),
      );
      // What the worker seals, the codec opens, and back.
      final (type, payload) = codec(sender: false).open(0, body(frame));
      expect(type, PairingFrameType.message);
      expect(payload, [7]);
      final back = codec(sender: false).seal(0, PairingFrameType.data, [8, 9]);
      final (backType, backPayload) = await sending.open(0, body(back));
      expect(backType, PairingFrameType.data);
      expect(backPayload, [8, 9]);
    });

    test('compresses, inflates and hashes in its isolate', () async {
      final chunks = [text(64 * 1024), noise(64 * 1024), text(10)];
      await receiving.startHash(sha256: true, sha1: false);
      for (final (number, chunk) in chunks.indexed) {
        final sealed = await sending.sealData(number, chunk, compress: true);
        if (number == 0) expect(sealed.sent, lessThan(chunk.length ~/ 10));
        if (number == 1) expect(sealed.sent, chunk.length);
        final (type, payload) = await receiving.open(
          number,
          body(sealed.frame),
        );
        expect(type, PairingFrameType.data);
        expect(payload, chunk);
      }
      final all = [for (final chunk in chunks) ...chunk];
      expect(await receiving.finishHash(), (sha256: sha256Of(all), sha1: null));
    });

    test('reports failures from its isolate', () async {
      final frame = await sending.seal(0, PairingFrameType.data, Uint8List(10));
      await expectLater(
        sending.open(0, body(frame)),
        throwsA(isA<PairingAuthenticationException>()),
      );
      final bomb = await sending.seal(
        1,
        PairingFrameType.compressedData,
        deflate.compress(Uint8List(4 << 20)),
      );
      await expectLater(
        receiving.open(1, body(bomb)),
        throwsA(isA<PairingProtocolException>()),
      );
      // A failure does not stop the worker.
      final good = await sending.seal(0, PairingFrameType.data, Uint8List(3));
      expect((await receiving.open(0, body(good))).$2, hasLength(3));
    });

    test('fails what is pending and what comes after it closed', () async {
      await sending.seal(0, PairingFrameType.data, Uint8List(1));
      final pending = sending.seal(
        1,
        PairingFrameType.data,
        Uint8List(1 << 18),
      );
      sending.close();
      await expectLater(pending, throwsA(isA<PairingClosedException>()));
      await expectLater(
        sending.seal(2, PairingFrameType.data, Uint8List(1)),
        throwsA(isA<PairingClosedException>()),
      );
      sending.close();
    });

    test('fails the calls it was working on when it closes', () async {
      final pending = sending.seal(
        0,
        PairingFrameType.data,
        Uint8List(8 << 20),
      );
      await Future<void>.delayed(Duration.zero);
      sending.close();
      await expectLater(pending, throwsA(isA<PairingClosedException>()));
    });

    test('reports other errors as protocol errors', () async {
      final worker = IsolatePairingFrameWorker(
        outgoing: a,
        incoming: b,
        deflate: const _FailingDeflate(),
      );
      addTearDown(worker.close);
      await expectLater(
        worker.sealData(0, Uint8List(10), compress: true),
        throwsA(isA<PairingProtocolException>()),
      );
    });

    test('a worker that dies fails its calls', () async {
      final worker = IsolatePairingFrameWorker(
        outgoing: a,
        incoming: b,
        deflate: const _DyingDeflate(),
      );
      addTearDown(worker.close);
      await expectLater(
        worker.sealData(0, Uint8List(10), compress: true),
        throwsA(isA<PairingClosedException>()),
      );
      await expectLater(
        worker.seal(1, PairingFrameType.data, Uint8List(1)),
        throwsA(isA<PairingClosedException>()),
      );
    });

    test('closing while it starts stops it', () async {
      final first = receiving.startHash(sha256: true, sha1: true);
      receiving.close();
      await expectLater(first, throwsA(isA<PairingClosedException>()));
    });

    test('is what the app uses', () {
      final worker = PairingFrameWorker.start(outgoing: a, incoming: b);
      expect(worker, isA<IsolatePairingFrameWorker>());
      worker.close();
      expect(PairingFrameWorker.inflates, isTrue);
    });
  });

  group('InlinePairingFrameWorker', () {
    test('round-trips frames with a pause before each', () async {
      final sending = InlinePairingFrameWorker(codec(deflating: deflate));
      final receiving = InlinePairingFrameWorker(
        codec(sender: false, deflating: deflate),
      );
      var ticks = 0;
      final ticker = Timer.periodic(Duration.zero, (_) => ticks++);
      addTearDown(ticker.cancel);
      await receiving.startHash(sha256: false, sha1: true);
      final data = text(50000);
      final sealed = await sending.sealData(0, data, compress: true);
      expect(sealed.sent, lessThan(data.length));
      expect((await receiving.open(0, body(sealed.frame))).$2, data);
      final message = await sending.seal(
        1,
        PairingFrameType.message,
        Uint8List(2),
      );
      expect((await receiving.open(1, body(message))).$1, 1);
      expect((await receiving.finishHash()).sha1, sha1Of(data));
      // Timers got their turn between the frames.
      expect(ticks, greaterThan(0));
      receiving.close();
      await expectLater(
        receiving.finishHash(),
        throwsA(isA<PairingClosedException>()),
      );
    });

    test('is what a browser uses, without compression', () async {
      final worker = web.startPairingFrameWorker(outgoing: a, incoming: b);
      expect(worker, isA<InlinePairingFrameWorker>());
      expect(web.pairingDeflate, isNull);
      final sealed = await worker.sealData(0, text(10000), compress: true);
      expect(sealed.sent, 10000);
    });
  });
}

/// Compression that fails with an error that is not the protocol's.
class _FailingDeflate implements PairingDeflate {
  const new();

  @override
  Uint8List compress(Uint8List bytes) => throw StateError('broken');

  @override
  Uint8List inflate(Uint8List bytes, {required int limit}) => bytes;
}

/// Compression that stops the worker's isolate.
class _DyingDeflate implements PairingDeflate {
  const new();

  @override
  Uint8List compress(Uint8List bytes) => Isolate.exit();

  @override
  Uint8List inflate(Uint8List bytes, {required int limit}) => bytes;
}
