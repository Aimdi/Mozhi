import 'package:translation_repository/src/quality/protected_patterns.dart';
import 'package:translation_repository/src/quality/text_masker.dart';

/// What [PersonalData] finds.
enum PersonalDataKind {
  email,
  phone,

  /// International bank account numbers (checked with ISO 7064 mod 97).
  iban,

  /// Payment card numbers (13 to 19 digits, checked with the Luhn
  /// algorithm).
  paymentCard,

  /// IPv4 and IPv6 addresses.
  ipAddress,
}

/// Finds personal data in a text, for the shield that keeps it on the
/// device (`TranslationRepository.maskPersonalData`): e-mail addresses,
/// phone numbers, IBANs, payment card numbers and IP addresses.
///
/// Tuned to find rather than to miss: a false hit only costs a masked
/// span, which is put back unchanged. Pure regular expressions plus
/// checksums; texts without `@`, digits or a colon next to a hexadecimal
/// letter are skipped at once.
///
/// E-mail addresses may have letters of any script (`jürgen@example.de`,
/// `info@müller.de`; see `ProtectedPatterns.email`). IP addresses are
/// IPv4 and IPv6 ([isValidIpv6]: full, `::`-compressed, with an IPv4 tail
/// such as `::ffff:192.0.2.1` and a zone such as `%eth0`); times, ratios,
/// verses and MAC addresses (`10:30:00`, `1:2:3`, `00:1a:2b:3c:4d:5e`) are
/// not.
abstract final class PersonalData {
  static final _email = RegExp(ProtectedPatterns.email, unicode: true);

  static final _iban = RegExp(
    r'(?<![A-Za-z0-9])[A-Za-z]{2}\d{2}(?:[ ]?[A-Za-z0-9]{4}){2,7}'
    '(?:[ ]?[A-Za-z0-9]{1,4})?(?![A-Za-z0-9])',
  );

  static final _card = RegExp(
    r'(?<![\d.,])\d(?:[ -]?\d){12,18}(?![\d]|[.,]\d)',
  );

  static final _ipv4 = RegExp(
    r'(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}'
    r'(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\d]|\.\d)',
  );

  /// An IPv6 address candidate ([isValidIpv6] decides): hexadecimal
  /// groups and colons, possibly with an IPv4 tail and a zone, not inside
  /// a word or a longer run of digits, colons and dots (a timestamp such
  /// as `12:34:56.789` is no candidate).
  static final _ipv6 = RegExp(
    r'(?<![\p{L}\p{N}_:.])(?=[0-9A-Fa-f]{0,4}:)[0-9A-Fa-f:]{2,39}'
    r'(?:(?<=:)(?:\d{1,3}\.){3}\d{1,3})?(?:%[\p{L}\p{N}_~-]+)?'
    r'(?![\p{L}\p{N}_:]|\.\d)',
    unicode: true,
  );

  static final _ipv4Tail = RegExp(
    r'^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}'
    r'(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$',
  );
  static final _hexGroup = RegExp(r'^[0-9A-Fa-f]{1,4}$');
  static final _hexLetter = RegExp('[A-Fa-f]');

  /// A phone number candidate: an optional `+` or `00`, then digits with
  /// single spaces, dots, dashes, slashes or parentheses between them.
  static final _phone = RegExp(
    r'(?<![\w@+.\-/])(?:\+|00)?[(\d][\d ().\-/]{5,24}\d(?![\w@])',
  );

  static final _date = RegExp(r'^\d{1,4}[./\-]\d{1,2}[./\-]\d{1,4}$');
  static final _nanp = RegExp(r'^\(?\d{3}\)?[ .\-]\d{3}[ .\-]\d{4}$');
  static final _doubleSeparator = RegExp(r'[ .\-/]{2}|[(][ .\-/)]|[ .\-/][)]');
  static final _nonDigit = RegExp(r'\D');
  static final _digitOrAt = RegExp('[0-9@]|[A-Fa-f]:|:[A-Fa-f]');

  /// The personal data in [text], as [ProtectedKind.personal] spans
  /// (overlaps are merged by `TextMasker.merge`).
  static List<ProtectedSpan> find(String text) => [
    for (final (_, start, end) in matches(text))
      ProtectedSpan(start, end, kind: ProtectedKind.personal),
  ];

