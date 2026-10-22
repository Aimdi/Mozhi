/// Where phone to phone lives, without loading its screens (they are
/// deferred).
abstract final class PairingRoutes {
  /// Both directions, explained (`/pairing`).
  static const location = '/pairing';

  /// **Receive on this phone**.
  static const receive = '/pairing/receive';

  /// **Send to another phone**; `?code=…` fills in the code, `?what=packs`
  /// selects the language packs instead of the data.
  static const send = '/pairing/send';

  /// Where `mozhi://pair?code=…` arrives (the QR code's link, rewritten by
  /// the Android app to `/pair?code=…`): an alias of [send].
  static const link = '/pair';

  /// Query parameters of [send].
  static const codeParameter = 'code';
  static const purposeParameter = 'what';

  /// The value of [purposeParameter] that selects the language packs.
  static const packsPurpose = 'packs';

  /// The location of [send] with [code] filled in, the language packs
  /// selected when [packs].
  static String sendLocation({String? code, bool packs = false}) {
    final query = {
      if (code != null && code.isNotEmpty) codeParameter: code,
      if (packs) purposeParameter: packsPurpose,
    };
    return Uri(
      path: send,
      queryParameters: query.isEmpty ? null : query,
    ).toString();
  }
}
