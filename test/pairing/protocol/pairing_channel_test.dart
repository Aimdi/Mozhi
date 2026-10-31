import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/pairing/protocol/byte_reader.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_codec.dart';
import 'package:mozhi/pairing/protocol/pairing_frame_worker.dart';

import '../helpers/fake_packs.dart';
import '../helpers/loopback.dart';

void main() {
  const timeout = Duration(seconds: 5);

  group('PairingChannel', () {
    late PairingChannel a;
    late PairingChannel b;

    setUp(() async {
      (a, b) = await channelPair();
    });

    tearDown(() {
      a.destroy();
      b.destroy();
    });

    test('carries messages and data both ways, in order', () async {
      expect(a.sas, '123456');
      expect(a.remoteAddress, InternetAddress.loopbackIPv4);
      await a.send('offer', {'items': <Object?>[]});
      await a.sendData(Uint8List.fromList([1, 2, 3]));
      await a.sendData(Uint8List(PairingChannel.maxPayload));
      await b.send('accept');

      final offer = await b.receive(timeout: timeout);
      expect(
        offer,
        isA<PairingMessage>().having((m) => m.type, 'type', 'offer'),
      );
      expect((offer as PairingMessage).fields, {
        'items': <Object?>[],
        't': 'offer',
      });
      expect(offer.toString(), 'PairingMessage(offer)');
      final data = await b.receive(timeout: timeout);
      expect((data as PairingData).bytes, [1, 2, 3]);
      expect(data.toString(), 'PairingData(3)');
      final big = await b.receive(timeout: timeout);
      expect((big as PairingData).bytes, hasLength(PairingChannel.maxPayload));
      final accept = await a.receiveMessage(
        timeout: timeout,
        expected: {'accept'},
      );
      expect(accept.type, 'accept');
    });

    test('refuses to send oversize messages and data', () {
      expect(
        () => a.send('x', {'pad': 'x' * PairingChannel.maxPayload}),
        throwsArgumentError,
      );
      expect(
        () => a.sendData(Uint8List(PairingChannel.maxPayload + 1)),
        throwsArgumentError,
      );
    });

    test('reports a cancel, unexpected messages and data', () async {
      await a.send('cancel', {'reason': 'user'});
      await expectLater(
        b.receiveMessage(timeout: timeout),
        throwsA(isA<PairingCancelledException>()),
      );
      // The channel is finished after a failure.
      await expectLater(
        b.receive(timeout: timeout),
        throwsA(isA<PairingCancelledException>()),
      );
      expect(() => b.send('hello'), throwsA(isA<PairingCancelledException>()));
    });

    test('refuses a message it did not expect', () async {
      await a.send('done');
      await expectLater(
        b.receiveMessage(timeout: timeout, expected: {'accept'}),
        throwsA(isA<PairingProtocolException>()),
      );
    });

    test('refuses data where a message is due', () async {
      await a.sendData([1]);
      await expectLater(
        b.receiveMessage(timeout: timeout),
        throwsA(isA<PairingProtocolException>()),
      );
    });

    test('times out and closes', () async {
      await expectLater(
        b.receive(timeout: const Duration(milliseconds: 20)),
        throwsA(isA<PairingTimeoutException>()),
      );
      await expectLater(
        b.receive(timeout: timeout),
        throwsA(isA<PairingTimeoutException>()),
      );
    });

    test('reports a closed connection', () async {
      await a.close();
      await expectLater(
        b.receive(timeout: timeout),
        throwsA(isA<PairingClosedException>()),
      );
    });

    test('fails sends on a destroyed connection', () async {
      a.destroy();
      expect(() => a.send('hello'), throwsA(isA<PairingClosedException>()));
      await a.close();
    });

    test('a write that fails fails the channel', () async {
      b.destroy();
      // Writes fail once the other end has gone (the first ones may still
      // be buffered by the system).
      Object? failure;
      for (var i = 0; i < 200 && failure == null; i++) {
        try {
          await a.sendData(Uint8List(PairingChannel.maxPayload));
        } on PairingClosedException catch (error) {
          failure = error;
        }
      }
      expect(failure, isA<PairingClosedException>());
      expect(() => a.send('x'), throwsA(isA<PairingClosedException>()));
    });

    test('cancel tells the other phone and closes', () async {
      await a.cancel('declined');
      final frame = await b.receive(timeout: timeout);
      expect((frame as PairingMessage).fields['reason'], 'declined');
      // A second cancel sends nothing.
      await a.cancel();
    });
  });

  group('PairingChannel refuses frames', () {
    late Socket raw;
    late PairingChannel channel;
    late Uint8List Function(List<int> plain, int number) seal;

    setUp(() async {
      final (socket, other) = await socketPair();
      raw = socket;
      final (keys, peerKeys) = keyPair();
      channel = PairingChannel(
        input: PairingByteReader(other),
        socket: other,
        keys: peerKeys,
      );
      seal = (plain, number) => sealFrame(plain, keys.outgoing, number);
    });

    tearDown(() {
      raw.destroy();
      channel.destroy();
    });

    Future<Object?> failureOf(List<int> bytes) async {
      raw.add(bytes);
      try {
        await channel.receive(timeout: timeout);
        return null;
      } on Object catch (error) {
        return error;
      }
    }

    List<int> message(Object json) => [1, ...utf8.encode(jsonEncode(json))];

    test('reads a well-formed frame', () async {
      raw.add(seal(message({'t': 'hello', 'v': 1}), 0));
      final frame = await channel.receive(timeout: timeout);
      expect((frame as PairingMessage).fields['v'], 1);
    });

    test('that were changed', () async {
      final frame = seal(message({'t': 'hello'}), 0);
      frame[10] ^= 1;
      expect(await failureOf(frame), isA<PairingAuthenticationException>());
    });

    test('that were replayed', () async {
      final frame = seal(message({'t': 'hello'}), 0);
      raw.add(frame);
      await channel.receive(timeout: timeout);
      expect(await failureOf(frame), isA<PairingAuthenticationException>());
    });

    test('out of order', () async {
      final second = seal(message({'t': 'b'}), 1);
      expect(await failureOf(second), isA<PairingAuthenticationException>());
    });

    test('that are too long or too short', () async {
      final header = Uint8List(4);
      ByteData.sublistView(header)
          .setUint32(0, PairingChannel.maxPayload + 1 + 16 + 1);
      expect(await failureOf(header), isA<PairingProtocolException>());
    });

    test('that are too short', () async {
      expect(
        await failureOf([0, 0, 0, 16, ...List.filled(16, 0)]),
        isA<PairingProtocolException>(),
      );
    });

    test('of an unknown type', () async {
      expect(await failureOf(seal([9, 1], 0)), isA<PairingProtocolException>());
    });

    test('with malformed messages', () async {
      expect(
        await failureOf(seal([1, 0xff, 0xfe], 0)),
        isA<PairingProtocolException>(),
      );
    });

    test('with messages that are not objects', () async {
      expect(
        await failureOf(seal(message([1]), 0)),
        isA<PairingProtocolException>(),
      );
    });

    test('with messages without a type', () async {
      expect(
        await failureOf(seal(message({'v': 1}), 0)),
        isA<PairingProtocolException>(),
      );
    });

    test('a large frame of an earlier version, through the worker', () async {
      final data = List.generate(100000, (i) => i % 251);
      raw.add(seal([2, ...data], 0));
      final frame = await channel.receive(timeout: timeout);
      expect((frame as PairingData).bytes, data);
    });

    test('with data that does not inflate', () async {
      expect(
        await failureOf(seal([3, 0xff, 0xff, 0xff], 0)),
        isA<PairingProtocolException>(),
      );
    });
  });

  group('PairingChannel features', () {
    /// [length] bytes of text, which compress well.
    Uint8List text(int length) => Uint8List.fromList([
      for (var i = 0; i < length; i++) 'a b c d e f g '.codeUnitAt(i % 14),
    ]);

    test(
      'hello says what this phone takes and keeps what the other says',
      () async {
        final (a, b) = await channelPair();
        addTearDown(() {
          a.destroy();
          b.destroy();
        });
        expect(PairingChannel.features, [PairingFeature.deflate]);
        expect(b.peerInflates, isFalse);
        await a.sendHello();
        final hello = await b.receiveMessage(timeout: timeout);
        expect(hello.fields['v'], pairingProtocolVersion);
        expect(hello.fields['features'], [PairingFeature.deflate]);
        b.acceptHello(hello);
        expect(b.peerFeatures, {PairingFeature.deflate});
        expect(b.peerInflates, isTrue);
      },
    );

    test('a hello of an earlier version lists nothing', () {
      expect(helloFeatures(helloOf()), isEmpty);
      expect(
        helloFeatures(
          const PairingMessage('hello', {'v': 1, 'features': 'deflate'}),
        ),
        isEmpty,
      );
      expect(
        helloFeatures(
          const PairingMessage('hello', {
            'v': 1,
            'features': [1, 'deflate', null, 'later'],
          }),
        ),
        {'deflate', 'later'},
      );
    });

    test('file data goes compressed to a phone that inflates', () async {
      final (a, b) = await recordingPair();
      addTearDown(() {
        a.destroy();
        b.destroy();
      });
      final data = text(64 * 1024);
      final sent = await a.sendFileData(data);
      expect(sent, lessThan(data.length ~/ 10));
      // Unless asked not to.
      expect(await a.sendFileData(data, compress: false), data.length);
      for (var i = 0; i < 2; i++) {
        final frame = await b.receive(timeout: timeout);
        expect((frame as PairingData).bytes, data);
      }
    });

    test('a phone of an earlier version gets file data as it is', () async {
      final (socket, other) = await socketPair();
      final (keys, peerKeys) = keyPair();
      final channel = PairingChannel(
        input: PairingByteReader(socket),
        socket: socket,
        keys: keys,
      )..acceptHello(helloOf());
      addTearDown(() {
        channel.destroy();
        other.destroy();
      });
      expect(channel.peerInflates, isFalse);
      final data = text(64 * 1024);
      expect(await channel.sendFileData(data), data.length);
      // What the earlier version reads: frames of types 1 and 2 only.
      final input = PairingByteReader(other);
      final header = await input.read(4, timeout: timeout);
      final sealed = await input.read(
        ByteData.sublistView(header).getUint32(0),
        timeout: timeout,
      );
      final earlier = PairingFrameCodec(
        outgoing: peerKeys.outgoing.bytes,
        incoming: peerKeys.incoming.bytes,
      );
      final (type, payload) = earlier.open(0, sealed);
      expect(type, PairingFrameType.data);
      expect(payload, data);
      await input.cancel();
    });

    test('hashes the file data it receives, small frames too', () async {
      final (a, b) = await recordingPair();
      addTearDown(() {
        a.destroy();
        b.destroy();
      });
      final chunks = [
        text(64 * 1024),
        text(100),
        Uint8List.fromList([1]),
      ];
      await b.startHash(sha256: true, sha1: true);
      for (final chunk in chunks) {
        await a.sendFileData(chunk);
        await a.send('note');
      }
      for (final chunk in chunks) {
        expect(
          ((await b.receive(timeout: timeout)) as PairingData).bytes,
          chunk,
        );
        expect(await b.receive(timeout: timeout), isA<PairingMessage>());
      }
      final all = [for (final chunk in chunks) ...chunk];
      expect(await b.finishHash(), (sha256: sha256Of(all), sha1: sha1Of(all)));
    });

    test('refuses file data longer than a frame', () async {
      final (a, b) = await recordingPair();
      addTearDown(() {
        a.destroy();
        b.destroy();
      });
      expect(
        () => a.sendFileData(Uint8List(PairingChannel.maxPayload + 1)),
        throwsArgumentError,
      );
    });

    test('a worker that fails breaks the channel', () async {
      final (socket, other) = await socketPair();
      final (keys, _) = keyPair();
      final closed = InlinePairingFrameWorker(
        PairingFrameCodec(
          outgoing: keys.outgoing.bytes,
          incoming: keys.incoming.bytes,
        ),
      )..close();
      final channel = PairingChannel(
        input: PairingByteReader(socket),
        socket: socket,
        keys: keys,
        worker: closed,
      );
      addTearDown(() {
        channel.destroy();
        other.destroy();
      });
      await expectLater(
        channel.startHash(sha256: true, sha1: false),
        throwsA(isA<PairingClosedException>()),
      );
      expect(() => channel.send('x'), throwsA(isA<PairingClosedException>()));
    });

    test("an error that is not the protocol's breaks it too", () async {
      final (socket, other) = await socketPair();
      final (keys, peerKeys) = keyPair();
      final channel = PairingChannel(
        input: PairingByteReader(socket),
        socket: socket,
        keys: keys,
        worker: _BrokenWorker(),
      );
      addTearDown(() {
        channel.destroy();
        other.destroy();
      });
      other.add(sealFrame([2, ...Uint8List(10000)], peerKeys.outgoing, 0));
      await expectLater(
        channel.receive(timeout: timeout),
        throwsA(isA<StateError>()),
      );
      expect(
        () => channel.send('x'),
        throwsA(
          isA<PairingClosedException>().having(
            (e) => '$e',
            'message',
            contains('worker broke'),
          ),
        ),
      );
    });

    test('a closed channel does not hash', () async {
      final (a, b) = await recordingPair();
      a.destroy();
      b.destroy();
      expect(
        () => b.startHash(sha256: true, sha1: false),
        throwsA(isA<PairingClosedException>()),
      );
      expect(b.finishHash, throwsA(isA<PairingClosedException>()));
    });
  });
}

/// A worker whose every call fails with an error of its own.
class _BrokenWorker implements PairingFrameWorker {
  @override
  Future<Uint8List> seal(int number, int type, Uint8List payload) =>
      throw StateError('worker broke');

  @override
  Future<({Uint8List frame, int sent})> sealData(
    int number,
    Uint8List bytes, {
    required bool compress,
  }) => throw StateError('worker broke');

  @override
  Future<(int, Uint8List)> open(int number, Uint8List sealed) async =>
      throw StateError('worker broke');

  @override
  Future<void> startHash({required bool sha256, required bool sha1}) =>
      throw StateError('worker broke');

  @override
  Future<PairingDigests> finishHash() => throw StateError('worker broke');

  @override
  void close() {}
}
