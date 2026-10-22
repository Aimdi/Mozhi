import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/pairing/protocol/byte_reader.dart';
import 'package:mozhi/pairing/protocol/pairing_address.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';
import 'package:mozhi/pairing/protocol/pairing_connection.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';
import 'package:mozhi/pairing/protocol/pairing_handshake.dart';

import '../helpers/loopback.dart';

void main() {
  const timeout = Duration(seconds: 5);
  final loopback = InternetAddress.loopbackIPv4;
  final listeners = <PairingListener>[];
  final channels = <PairingChannel>[];

  Future<PairingListener> listen({
    Duration validity = const Duration(minutes: 1),
    int maxAttempts = 3,
    Duration handshakeTimeout = const Duration(seconds: 5),
    PairingAddressPolicy policy = loopbackPolicy,
  }) async {
    final listener = await PairingListener.bind(
      loopback,
      validity: validity,
      maxAttempts: maxAttempts,
      handshakeTimeout: handshakeTimeout,
      policy: policy,
    );
    listeners.add(listener);
    return listener;
  }

  Future<PairingChannel> connect(PairingCode code) async {
    final channel = await connectPairing(code, policy: loopbackPolicy);
    channels.add(channel);
    return channel;
  }

  PairingCode withPort(PairingCode code, int port) =>
      PairingCode(address: code.address, port: port, secret: code.secret);

  tearDown(() async {
    for (final channel in channels) {
      channel.destroy();
    }
    channels.clear();
    for (final listener in listeners) {
      await listener.close();
    }
    listeners.clear();
  });

  group('pairing connection', () {
    test('both phones get the same short authentication string', () async {
      final listener = await listen();
      expect(listener.code.host, '127.0.0.1');
      expect(
        listener.expiresAt.isAfter(
          DateTime.now().add(const Duration(seconds: 50)),
        ),
        isTrue,
      );
      final sender = await connect(listener.code);
      final receiver = await listener.connection;
      channels.add(receiver);
      expect(sender.sas, matches(RegExp(r'^\d{6}$')));
      expect(receiver.sas, sender.sas);

      await sender.send('offer', {'n': 1});
      final offer = await receiver.receiveMessage(timeout: timeout);
      expect(offer.fields['n'], 1);
      await receiver.sendData([4, 2]);
      expect(((await sender.receive(timeout: timeout)) as PairingData).bytes, [
        4,
        2,
      ]);
    });

    test('takes one phone only', () async {
      final listener = await listen();
      await connect(listener.code);
      channels.add(await listener.connection);
      await expectLater(
        connectPairing(listener.code, policy: loopbackPolicy),
        throwsA(_refused),
      );
    });

    test('every connection has its own keys', () async {
      final first = await listen();
      final second = await listen();
      final a = await connect(first.code);
      final b = await connect(second.code);
      channels.addAll([await first.connection, await second.connection]);
      // Six digits can collide; the keys behind them do not.
      expect(first.code.secret, isNot(second.code.secret));
      expect([a.sas, b.sas], hasLength(2));
    });

    test('a phone without the secret cannot connect', () async {
      final listener = await listen(maxAttempts: 2);
      final wrong = PairingCode(
        address: listener.code.address,
        port: listener.code.port,
        secret: List.filled(8, 7),
      );
      await expectLater(
        connectPairing(wrong, policy: loopbackPolicy),
        throwsA(isA<PairingClosedException>()),
      );
      // The right phone can still connect after one wrong attempt.
      final sender = await connect(listener.code);
      final receiver = await listener.connection;
      channels.add(receiver);
      expect(receiver.sas, sender.sas);
    });

    test('too many wrong attempts burn the code', () async {
      final listener = await listen(maxAttempts: 2);
      final wrong = PairingCode(
        address: listener.code.address,
        port: listener.code.port,
        secret: List.filled(8, 7),
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          connectPairing(wrong, policy: loopbackPolicy),
          throwsA(isA<PairingClosedException>()),
        );
      }
      await expectLater(
        listener.connection,
        throwsA(
          isA<PairingExpiredException>().having(
            (e) => e.tooManyAttempts,
            'tooManyAttempts',
            isTrue,
          ),
        ),
      );
      await expectLater(
        connectPairing(listener.code, policy: loopbackPolicy),
        throwsA(_refused),
      );
    });

    test('the code expires', () async {
      final listener = await listen(validity: const Duration(milliseconds: 50));
      await expectLater(
        listener.connection,
        throwsA(isA<PairingExpiredException>()),
      );
      await expectLater(
        connectPairing(listener.code, policy: loopbackPolicy),
        throwsA(_refused),
      );
    });

    test('closing stops listening', () async {
      final listener = await listen();
      await listener.close();
      await expectLater(
        listener.connection,
        throwsA(isA<PairingClosedException>()),
      );
    });

    test('a silent connection times out and frees the listener', () async {
      final listener = await listen(
        handshakeTimeout: const Duration(milliseconds: 100),
      );
      final silent = await Socket.connect(loopback, listener.code.port);
      // Another phone is refused while the first one sets up.
      final second = await Socket.connect(loopback, listener.code.port);
      await expectLater(second.isEmpty, completion(isTrue));
      second.destroy();
      // The silent one is closed after the timeout.
      await expectLater(silent.isEmpty, completion(isTrue));
      silent.destroy();
      final sender = await connect(listener.code);
      channels.add(await listener.connection);
      expect(sender.sas, hasLength(6));
    });

    test('refuses phones outside the private network', () async {
      final listener = await listen(policy: const _OnlyFirstLoopback());
      final outsider = await Socket.connect(
        loopback,
        listener.code.port,
        sourceAddress: InternetAddress('127.0.0.2'),
      );
      await expectLater(outsider.isEmpty, completion(isTrue));
      outsider.destroy();
    });

    test('refuses to listen on or connect to other addresses', () async {
      await expectLater(
        PairingListener.bind(loopback),
        throwsA(isA<PairingAddressException>()),
      );
      final public = PairingCode(
        address: const [8, 8, 8, 8],
        port: 80,
        secret: List.filled(8, 0),
      );
      await expectLater(
        connectPairing(public),
        throwsA(isA<PairingAddressException>()),
      );
    });

    test('reports a receiver that does not answer', () async {
      final server = await ServerSocket.bind(loopback, 0);
      final port = server.port;
      await server.close();
      final code = PairingCode(
        address: loopback.rawAddress,
        port: port,
        secret: List.filled(8, 1),
      );
      await expectLater(
        connectPairing(code, policy: loopbackPolicy),
        throwsA(isA<PairingUnreachableException>()),
      );
    });

    test('refuses a peer that is not Mozhi', () async {
      final server = await ServerSocket.bind(loopback, 0);
      server.listen((socket) => socket.add(List.filled(36, 65)));
      final code = PairingCode(
        address: loopback.rawAddress,
        port: server.port,
        secret: List.filled(8, 1),
      );
      await expectLater(
        connectPairing(code, policy: loopbackPolicy),
        throwsA(isA<PairingProtocolException>()),
      );
      await server.close();
    });

    test('refuses another protocol version', () async {
      const hello = PairingMessage('hello', {'t': 'hello', 'v': 2});
      expect(() => checkHello(hello), throwsA(isA<PairingProtocolException>()));
    });
  });

  group('someone in the middle', () {
    Future<(PairingListener, PairingRelay)> relayed({
      FrameFilter? upstream,
      FrameFilter? downstream,
    }) async {
      final listener = await listen();
      final relay = await PairingRelay.start(
        listener.code.port,
        upstream: upstream,
        downstream: downstream,
      );
      addTearDown(relay.close);
      return (listener, relay);
    }

    test('passing frames on unchanged changes nothing', () async {
      final (listener, relay) = await relayed();
      final sender = await connect(withPort(listener.code, relay.port));
      final receiver = await listener.connection;
      channels.add(receiver);
      expect(receiver.sas, sender.sas);
      await sender.send('ping');
      expect((await receiver.receiveMessage(timeout: timeout)).type, 'ping');
    });

    test('cannot change a frame', () async {
      final (listener, relay) = await relayed(
        upstream: (index, frame) {
          if (index == 1) frame[frame.length - 1] ^= 0x80;
          return [frame];
        },
      );
      final sender = await connect(withPort(listener.code, relay.port));
      final receiver = await listener.connection;
      channels.add(receiver);
      await sender.send('offer');
      await expectLater(
        receiver.receive(timeout: timeout),
        throwsA(isA<PairingAuthenticationException>()),
      );
    });

    test('cannot replay a frame', () async {
      final (listener, relay) = await relayed(
        upstream: (index, frame) => index == 1 ? [frame, frame] : [frame],
      );
      final sender = await connect(withPort(listener.code, relay.port));
      final receiver = await listener.connection;
      channels.add(receiver);
      await sender.send('offer');
      expect((await receiver.receiveMessage(timeout: timeout)).type, 'offer');
      await expectLater(
        receiver.receive(timeout: timeout),
        throwsA(isA<PairingAuthenticationException>()),
      );
    });

    test('cannot reorder frames', () async {
      Uint8List? held;
      final (listener, relay) = await relayed(
        upstream: (index, frame) {
          if (index == 1) {
            held = frame;
            return const [];
          }
          if (index == 2) return [frame, held!];
          return [frame];
        },
      );
      final sender = await connect(withPort(listener.code, relay.port));
      final receiver = await listener.connection;
      channels.add(receiver);
      await sender.send('first');
      await sender.send('second');
      await expectLater(
        receiver.receive(timeout: timeout),
        throwsA(isA<PairingAuthenticationException>()),
      );
    });

    test('cannot drop a frame', () async {
      final (listener, relay) = await relayed(
        downstream: (index, frame) => index == 1 ? const [] : [frame],
      );
      final sender = await connect(withPort(listener.code, relay.port));
      final receiver = await listener.connection;
      channels.add(receiver);
      await receiver.send('first');
      await receiver.send('second');
      await expectLater(
        sender.receive(timeout: timeout),
        throwsA(isA<PairingAuthenticationException>()),
      );
    });

    test('cannot send an oversize frame', () async {
      final (listener, relay) = await relayed(
        upstream: (index, frame) {
          if (index == 1) {
            ByteData.sublistView(frame).setUint32(0, 0x7fffffff);
            return [Uint8List.sublistView(frame, 0, 4)];
          }
          return [frame];
        },
      );
      final sender = await connect(withPort(listener.code, relay.port));
      final receiver = await listener.connection;
      channels.add(receiver);
      await sender.send('offer');
      await expectLater(
        receiver.receive(timeout: timeout),
        throwsA(isA<PairingProtocolException>()),
      );
    });

    test('a broken connection is reported', () async {
      final (listener, relay) = await relayed();
      final sender = await connect(withPort(listener.code, relay.port));
      final receiver = await listener.connection;
      channels.add(receiver);
      await relay.close();
      await expectLater(
        receiver.receive(timeout: timeout),
        throwsA(isA<PairingClosedException>()),
      );
      await expectLater(
        sender.receive(timeout: timeout),
        throwsA(isA<PairingClosedException>()),
      );
    });
  });

  group('PairingHandshake', () {
    final code = PairingCode(
      address: const [10, 0, 0, 1],
      port: 1000,
      secret: List.filled(8, 3),
    );

    Future<Object?> respondTo(List<int> Function(List<int> own) script) async {
      final (raw, socket) = await socketPair();
      addTearDown(() {
        raw.destroy();
        socket.destroy();
      });
      final rawInput = PairingByteReader(raw);
      unawaited(() async {
        try {
          // The script sees the receiver's reply before sending more.
          final first = script(const []);
          raw.add(first);
          final reply = await rawInput.read(36, timeout: timeout);
          raw.add(script(reply.sublist(4)));
        } on Object {
          // The receiver hung up.
        }
      }());
      try {
        await PairingHandshake.respond(
          input: PairingByteReader(socket),
          output: socket.add,
          code: code,
          timeout: timeout,
        );
        return null;
      } on Object catch (error) {
        return error;
      }
    }

    test('refuses a key that does not match the commitment', () async {
      final keys = await X25519().newKeyPair();
      final own = (await keys.extractPublicKey()).bytes;
      final commitment = (await Sha256().hash(own)).bytes;
      final other =
          (await (await X25519().newKeyPair()).extractPublicKey()).bytes;
      final error = await respondTo(
        (reply) =>
            reply.isEmpty ? [...PairingHandshake.magic, ...commitment] : other,
      );
      expect(error, isA<PairingProtocolException>());
    });

    test('refuses a key that gives no shared secret', () async {
      final zero = List.filled(32, 0);
      final commitment = (await Sha256().hash(zero)).bytes;
      final error = await respondTo(
        (reply) =>
            reply.isEmpty ? [...PairingHandshake.magic, ...commitment] : zero,
      );
      expect(error, isA<PairingProtocolException>());
    });

    test('refuses a peer without the magic', () async {
      final error = await respondTo((reply) => List.filled(36, 1));
      expect(error, isA<PairingProtocolException>());
    });
  });
}

/// Nobody listens any more, or the listener hangs up at once (while it
/// is stopping).
final Matcher _refused = anyOf(
  isA<PairingUnreachableException>(),
  isA<PairingClosedException>(),
);

/// Allows binding to 127.0.0.1 and nothing else.
class _OnlyFirstLoopback implements PairingAddressPolicy {
  const new();

  @override
  bool get allowLoopback => true;

  @override
  bool allows(InternetAddress address) => address.address == '127.0.0.1';
}
