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
    int maxFailures = 30,
    int maxPending = 4,
    int maxPendingPerAddress = 2,
    int maxHandshakesPerMinute = 30,
    int maxAddressHandshakesPerMinute = 6,
    Duration minSetupTime = const Duration(seconds: 2),
    Duration handshakeTimeout = const Duration(seconds: 5),
    PairingAddressPolicy policy = loopbackPolicy,
    DateTime Function() now = DateTime.now,
  }) async {
    final listener = await PairingListener.bind(
      loopback,
      validity: validity,
      maxAttempts: maxAttempts,
      maxFailures: maxFailures,
      maxPending: maxPending,
      maxPendingPerAddress: maxPendingPerAddress,
      maxHandshakesPerMinute: maxHandshakesPerMinute,
      maxAddressHandshakesPerMinute: maxAddressHandshakesPerMinute,
      minSetupTime: minSetupTime,
      handshakeTimeout: handshakeTimeout,
      policy: policy,
      now: now,
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

  PairingCode wrongSecret(PairingCode code) => PairingCode(
    address: code.address,
    port: code.port,
    secret: List.filled(8, 7),
  );

  /// A raw connection from [source] (another loopback address), closed
  /// with the test.
  Future<Socket> rawSocket(int port, {String source = '127.0.0.1'}) async {
    final socket = await Socket.connect(
      loopback,
      port,
      sourceAddress: InternetAddress(source),
    );
    addTearDown(socket.destroy);
    return socket;
  }

  /// [connectPairing] from [source], with the sender's writes after the
  /// first one held back by [keyDelay] and its hello by [helloDelay].
  Future<PairingChannel> connectFrom(
    PairingCode code, {
    String source = '127.0.0.1',
    Duration keyDelay = Duration.zero,
    Duration helloDelay = Duration.zero,
  }) async {
    final socket = await rawSocket(code.port, source: source);
    final input = PairingByteReader(socket);
    var writes = 0;
    final keys = await PairingHandshake.initiate(
      input: input,
      output: (bytes) {
        if (writes++ == 0) {
          socket.add(bytes);
        } else {
          Timer(keyDelay, () => socket.add(bytes));
        }
      },
      code: code,
      timeout: timeout,
    );
    await Future<void>.delayed(keyDelay + helloDelay);
    final channel = PairingChannel(input: input, socket: socket, keys: keys);
    channels.add(channel);
    await channel.send('hello', const {'v': pairingProtocolVersion});
    checkHello(await channel.receiveMessage(timeout: timeout));
    return channel;
  }

  /// Completes when the other end closes [socket].
  Future<void> closedByPeer(Socket socket) {
    final closed = Completer<void>();
    socket.listen(
      null,
      onDone: closed.complete,
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
      cancelOnError: true,
    );
    return closed.future.timeout(timeout);
  }

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
        connectPairing(
          listener.code,
          policy: loopbackPolicy,
          retryDelays: const [],
        ),
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
      final wrong = wrongSecret(listener.code);
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

    test('wrong codes from one address shut out that address', () async {
      final listener = await listen(maxAttempts: 2);
      final wrong = wrongSecret(listener.code);
      for (var i = 0; i < 2; i++) {
        await expectLater(
          connectPairing(wrong, policy: loopbackPolicy),
          throwsA(isA<PairingClosedException>()),
        );
      }
      // Even with the right code, that address is closed at once…
      await expectLater(
        connectPairing(
          listener.code,
          policy: loopbackPolicy,
          retryDelays: const [],
        ),
        throwsA(_refused),
      );
      // …but the code still works for another phone.
      final sender = await connectFrom(listener.code, source: '127.0.0.2');
      final receiver = await listener.connection;
      channels.add(receiver);
      expect(receiver.sas, sender.sas);
      expect(receiver.remoteAddress.address, '127.0.0.2');
    });

    test('too many wrong codes in all burn the code', () async {
      final listener = await listen(maxAttempts: 10, maxFailures: 2);
      final wrong = wrongSecret(listener.code);
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
        connectPairing(
          listener.code,
          policy: loopbackPolicy,
          retryDelays: const [],
        ),
        throwsA(_refused),
      );
    });

    test('garbage and timeouts do not count as wrong codes', () async {
      final listener = await listen(
        maxAttempts: 1,
        maxFailures: 1,
        handshakeTimeout: const Duration(milliseconds: 200),
      );
      // Not the magic, a key that does not match its commitment, silence.
      final garbage = await rawSocket(listener.code.port);
      garbage.add(List.filled(36, 65));
      await closedByPeer(garbage);
      final silent = await rawSocket(listener.code.port);
      await closedByPeer(silent);
      final cheat = await rawSocket(listener.code.port);
      cheat
        ..add([...PairingHandshake.magic, ...List.filled(32, 1)])
        ..add(List.filled(32, 2));
      await closedByPeer(cheat);
      final sender = await connect(listener.code);
      channels.add(await listener.connection);
      expect(sender.sas, hasLength(6));
    });

    test('the code expires', () async {
      final listener = await listen(validity: const Duration(milliseconds: 50));
      await expectLater(
        listener.connection,
        throwsA(isA<PairingExpiredException>()),
      );
      await expectLater(
        connectPairing(
          listener.code,
          policy: loopbackPolicy,
          retryDelays: const [],
        ),
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

    test('a stalled connection does not keep the real phone out', () async {
      final listener = await listen();
      final silent = await rawSocket(listener.code.port);
      final silentClosed = closedByPeer(silent);
      // The real phone gets through while the other one stalls…
      final sender = await connect(listener.code);
      channels.add(await listener.connection);
      expect(sender.sas, hasLength(6));
      // …which is then closed: one connection per code.
      await silentClosed;
    });

    test('a connection that stalls is closed after the timeout', () async {
      final listener = await listen(
        handshakeTimeout: const Duration(milliseconds: 100),
      );
      final silent = await rawSocket(listener.code.port);
      await closedByPeer(silent);
      final sender = await connect(listener.code);
      channels.add(await listener.connection);
      expect(sender.sas, hasLength(6));
    });

    test('the key agreement and hello have one deadline', () async {
      final listener = await listen(
        handshakeTimeout: const Duration(milliseconds: 400),
      );
      var connected = false;
      unawaited(listener.connection.then((_) => connected = true));
      // Each step comes in time, all of them together do not.
      await expectLater(
        connectFrom(
          listener.code,
          keyDelay: const Duration(milliseconds: 250),
          helloDelay: const Duration(milliseconds: 300),
        ),
        throwsA(isA<PairingClosedException>()),
      );
      expect(connected, isFalse);
      final sender = await connect(listener.code);
      final receiver = await listener.connection;
      channels.add(receiver);
      expect(receiver.sas, sender.sas);
    });

    test('the sender gives up on a receiver that stalls', () async {
      final server = await ServerSocket.bind(loopback, 0);
      final accepted = <Socket>[];
      addTearDown(() async {
        for (final socket in accepted) {
          socket.destroy();
        }
        await server.close();
      });
      // Answers the commitment, then never the hello.
      server.listen((socket) async {
        accepted.add(socket);
        final input = PairingByteReader(socket);
        try {
          await PairingHandshake.respond(
            input: input,
            output: socket.add,
            code: PairingCode(
              address: loopback.rawAddress,
              port: server.port,
              secret: List.filled(8, 1),
            ),
            timeout: timeout,
          );
        } on Object {
          // The sender hung up.
        }
      });
      final code = PairingCode(
        address: loopback.rawAddress,
        port: server.port,
        secret: List.filled(8, 1),
      );
      await expectLater(
        connectPairing(
          code,
          policy: loopbackPolicy,
          handshakeTimeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<PairingTimeoutException>()),
      );
    });

    test('too many connections close the oldest first', () async {
      final listener = await listen(maxPending: 2);
      final first = await rawSocket(listener.code.port);
      final firstClosed = closedByPeer(first);
      final second = await rawSocket(listener.code.port);
      final secondClosed = closedByPeer(second);
      final sender = await connect(listener.code);
      channels.add(await listener.connection);
      expect(sender.sas, hasLength(6));
      await firstClosed;
      await secondClosed;
    });

    test('a device opening many connections loses its own first', () async {
      final listener = await listen(maxPending: 2, minSetupTime: Duration.zero);
      var otherClosed = false;
      final other = await rawSocket(listener.code.port, source: '127.0.0.2');
      unawaited(closedByPeer(other).then((_) => otherClosed = true));
      final first = await rawSocket(listener.code.port);
      final firstClosed = closedByPeer(first);
      await rawSocket(listener.code.port);
      await firstClosed;
      expect(otherClosed, isFalse);
    });

    test('a device loses its own connections beyond its share', () async {
      final listener = await listen(maxPendingPerAddress: 1);
      var otherClosed = false;
      final other = await rawSocket(listener.code.port, source: '127.0.0.2');
      unawaited(closedByPeer(other).then((_) => otherClosed = true));
      final first = await rawSocket(listener.code.port);
      final firstClosed = closedByPeer(first);
      await rawSocket(listener.code.port);
      await firstClosed;
      expect(otherClosed, isFalse);
    });

    group('a flood from many addresses', () {
      /// Stalling connections from 127.0.0.<first>, <first + 1>…
      Future<List<Socket>> flood(int port, int count, {int first = 10}) =>
          Future.wait([
            for (var i = 0; i < count; i++)
              rawSocket(port, source: '127.0.0.${first + i}'),
          ]);

      /// Whether each of [sockets] is closed by the listener soon.
      Future<List<bool>> closedSoon(List<Socket> sockets) => Future.wait([
        for (final socket in sockets)
          closedByPeer(socket).then((_) => true, onError: (Object _) => false),
      ]);

      test('cannot push out a phone setting up', () async {
        final listener = await listen(maxPending: 2);
        // The real phone takes its time over the key agreement…
        final sender = connectFrom(
          listener.code,
          keyDelay: const Duration(milliseconds: 300),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // …while a flood takes the other place, and then is refused.
        await rawSocket(listener.code.port, source: '127.0.0.9');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final sockets = await flood(listener.code.port, 12);
        expect(await closedSoon(sockets), everyElement(isTrue));
        final channel = await sender;
        channels.add(await listener.connection);
        expect(channel.sas, hasLength(6));
      });

      test('holds the phone back only while it lasts', () async {
        var time = DateTime(2026);
        final listener = await listen(now: () => time);
        // Every place is taken by connections that stall…
        final stalled = await flood(listener.code.port, 4);
        final refused = await flood(listener.code.port, 8, first: 20);
        expect(await closedSoon(refused), everyElement(isTrue));
        // …and young ones are not pushed out, not even for the real phone.
        await expectLater(
          connectPairing(
            listener.code,
            policy: loopbackPolicy,
            retryDelays: const [],
          ),
          throwsA(isA<PairingClosedException>()),
        );
        // Once they had their time, the real phone gets through.
        time = time.add(const Duration(seconds: 3));
        final sender = await connect(listener.code);
        channels.add(await listener.connection);
        expect(sender.sas, hasLength(6));
        expect(await closedSoon(stalled), everyElement(isTrue));
      });

      test('starts a limited number of handshakes a minute', () async {
        var time = DateTime(2026);
        final listener = await listen(
          maxHandshakesPerMinute: 6,
          maxPending: 8,
          now: () => time,
        );
        final taken = await flood(listener.code.port, 6);
        // Places are free, but the minute's handshakes are used up.
        final refused = await flood(listener.code.port, 10, first: 30);
        expect(await closedSoon(refused), everyElement(isTrue));
        await expectLater(
          connectPairing(
            listener.code,
            policy: loopbackPolicy,
            retryDelays: const [],
          ),
          throwsA(isA<PairingClosedException>()),
        );
        for (final socket in taken) {
          socket.destroy();
        }
        // A minute after the flood, the real phone gets through.
        time = time.add(const Duration(seconds: 61));
        final sender = await connect(listener.code);
        channels.add(await listener.connection);
        expect(sender.sas, hasLength(6));
      });

      test('and from one address count per address too', () async {
        final listener = await listen(maxAddressHandshakesPerMinute: 2);
        final first = await rawSocket(listener.code.port, source: '127.0.0.2');
        final second = await rawSocket(listener.code.port, source: '127.0.0.2');
        final third = await rawSocket(listener.code.port, source: '127.0.0.2');
        await closedByPeer(third);
        final sender = await connect(listener.code);
        channels.add(await listener.connection);
        expect(sender.sas, hasLength(6));
        await closedByPeer(first);
        await closedByPeer(second);
      });
    });

    test('the sender tries again when it was turned away', () async {
      var calls = 0;
      final start = DateTime(2026);
      // Bind, the stalling connection and the first try see the same
      // minute; the second try a later one.
      final listener = await listen(
        maxHandshakesPerMinute: 1,
        now: () => calls++ < 3 ? start : start.add(const Duration(minutes: 2)),
      );
      await rawSocket(listener.code.port, source: '127.0.0.2');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sender = await connectPairing(
        listener.code,
        policy: loopbackPolicy,
        retryDelays: const [Duration(milliseconds: 100)],
      );
      channels
        ..add(sender)
        ..add(await listener.connection);
      expect(calls, 4);
    });

    test('the sender does not try a wrong code again', () async {
      final listener = await listen(maxAttempts: 2);
      await expectLater(
        connectPairing(
          wrongSecret(listener.code),
          policy: loopbackPolicy,
          retryDelays: const [Duration.zero, Duration.zero],
        ),
        throwsA(isA<PairingClosedException>()),
      );
      // One wrong code counted, so the address may still connect.
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
