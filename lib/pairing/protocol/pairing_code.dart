import 'dart:math';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// What the receiving phone shows and the sending phone needs: the
/// receiver's private IPv4 [address], the [port] it listens on and a
/// one-time [secret] (see docs/pairing.md).
///
/// Written as a short code ([text], 24 characters of Crockford's base32 in
/// groups of four, the last one a check character that catches typos) and
/// as a link ([link], `mozhi://pair?code=…`) for the QR code, which the
/// system camera opens in Mozhi. [tryParse] reads both, with or without
/// separators, in any case.
class PairingCode extends Equatable {
  new({
    required List<int> address,
    required this.port,
    required List<int> secret,
  }) : address = Uint8List.fromList(address),
       secret = Uint8List.fromList(secret) {
    if (address.length != 4) {
      throw ArgumentError.value(address, 'address', 'Not an IPv4 address');
    }
    if (port <= 0 || port > 0xffff) {
      throw ArgumentError.value(port, 'port', 'Invalid port');
    }
    if (secret.length != secretLength) {
      throw ArgumentError.value(secret, 'secret', 'Invalid secret');
    }
  }

  /// A new code for [address] (four bytes) and [port] with a fresh secret
  /// from [random] (default: the platform's secure random generator).
  factory generate({
    required List<int> address,
    required int port,
    Random? random,
  }) {
    final source = random ?? Random.secure();
    return PairingCode(
      address: address,
      port: port,
      secret: [for (var i = 0; i < secretLength; i++) source.nextInt(256)],
    );
  }

  /// The code in [input]: a pairing link (`mozhi://pair?code=…`, also the
  /// app location `/pair?code=…`) or the code itself; null when it is
  /// neither, or its check character does not match (a typo).
  static PairingCode? tryParse(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri != null && uri.queryParameters.containsKey(linkParameter)) {
      final isLink =
          (uri.isScheme(linkScheme) && uri.host.toLowerCase() == linkHost) ||
          (!uri.hasScheme && uri.path == '/$linkHost');
      if (!isLink) return null;
      text = uri.queryParameters[linkParameter]!;
    }
    final values = <int>[];
    for (final unit in text.toUpperCase().codeUnits) {
      final char = String.fromCharCode(unit);
      if (char == '-' || char == ' ' || char == ' ') continue;
      final value = _alphabet.indexOf(_aliases[char] ?? char);
      if (value < 0) return null;
      values.add(value);
    }
    if (values.length != textLength) return null;
    final check = values.removeLast();
    if (check != _checkOf(values)) return null;
    final bytes = _fromBase32(values);
    final port = bytes[4] << 8 | bytes[5];
    if (port == 0) return null;
    return PairingCode(
      address: bytes.sublist(0, 4),
      port: port,
      secret: bytes.sublist(6),
    );
  }

  /// Bytes of the one-time secret: 64 bits, which nobody can guess in the
  /// few minutes a code is valid (see docs/pairing.md).
  static const secretLength = 8;

  /// Characters of [text] without its separators.
  static const textLength = 24;

  /// `mozhi://pair?code=…`.
  static const linkScheme = 'mozhi';
  static const linkHost = 'pair';
  static const linkParameter = 'code';

  /// The receiver's private IPv4 address.
  final Uint8List address;

  /// The TCP port the receiver listens on.
  final int port;

  /// The one-time secret both phones mix into their keys.
  final Uint8List secret;

  /// [address] as `192.168.1.20`.
  String get host => address.join('.');

  /// The code as typed: `ABCD-EFGH-JKMN-PQRS-TVWX-YZ01`.
  String get text {
    final plain = _plain;
    return [for (var i = 0; i < plain.length; i += 4) plain.substring(i, i + 4)]
        .join('-');
  }

  /// The link of the QR code (`mozhi://pair?code=…`, without separators).
  String get link => '$linkScheme://$linkHost?$linkParameter=$_plain';

  String get _plain {
    final values = _toBase32([...address, port >> 8, port & 0xff, ...secret]);
    return [
      for (final value in [...values, _checkOf(values)]) _alphabet[value],
    ].join();
  }

  @override
  List<Object?> get props => [address, port, secret];

  @override
  String toString() => 'PairingCode($host:$port)';

  /// Crockford's base32 (no I, L, O or U, which look like other
  /// characters).
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Letters read as the digits they look like.
  static const _aliases = {'O': '0', 'I': '1', 'L': '1'};

  /// 5-bit values of [bytes], padded with zero bits.
  static List<int> _toBase32(List<int> bytes) {
    final values = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final byte in bytes) {
      buffer = (buffer << 8 | byte) & 0xffff;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        values.add(buffer >> bits & 31);
      }
    }
    if (bits > 0) values.add(buffer << (5 - bits) & 31);
    return values;
  }

  /// The bytes of 5-bit [values] (the inverse of [_toBase32]).
  static Uint8List _fromBase32(List<int> values) {
    final bytes = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final value in values) {
      buffer = (buffer << 5 | value) & 0xffff;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        bytes.add(buffer >> bits & 0xff);
      }
    }
    return Uint8List.fromList(bytes);
  }

  /// A weighted sum modulo 31 (a prime), which changes with any single
  /// mistyped character and any swap of two neighbours.
  static int _checkOf(List<int> values) {
    var sum = 0;
    for (final (index, value) in values.indexed) {
      sum += (index + 1) * value;
    }
    return sum % 31;
  }
}
