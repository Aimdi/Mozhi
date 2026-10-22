import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:mozhi/pairing/protocol/byte_reader.dart';
import 'package:mozhi/pairing/protocol/pairing_address.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';
import 'package:mozhi/pairing/protocol/pairing_handshake.dart';

/// Version of the messages inside the channel (`hello`'s `v`).
const pairingProtocolVersion = 1;

/// Time for the key agreement and the first messages of a connection.
const pairingHandshakeTimeout = Duration(seconds: 10);

/// The receiving phone's side ([bind]): listens on one of its private
/// addresses on a port the system picks and waits, for the code's
/// validity, for one phone that knows [code].
///
/// * Connections from addresses the [policy] does not allow (anything but
///   private IPv4 addresses) are closed at once, and so are connections
///   while another one is setting up or after one has succeeded.
/// * A connection is set up when the [PairingHandshake] and the `hello`
///   messages complete within [handshakeTimeout]; [connection] then
///   completes with its channel and the listener stops listening.
/// * A phone that does not know the secret fails the first encrypted
///   frame; after [maxAttempts] of those the code is burnt and
///   [connection] fails with [PairingExpiredException], as it does at
///   [expiresAt].
class PairingListener {
  new _(
    this._server,
    this.code,
    this.expiresAt, {
    required this.policy,
    required this.maxAttempts,
    required this.handshakeTimeout,
    required Duration validity,
  }) {
    unawaited(_result.future.then((_) {}, onError: (Object _) {}));
    _expiry = Timer(validity, () => _finish(const PairingExpiredException()));
    _subscription = _server.listen(
      _onSocket,
      onError: (Object error) => _finish(PairingClosedException('$error')),
      onDone: () => _finish(const PairingClosedException()),
    );
  }

  /// Starts listening on [address] (see [PairingListener]).
  static Future<PairingListener> bind(
    InternetAddress address, {
    Duration validity = const Duration(minutes: 5),
    int maxAttempts = 3,
    PairingAddressPolicy policy = const PairingAddressPolicy(),
    Duration handshakeTimeout = pairingHandshakeTimeout,
    Random? random,
    DateTime Function() now = DateTime.now,
  }) async {
    if (!policy.allows(address)) throw const PairingAddressException();
    final server = await ServerSocket.bind(address, 0);
    return PairingListener._(
      server,
      PairingCode.generate(
        address: address.rawAddress,
        port: server.port,
        random: random,
      ),
      now().add(validity),
      policy: policy,
      maxAttempts: maxAttempts,
      handshakeTimeout: handshakeTimeout,
      validity: validity,
    );
  }

  /// What the other phone needs to connect.
  final PairingCode code;

  /// When [code] stops working (unless a phone connected before).
  final DateTime expiresAt;

  final PairingAddressPolicy policy;
  final int maxAttempts;
  final Duration handshakeTimeout;

  final ServerSocket _server;
  late final StreamSubscription<Socket> _subscription;
  late final Timer _expiry;
  final Completer<PairingChannel> _result = Completer();
  bool _busy = false;
  int _failures = 0;

  /// The channel to the first phone that knew [code].
  Future<PairingChannel> get connection => _result.future;

  /// Stops listening; a [connection] that is still pending fails with
  /// [PairingClosedException].
  Future<void> close() => _finish(const PairingClosedException());

  void _onSocket(Socket socket) {
    if (_result.isCompleted || _busy || !policy.allows(socket.remoteAddress)) {
      socket.destroy();
      return;
    }
    _busy = true;
    unawaited(_accept(socket));
  }

  Future<void> _accept(Socket socket) async {
    final input = PairingByteReader(socket);
    try {
      final keys = await PairingHandshake.respond(
        input: input,
        output: socket.add,
        code: code,
        timeout: handshakeTimeout,
      );
      final channel = PairingChannel(input: input, socket: socket, keys: keys);
      checkHello(
        await channel.receiveMessage(
          timeout: handshakeTimeout,
          expected: const {'hello'},
        ),
      );
      await channel.send('hello', const {'v': pairingProtocolVersion});
      if (_result.isCompleted) {
        channel.destroy();
        return;
      }
      _result.complete(channel);
      await _stop();
    } on Object catch (error) {
      socket.destroy();
      await input.cancel();
      if (error is PairingAuthenticationException &&
          ++_failures >= maxAttempts) {
        await _finish(const PairingExpiredException(tooManyAttempts: true));
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _finish(PairingException error) async {
    if (!_result.isCompleted) _result.completeError(error);
    await _stop();
  }

  Future<void> _stop() async {
    _expiry.cancel();
    await _subscription.cancel();
    await _server.close();
  }
}

/// The sending phone's side: connects to the receiver of [code] and sets
/// up the encrypted channel (see [PairingListener]).
///
/// Throws [PairingAddressException] for a code whose address the [policy]
/// does not allow (nothing is sent), [PairingUnreachableException] when
/// nothing answers within [connectTimeout], and the [PairingException]s
/// of the set-up: a receiver that does not take the code closes the
/// connection ([PairingClosedException]).
Future<PairingChannel> connectPairing(
  PairingCode code, {
  PairingAddressPolicy policy = const PairingAddressPolicy(),
  Duration connectTimeout = pairingHandshakeTimeout,
  Duration handshakeTimeout = pairingHandshakeTimeout,
}) async {
  final address = InternetAddress.fromRawAddress(code.address);
  if (!policy.allows(address)) throw const PairingAddressException();
  final Socket socket;
  try {
    socket = await Socket.connect(address, code.port, timeout: connectTimeout);
  } on SocketException catch (error) {
    throw PairingUnreachableException(error.message);
  }
  socket.setOption(SocketOption.tcpNoDelay, true);
  final input = PairingByteReader(socket);
  try {
    final keys = await PairingHandshake.initiate(
      input: input,
      output: socket.add,
      code: code,
      timeout: handshakeTimeout,
    );
    final channel = PairingChannel(input: input, socket: socket, keys: keys);
    await channel.send('hello', const {'v': pairingProtocolVersion});
    checkHello(
      await channel.receiveMessage(
        timeout: handshakeTimeout,
        expected: const {'hello'},
      ),
    );
    return channel;
  } on Object {
    socket.destroy();
    await input.cancel();
    rethrow;
  }
}

/// Throws [PairingProtocolException] unless [hello] speaks
/// [pairingProtocolVersion].
void checkHello(PairingMessage hello) {
  if (hello.fields['v'] != pairingProtocolVersion) {
    throw const PairingProtocolException('Unsupported protocol version');
  }
}