  /// What [find] finds, with its kind, in text order (spans may overlap,
  /// e.g. a card number that also looks like a phone number).
  static List<(PersonalDataKind, int, int)> matches(String text) {
    if (!_digitOrAt.hasMatch(text)) return const [];
    final found = <(PersonalDataKind, int, int)>[
      for (final match in _email.allMatches(text))
        (PersonalDataKind.email, match.start, match.end),
      for (final match in _iban.allMatches(text))
        if (isValidIban(match.group(0)!))
          (PersonalDataKind.iban, match.start, match.end),
      for (final match in _card.allMatches(text))
        if (isValidCardNumber(match.group(0)!))
          (PersonalDataKind.paymentCard, match.start, match.end),
      for (final match in _ipv4.allMatches(text))
        (PersonalDataKind.ipAddress, match.start, match.end),
      for (final match in _ipv6.allMatches(text))
        if (isValidIpv6(match.group(0)!))
          (PersonalDataKind.ipAddress, match.start, match.end),
      for (final match in _phone.allMatches(text))
        if (_trimmedPhone(text, match.start, match.end) case (
          final start,
          final end,
        ))
          (PersonalDataKind.phone, start, end),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return found;
  }

  /// Whether [candidate] (spaces allowed) is an IBAN: 15 to 34 characters,
  /// a country code, check digits and a valid ISO 7064 mod 97 checksum.
  static bool isValidIban(String candidate) {
    final iban = candidate.replaceAll(' ', '').toUpperCase();
    if (iban.length < 15 || iban.length > 34) return false;
    if (!RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]+$').hasMatch(iban)) return false;
    final rearranged = iban.substring(4) + iban.substring(0, 4);
    var remainder = 0;
    for (final unit in rearranged.codeUnits) {
      final value = unit >= 0x41 ? unit - 0x41 + 10 : unit - 0x30;
      remainder = value >= 10
          ? (remainder * 100 + value) % 97
          : (remainder * 10 + value) % 97;
    }
    return remainder == 1;
  }

  /// Whether [candidate] is an IPv6 address that reads as one: eight
  /// groups of one to four hexadecimal digits separated by colons, or
  /// fewer with one `::` standing for the missing ones; the last two
  /// groups may be an IPv4 address (`::ffff:192.0.2.1`), and a zone may
  /// follow (`fe80::1%eth0`). To tell it from times, ratios, verses and
  /// code (`1:2:3:4:5:6:7:8`, `a[1::2]`, `A::B`), it also needs a group of
  /// three or four digits, an IPv4 tail or, written in full, a hexadecimal
  /// letter: `::1` and `::` are not personal anyway.
  static bool isValidIpv6(String candidate) {
    var address = candidate;
    final zone = address.indexOf('%');
    if (zone >= 0) address = address.substring(0, zone);
    final tail = address.substring(address.lastIndexOf(':') + 1);
    final ipv4 = tail.contains('.');
    if (ipv4) {
      if (!_ipv4Tail.hasMatch(tail)) return false;
      address = '${address.substring(0, address.length - tail.length)}0:0';
    }
    final halves = address.split('::');
    if (halves.length > 2) return false;
    final groups = [
      for (final half in halves)
        if (half.isNotEmpty) ...half.split(':'),
    ];
    if (!groups.every(_hexGroup.hasMatch)) return false;
    final compressed = halves.length == 2;
    if (compressed ? groups.length > 7 : groups.length != 8) return false;
    return ipv4 ||
        groups.any((group) => group.length >= 3) ||
        (!compressed && groups.any(_hexLetter.hasMatch));
  }

  /// Whether [candidate] (spaces and dashes allowed) is a payment card
  /// number: 13 to 19 digits, not all the same, with a valid Luhn check
  /// digit.
  static bool isValidCardNumber(String candidate) {
    final digits = candidate.replaceAll(_nonDigit, '');
    if (digits.length < 13 || digits.length > 19) return false;
    if (digits.split('').toSet().length == 1) return false;
    return isLuhnValid(digits);
  }

  /// The Luhn (mod 10) check of a string of digits.
  static bool isLuhnValid(String digits) {
    if (digits.isEmpty || digits.contains(_nonDigit)) return false;
    var sum = 0;
    var double = false;
    for (var i = digits.length - 1; i >= 0; i--) {
      var value = digits.codeUnitAt(i) - 0x30;
      if (double) {
        value *= 2;
        if (value > 9) value -= 9;
      }
      sum += value;
      double = !double;
    }
    return sum % 10 == 0;
  }

  /// The span of a phone number in the candidate match `start`..`end`
  /// (without a trailing parenthesis or separator), or null when it is no
  /// phone number: 7 to 15 digits, single separators, not a date, and
  /// written as phone numbers are (international `+` or `00`, a leading
  /// area code in parentheses or a trunk `0`, or the North American
  /// `555-123-4567`).
  static (int, int)? _trimmedPhone(String text, int start, int end) {
    var from = start;
    var candidate = text.substring(start, end);
    if (candidate.startsWith('(') &&
        '('.allMatches(candidate).length > ')'.allMatches(candidate).length) {
      // "(030 1234567)": the parenthesis is the sentence's.
      candidate = candidate.substring(1);
      from++;
    }
    if (_doubleSeparator.hasMatch(candidate) || _date.hasMatch(candidate)) {
      return null;
    }
    final digits = candidate.replaceAll(_nonDigit, '').length;
    if (digits < 7 || digits > 15) return null;
    final opens = '('.allMatches(candidate).length;
    final closes = ')'.allMatches(candidate).length;
    if (opens != closes) return null;
    final international =
        candidate.startsWith('+') || candidate.startsWith('00');
    final written =
        international ||
        candidate.startsWith('(') ||
        (candidate.startsWith('0') && digits >= 9) ||
        _nanp.hasMatch(candidate);
    return written ? (from, end) : null;
  }
}
