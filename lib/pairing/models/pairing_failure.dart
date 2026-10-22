import 'dart:io';

import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';

/// Why phone to phone stopped, as the screens explain it.
enum PairingFailure {
  /// The typed or pasted code is not a pairing code (or not for a phone
  /// on a local network).
  invalidCode,

  /// Nothing answered: not on the same network, or the code is gone.
  unreachable,

  /// The other phone did not take the code (it expired, or it is another
  /// phone's).
  refused,

  /// The code expired before a phone connected.
  expired,

  /// Phones tried the code with a wrong secret; it was made unusable.
  tooManyAttempts,

  /// The user said the numbers on both phones differ.
  sasMismatch,

  /// The other phone said no.
  declined,

  /// The other phone stopped the transfer.
  cancelled,

  /// The connection broke (Wi-Fi lost, the other app closed).
  connectionLost,

  /// The other phone did not answer in time.
  timedOut,

  /// The other phone sent something that did not check out (a damaged or
  /// changed frame, an unexpected message).
  protocol,

  /// This phone ran out of storage space.
  noSpace,

  /// Anything else.
  unknown;

  /// The failure behind [error]. While [connecting], a closed connection
  /// means the other phone refused the code.
  static PairingFailure of(Object error, {bool connecting = false}) =>
      switch (error) {
        PairingAddressException() => invalidCode,
        PairingUnreachableException() => unreachable,
        PairingClosedException() when connecting => refused,
        PairingClosedException() => connectionLost,
        PairingExpiredException(tooManyAttempts: true) => tooManyAttempts,
        PairingExpiredException() => expired,
        PairingDeclinedException() => declined,
        PairingCancelledException() => cancelled,
        PairingTimeoutException() => timedOut,
        PairingAuthenticationException() ||
        PairingProtocolException() => protocol,
        FileSystemException() when isNoSpace(error) => noSpace,
        _ => unknown,
      };
}
