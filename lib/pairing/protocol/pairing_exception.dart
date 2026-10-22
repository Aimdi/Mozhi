/// Why a phone-to-phone connection or transfer stopped (see
/// docs/pairing.md). None of them carries text from the other phone.
sealed class PairingException implements Exception {
  const new(this.message);

  /// What went wrong, for logs and tests (never shown as is).
  final String message;

  String get _name;

  @override
  String toString() => '$_name($message)';
}

/// The other phone closed the connection (or it broke, e.g. the Wi-Fi
/// dropped).
final class PairingClosedException extends PairingException {
  const new([super.message = 'Connection closed']);

  @override
  String get _name => 'PairingClosedException';
}

/// Nothing arrived from the other phone in time.
final class PairingTimeoutException extends PairingException {
  const new([super.message = 'Timed out']);

  @override
  String get _name => 'PairingTimeoutException';
}

/// A frame did not decrypt: the other phone does not know the code, or the
/// data was changed, replayed or reordered on the way.
final class PairingAuthenticationException extends PairingException {
  const new([super.message = 'Authentication failed']);

  @override
  String get _name => 'PairingAuthenticationException';
}

/// The other phone sent something this protocol does not allow (an
/// oversize frame, a malformed or unexpected message, a file nobody asked
/// for).
final class PairingProtocolException extends PairingException {
  const new(super.message);

  @override
  String get _name => 'PairingProtocolException';
}

/// The address is not on a private network (10/8, 172.16/12, 192.168/16),
/// so pairing refuses it.
final class PairingAddressException extends PairingException {
  const new([super.message = 'Not a private address']);

  @override
  String get _name => 'PairingAddressException';
}

/// The other phone stopped the transfer.
final class PairingCancelledException extends PairingException {
  const new([super.message = 'Cancelled']);

  @override
  String get _name => 'PairingCancelledException';
}

/// The other phone said no to the offer.
final class PairingDeclinedException extends PairingException {
  const new([super.message = 'Declined']);

  @override
  String get _name => 'PairingDeclinedException';
}

/// The pairing code is no longer valid: it expired, or too many phones
/// tried it with the wrong secret ([tooManyAttempts]).
final class PairingExpiredException extends PairingException {
  const new({this.tooManyAttempts = false})
    : super(tooManyAttempts ? 'Too many attempts' : 'Code expired');

  final bool tooManyAttempts;

  @override
  String get _name => 'PairingExpiredException';
}

/// No phone answered at the code's address: the phones are not on the
/// same network, or the receiving phone stopped listening.
final class PairingUnreachableException extends PairingException {
  const new([super.message = 'Unreachable']);

  @override
  String get _name => 'PairingUnreachableException';
}
