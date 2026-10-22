import 'dart:convert';
import 'dart:math';

/// The random secrets of a shared conversation, from a cryptographically
/// secure generator ([Random.secure] by default).
class ShareSecrets {
  new([Random? random]) : _random = random ?? Random.secure();

  final Random _random;

  /// 128 random bits, base64url without padding (22 characters): the
  /// session token in the link, and each guest's key.
  String token() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// 64 random bits as 16 hex digits: a guest's public id.
  String id() =>
      [for (var i = 0; i < 8; i++) _random.nextInt(256).toRadixString(16)]
          .map((byte) => byte.padLeft(2, '0'))
          .join();

  /// Four random digits.
  String pin() => _random.nextInt(10000).toString().padLeft(4, '0');
}

/// Whether [a] and [b] are equal, taking the same time whatever their
/// first difference (so a guess cannot be refined by timing).
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}

/// Counts events per key in a sliding window (requests per address,
/// replies per guest, wrong PINs).
class ShareRateLimiter {
  new({required this.max, required this.per, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Events allowed per key within [per].
  final int max;
  final Duration per;
  final DateTime Function() _clock;
  final Map<String, List<DateTime>> _events = {};

  /// Records an event of [key] and returns true, unless [key] had [max]
  /// events within [per] already (then nothing is recorded).
  bool allow(String key) {
    final now = _clock();
    final events = _recent(key, now);
    if (events.length >= max) return false;
    events.add(now);
    return true;
  }

  /// Whether [key] may have another event now (nothing is recorded).
  bool allows(String key) => _recent(key, _clock()).length < max;

  List<DateTime> _recent(String key, DateTime now) {
    final events = _events.putIfAbsent(key, () => []);
    final since = now.subtract(per);
    events.removeWhere((time) => !time.isAfter(since));
    if (_events.length > 512) {
      // Forget keys that went quiet, so the map cannot grow without end.
      _events.removeWhere(
        (other, times) =>
            other != key && times.every((time) => !time.isAfter(since)),
      );
    }
    return events;
  }
}
