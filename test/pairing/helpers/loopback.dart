import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:mozhi/pairing/protocol/byte_reader.dart';
import 'package:mozhi/pairing/protocol/pairing_address.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_handshake.dart';

/// Pairing on one machine: loopback addresses allowed.
const loopbackPolicy = PairingAddressPolicy(allowLoopback: true);

/// Two connected loopback sockets.
Future<(Socket, Socket)> socketPair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = server.first;
  final client = await Socket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
  );
  final other = await accepted;
  await server.close();
  return (client, other);
}

/// Keys for both ends of a channel without a handshake.
(PairingKeys, PairingKeys) keyPair({String sas = '123456'}) {
  final a = SecretKeyData(List.generate(32, (i) => i));
  final b = SecretKeyData(List.generate(32, (i) => 100 + i));
  return (
    PairingKeys(outgoing: a, incoming: b, sas: sas),
    PairingKeys(outgoing: b, incoming: a, sas: sas),
  );
}

/// Two channels over a loopback socket pair.
Future<(PairingChannel, PairingChannel)> channelPair() async {
  final (a, b) = await socketPair();
  final (keysA, keysB) = keyPair();
  return (
    PairingChannel(input: PairingByteReader(a), socket: a, keys: keysA),
    PairingChannel(input: PairingByteReader(b), socket: b, keys: keysB),
  );
}

/// A sealed frame as [PairingChannel] writes it: [plain] (type byte and
/// payload) encrypted under [key] as frame [number].
Uint8List sealFrame(List<int> plain, SecretKeyData key, int number) {
  final nonce = Uint8List(12);
  ByteData.sublistView(nonce).setUint32(8, number);
  final box = DartAesGcm.with256bits().encryptSync(
    plain,
    secretKeyData: key,
    nonce: nonce,
  );
  final length = box.cipherText.length + 16;
  final frame = Uint8List(4 + length);
  ByteData.sublistView(frame).setUint32(0, length);
  frame
    ..setRange(4, 4 + box.cipherText.length, box.cipherText)
    ..setRange(4 + box.cipherText.length, 4 + length, box.mac.bytes);
  return frame;
}

/// What a [PairingRelay] does with the frames of one direction: the
/// frames to pass on instead of [frame] (number [index] in that
/// direction, its length header included).
typedef FrameFilter = List<Uint8List> Function(int index, Uint8List frame);

/// A machine in the middle on loopback: passes the handshake through
/// unchanged and each later frame through a [FrameFilter] (sender to
/// receiver: [upstream]; back: [downstream]).
class PairingRelay {
  new _(this._server, this.target, this.upstream, this.downstream) {
    _server.listen(_onClient);
  }

  static Future<PairingRelay> start(
    int targetPort, {
    FrameFilter? upstream,
    FrameFilter? downstream,
  }) async => PairingRelay._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    targetPort,
    upstream,
    downstream,
  );

  final ServerSocket _server;
  final int target;
  final FrameFilter? upstream;
  final FrameFilter? downstream;
  final List<Socket> _sockets = [];

  int get port => _server.port;

  Future<void> close() async {
    await _server.close();
    for (final socket in _sockets) {
      socket.destroy();
    }
  }

  Future<void> _onClient(Socket client) async {
    final server = await Socket.connect(InternetAddress.loopbackIPv4, target);
    _sockets.addAll([client, server]);
    // Sender to receiver: commitment (36 bytes) and key (32 bytes).
    unawaited(_pipe(client, server, const [36, 32], upstream));
    // Receiver to sender: key (36 bytes).
    unawaited(_pipe(server, client, const [36], downstream));
  }

  static Future<void> _pipe(
    Socket from,
    Socket to,
    List<int> handshake,
    FrameFilter? filter,
  ) async {
    final input = PairingByteReader(from);
    const wait = Duration(seconds: 30);
    try {
      for (final length in handshake) {
        to.add(await input.read(length, timeout: wait));
      }
      for (var index = 0; ; index++) {
        final header = await input.read(4, timeout: wait);
        final length = ByteData.sublistView(header).getUint32(0);
        final body = await input.read(length, timeout: wait);
        final frame = Uint8List.fromList([...header, ...body]);
        (filter?.call(index, frame) ?? [frame]).forEach(to.add);
      }
    } on Object {
      to.destroy();
      from.destroy();
    }
  }
}
