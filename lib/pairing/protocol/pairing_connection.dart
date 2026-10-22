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

/// Time for the key agreement and the `hello` messages of a connection,
/// in all.
const pairingHandshakeTimeout = Duration(seconds: 10);

/// The receiving phone's side ([bind]): listens on one of its private
/// addresses on a port the system picks and waits, for the code's
/// validity, for one phone that knows [code].
///
/// * Connections from addresses the [policy] does not allow (anything but
///   private IPv4 addresses) are closed at once, and so is every
///   connection after one has succeeded.
/// * A connection is set up when the [PairingHandshake] and the `hello`
///   messages complete within [handshakeTimeout] (one deadline for all of
///   it); [connection] then completes with its channel, and the listener
///   closes the others and stops listening.
/// * Up to [maxPending] connections set up at once, so that one that
///   stalls cannot keep the real phone out. When another one arrives, the
///   oldest connection of the address with the most of them is closed (a
///   device that opens many loses its own first; a real phone needs well
///   under a second).
/// * Only a first encrypted frame that does not decrypt proves a wrong
///   code (timeouts and malformed handshakes prove nothing, and anybody
///   can cause them). After [maxAttempts] of those from one address, that
///   address is refused for as long as the code works; after
///   [maxFailures] in all, the code is burnt and [connection] fails with
///   [PairingExpiredException], as it does at [expiresAt]. One device
///   therefore cannot burn the code, and guesses stay few (the secret has
///   64 bits).
class PairingListener {
  new _(
    this._server,
    this.code,
    this.expiresAt, {
    required this.policy,
    required this.maxAttempts,
    required this.maxFailures,
    required this.maxPending,
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
    int maxFailures = 30,
    int maxPending = 4,
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
      maxFailures: maxFailures,
      maxPending: maxPending,
      handshakeTimeout: handshakeTimeout,
      validity: validity,
    );
  }

  /// What the other phone needs to connect.
  final PairingCode code;

  /// When [code] stops working (unless a phone connected before).
  final DateTime expiresAt;

  final PairingAddressPolicy policy;

  /// Wrong codes from one address before it is refused.
  final int maxAttempts;

  /// Wrong codes in all before the code is burnt.
  final int maxFailures;

  /// Connections that may set up at once.
  final int maxPending;

  final Duration handshakeTimeout;

  final ServerSocket _server;
  late final StreamSubscription<Socket> _subscription;
  late final Timer _expiry;
  final Completer<PairingChannel> _result = Completer();

  /// The connections setting up, oldest first.
  final List<_Pending> _pending = [];

  /// Wrong codes by address, and in all.
  final Map<String, int> _failures = {};
  int _totalFailures = 0;

  /// The channel to the first phone that knew [code].
  Future<PairingChannel> get connection => _result.future;

  /// Stops listening; a [connection] that is still pending fails with
  /// [PairingClosedException].
  Future<void> close() => _finish(const PairingClosedException());

  void _onSocket(Socket socket) {
    final address = socket.remoteAddress;
    if (_result.isCompleted ||
        !policy.allows(address) ||
        (_failures[address.address] ?? 0) >= maxAttempts) {
      socket.destroy();
      return;
    }
    final pending = _Pending(socket, address.address);
    _pending.add(pending);
    if (_pending.length > maxPending) _dropOne();
    unawaited(_accept(pending));
  }

  /// Closes the oldest connection of the address with the most of them
  /// (all of them counted, the one that just arrived included, which is
  /// never the one closed).
  void _dropOne() {
    final counts = <String, int>{};
    for (final pending in _pending) {
      counts.update(pending.address, (count) => count + 1, ifAbsent: () => 1);
    }
    final most = counts.values.reduce(max);
    _drop(_pending.firstWhere((pending) => counts[pending.address] == most));
  }

  void _drop(_Pending pending) {
    _pending.remove(pending);
    pending.drop();
  }

  Future<void> _accept(_Pending pending) async {
    final socket = pending.socket;
    final input = pending.input;
    final deadline = Timer(handshakeTimeout, () => _drop(pending));
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
      if (_result.isCompleted || pending.dropped) {
        channel.destroy();
        return;
      }
      // This phone knows the code: it is the one (the others are closed),
      // and its hello goes out first.
      deadline.cancel();
      _pending.remove(pending);
      final hello = channel.send('hello', const {'v': pairingProtocolVersion});
      _result.complete(channel);
      await _stop();
      await hello;
    } on Object catch (error) {
      _drop(pending);
      if (error is PairingAuthenticationException) _wrongCode(pending.address);
    } finally {
      deadline.cancel();
      _pending.remove(pending);
    }
  }

  /// Counts a wrong code from [address].
  void _wrongCode(String address) {
    final count = _failures.update(
      address,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    if (count >= maxAttempts) {
      for (final pending in [..._pending]) {
        if (pending.address == address) _drop(pending);
      }
    }
    if (++_totalFailures >= maxFailures) {
      unawaited(_finish(const PairingExpiredException(tooManyAttempts: true)));
    }
  }

  Future<void> _finish(PairingException error) async {
    if (!_result.isCompleted) _result.completeError(error);
    await _stop();
  }

  Future<void> _stop() async {
    _expiry.cancel();
    [..._pending].forEach(_drop);
    await _subscription.cancel();
    await _server.close();
  }
}

/// A connection to a [PairingListener] that is setting up.
class _Pending {
  new(this.socket, this.address) : input = PairingByteReader(socket);

  final Socket socket;

  /// The other end's address (a closed socket no longer tells).
  final String address;

  final PairingByteReader input;
  bool dropped = false;

  /// Closes it at once; what it waits for fails.
  void drop() {
    if (dropped) return;
    dropped = true;
    socket.destroy();
    unawaited(input.cancel());
  }
}

/// The sending phone's side: connects to the receiver of [code] and sets
/// up the encrypted channel (see [PairingListener]).
///
/// Throws [PairingAddressException] for a code whose address the [policy]
/// does not allow (nothing is sent), [PairingUnreachableException] when
/// nothing answers within [connectTimeout], and the [PairingException]s
/// of the set-up, which must complete within [handshakeTimeout] in all
/// ([PairingTimeoutException]): a receiver that does not take the code
/// closes the connection ([PairingClosedException]).
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
  var expired = false;
  final deadline = Timer(handshakeTimeout, () {
    expired = true;
    socket.destroy();
    unawaited(input.cancel());
  });
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
    if (expired) throw const PairingTimeoutException();
    rethrow;
  } finally {
    deadline.cancel();
  }
}

/// Throws [PairingProtocolException] unless [hello] speaks
/// [pairingProtocolVersion].
void checkHello(PairingMessage hello) {
  if (hello.fields['v'] != pairingProtocolVersion) {
    throw const PairingProtocolException('Unsupported protocol version');
  }
}
