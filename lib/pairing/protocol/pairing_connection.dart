import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:mozhi/pairing/protocol/byte_reader.dart';
import 'package:mozhi/pairing/protocol/pairing_address.dart';
import 'package:mozhi/pairing/protocol/pairing_channel.dart';
import 'package:mozhi/pairing/protocol/pairing_code.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';
import 'package:mozhi/pairing/protocol/pairing_handshake.dart';

export 'package:mozhi/pairing/protocol/pairing_channel.dart'
    show checkHello, helloFeatures, pairingProtocolVersion;

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
/// * Handshakes started (connections taken on) are limited per minute:
///   [maxHandshakesPerMinute] in all and [maxAddressHandshakesPerMinute]
///   from one address. A connection beyond them is closed at once and not
///   counted, so the limits only hold back a flood while it lasts, and the
///   work a flood makes the phone do (a key agreement each) stays small.
/// * Up to [maxPending] connections set up at once, at most
///   [maxPendingPerAddress] from one address: a further one from that
///   address closes its oldest one (a device that opens many loses its
///   own first). When [maxPending] are setting up, a new one closes the
///   oldest of the address with the most of them, but only one that has
///   had [minSetupTime] (a real phone needs well under a second); when
///   all are younger, the new one is closed instead. A flood from many
///   addresses therefore cannot push out a phone in the middle of its
///   key agreement, and one that stalls cannot keep the real phone out.
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
    required this.maxPendingPerAddress,
    required this.maxHandshakesPerMinute,
    required this.maxAddressHandshakesPerMinute,
    required this.minSetupTime,
    required this.handshakeTimeout,
    required Duration validity,
    required this._now,
  }) {
    unawaited(_result.future.then((_) {}, onError: (Object _) {}));
    _expiry = Timer(validity, () => _finish(const PairingExpiredException()));
    _subscription = _server.listen(
      _onSocket,
      onError: (Object error) => _finish(PairingClosedException('$error')),
      onDone: () => _finish(const PairingClosedException()),
    );
  }

  /// Starts listening on [address] (see [PairingListener]); [now] is the
  /// clock of the per-minute limits and [minSetupTime].
  static Future<PairingListener> bind(
    InternetAddress address, {
    Duration validity = const Duration(minutes: 5),
    int maxAttempts = 3,
    int maxFailures = 30,
    int maxPending = 8,
    int maxPendingPerAddress = 2,
    int maxHandshakesPerMinute = 30,
    int maxAddressHandshakesPerMinute = 6,
    Duration minSetupTime = const Duration(seconds: 2),
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
      maxPendingPerAddress: maxPendingPerAddress,
      maxHandshakesPerMinute: maxHandshakesPerMinute,
      maxAddressHandshakesPerMinute: maxAddressHandshakesPerMinute,
      minSetupTime: minSetupTime,
      handshakeTimeout: handshakeTimeout,
      validity: validity,
      now: now,
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

  /// Connections that may set up at once, in all.
  final int maxPending;

  /// Connections that may set up at once from one address.
  final int maxPendingPerAddress;

  /// Handshakes started per minute, in all.
  final int maxHandshakesPerMinute;

  /// Handshakes started per minute from one address.
  final int maxAddressHandshakesPerMinute;

  /// How long a connection may set up before a newer one can push it out.
  final Duration minSetupTime;

  final Duration handshakeTimeout;

  final ServerSocket _server;
  final DateTime Function() _now;
  late final StreamSubscription<Socket> _subscription;
  late final Timer _expiry;
  final Completer<PairingChannel> _result = Completer();

  /// The connections setting up, oldest first.
  final List<_Pending> _pending = [];

  /// When the handshakes of the last minute started, and from where.
  final List<(DateTime, String)> _started = [];

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
    final from = address.address;
    if (_result.isCompleted ||
        !policy.allows(address) ||
        (_failures[from] ?? 0) >= maxAttempts) {
      socket.destroy();
      return;
    }
    final now = _now();
    final since = now.subtract(const Duration(minutes: 1));
    _started.removeWhere((start) => !start.$1.isAfter(since));
    if (_started.length >= maxHandshakesPerMinute ||
        _started.where((start) => start.$2 == from).length >=
            maxAddressHandshakesPerMinute) {
      socket.destroy();
      return;
    }
    final own = [
      for (final pending in _pending)
        if (pending.address == from) pending,
    ];
    if (own.length >= maxPendingPerAddress) {
      _drop(own.first);
    } else if (_pending.length >= maxPending) {
      final oldest = _replaceable(now, from);
      if (oldest == null) {
        socket.destroy();
        return;
      }
      _drop(oldest);
    }
    _started.add((now, from));
    final pending = _Pending(socket, from, now);
    _pending.add(pending);
    unawaited(_accept(pending));
  }

  /// Of the connections that had [minSetupTime], the oldest of the
  /// address with the most of them (all of them counted, the one arriving
  /// from [from] included); null when none had.
  _Pending? _replaceable(DateTime now, String from) {
    final counts = <String, int>{from: 1};
    for (final pending in _pending) {
      counts.update(pending.address, (count) => count + 1, ifAbsent: () => 1);
    }
    _Pending? found;
    for (final pending in _pending) {
      if (now.difference(pending.since) < minSetupTime) continue;
      if (found == null || counts[pending.address]! > counts[found.address]!) {
        found = pending;
      }
    }
    return found;
  }

  void _drop(_Pending pending) {
    _pending.remove(pending);
    pending.drop();
  }

  Future<void> _accept(_Pending pending) async {
    final socket = pending.socket;
    final input = pending.input;
    final deadline = Timer(handshakeTimeout, () => _drop(pending));
    PairingChannel? channel;
    var handedOut = false;
    try {
      final keys = await PairingHandshake.respond(
        input: input,
        output: socket.add,
        code: code,
        timeout: handshakeTimeout,
      );
      final opened = channel = PairingChannel(
        input: input,
        socket: socket,
        keys: keys,
      );
      opened.acceptHello(
        await opened.receiveMessage(
          timeout: handshakeTimeout,
          expected: const {'hello'},
        ),
      );
      if (_result.isCompleted || pending.dropped) {
        opened.destroy();
        return;
      }
      // This phone knows the code: it is the one (the others are closed),
      // and its hello goes out first.
      deadline.cancel();
      _pending.remove(pending);
      final hello = opened.sendHello();
      handedOut = true;
      _result.complete(opened);
      await _stop();
      await hello;
    } on Object catch (error) {
      // A channel handed out is its user's to close.
      if (!handedOut) {
        channel?.destroy();
        _drop(pending);
      }
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
  new(this.socket, this.address, this.since)
    : input = PairingByteReader(socket);

  final Socket socket;

  /// The other end's address (a closed socket no longer tells).
  final String address;

  /// When it was taken on.
  final DateTime since;

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

/// How long the sending phone waits before it tries again when the
/// receiver closed the connection before answering (it was busy with
/// other connections, see [PairingListener]): once after each delay.
const pairingRetryDelays = [Duration(seconds: 1), Duration(seconds: 2)];

/// The sending phone's side: connects to the receiver of [code] and sets
/// up the encrypted channel (see [PairingListener]).
///
/// Throws [PairingAddressException] for a code whose address the [policy]
/// does not allow (nothing is sent), [PairingUnreachableException] when
/// nothing answers within [connectTimeout], and the [PairingException]s
/// of the set-up, which must complete within [handshakeTimeout] in all
/// ([PairingTimeoutException]): a receiver that does not take the code
/// closes the connection ([PairingClosedException]). A receiver that
/// closes the connection before it sent its key (one that is busy with a
/// flood of connections) is tried again after each of [retryDelays]; one
/// that closed it later (a wrong code) is not.
Future<PairingChannel> connectPairing(
  PairingCode code, {
  PairingAddressPolicy policy = const PairingAddressPolicy(),
  Duration connectTimeout = pairingHandshakeTimeout,
  Duration handshakeTimeout = pairingHandshakeTimeout,
  List<Duration> retryDelays = pairingRetryDelays,
}) async {
  final address = InternetAddress.fromRawAddress(code.address);
  if (!policy.allows(address)) throw const PairingAddressException();
  for (var attempt = 0; ; attempt++) {
    try {
      return await _connectOnce(
        code,
        address,
        connectTimeout: connectTimeout,
        handshakeTimeout: handshakeTimeout,
      );
    } on _Refused catch (refused) {
      if (attempt >= retryDelays.length) throw refused.error;
      await Future<void>.delayed(retryDelays[attempt]);
    }
  }
}

/// `ECONNRESET` (Linux, so Android).
const _connectionReset = 104;

/// The receiver closed the connection before it answered.
class _Refused implements Exception {
  const new(this.error);

  final PairingClosedException error;
}

Future<PairingChannel> _connectOnce(
  PairingCode code,
  InternetAddress address, {
  required Duration connectTimeout,
  required Duration handshakeTimeout,
}) async {
  final Socket socket;
  try {
    socket = await Socket.connect(address, code.port, timeout: connectTimeout);
  } on SocketException catch (error) {
    // Closed as soon as it was taken: turned away, not unreachable (the
    // timing decides whether the connect or the first read sees it).
    // coverage:ignore-start
    if (error.osError?.errorCode == _connectionReset) {
      throw _Refused(PairingClosedException(error.message));
    }
    // coverage:ignore-end
    throw PairingUnreachableException(error.message);
  }
  socket.setOption(SocketOption.tcpNoDelay, true);
  final input = PairingByteReader(socket);
  var expired = false;
  // The second write goes out once the receiver's key came.
  var writes = 0;
  final deadline = Timer(handshakeTimeout, () {
    expired = true;
    socket.destroy();
    unawaited(input.cancel());
  });
  PairingChannel? channel;
  try {
    final keys = await PairingHandshake.initiate(
      input: input,
      output: (bytes) {
        writes++;
        socket.add(bytes);
      },
      code: code,
      timeout: handshakeTimeout,
    );
    final opened = channel = PairingChannel(
      input: input,
      socket: socket,
      keys: keys,
    );
    await opened.sendHello();
    opened.acceptHello(
      await opened.receiveMessage(
        timeout: handshakeTimeout,
        expected: const {'hello'},
      ),
    );
    return opened;
  } on Object catch (error) {
    channel?.destroy();
    socket.destroy();
    await input.cancel();
    if (expired) throw const PairingTimeoutException();
    if (error is PairingClosedException && writes < 2) throw _Refused(error);
    rethrow;
  } finally {
    deadline.cancel();
  }
}
