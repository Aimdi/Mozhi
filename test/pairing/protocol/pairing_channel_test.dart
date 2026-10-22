import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/pairing/protocol/byte_reader.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';

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
  });
}
