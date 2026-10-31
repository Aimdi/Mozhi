/// Tailscale's MagicDNS names (`*.ts.net`) and where they lead.
///
/// A `.ts.net` name is not private by its name alone: on a tailnet it
/// resolves to the device's Tailscale address (100.64.0.0/10 or
/// fd7a:115c:a1e0::/48), but a Tailscale Funnel name resolves to public
/// relay addresses that anyone on the internet reaches. So a `.ts.net`
/// host counts as private ([isPrivate]) only once a lookup showed that
/// every address it resolves to is Tailscale's ([record]); until then, and
/// when it resolves anywhere else, it is a public server: it gets the
/// proxy, the consent and the `https` rule of the internet.
///
/// Packages cannot resolve names or see the device's network interfaces
/// (they run in browsers too), so the app (`TailnetResolver`) looks the
/// names up and [record]s the answers here, for every check that asks
/// `AiProviderConfig.isLocalHost` or `DataDestination.isPrivateHost`. It
/// records answers only while the device has a Tailscale interface, looks
/// a name up again once its record is older than [ttl] ([isFresh]), and
/// [forget]s every record when that interface comes or goes. A record is
/// the latest verdict: [isPrivate] keeps answering from it until the app
/// replaces or forgets it, which the app does before every connection.
abstract final class TailnetHosts {
  static final Map<String, _Record> _records = {};

  /// How long a [record] stays [isFresh]: the app looks the name up again
  /// after it.
  static const ttl = Duration(seconds: 60);

  /// Whether [host] (as in [Uri.host]) is a Tailscale MagicDNS name
  /// (`ts.net` itself or a name under it).
  static bool isTailnetName(String host) {
    final name = _normalize(host);
    return name == 'ts.net' || name.endsWith('.ts.net');
  }

  /// Whether [host] is a [isTailnetName] whose last lookup showed only
  /// Tailscale addresses ([isTailscaleAddress]).
  static bool isPrivate(String host) =>
      _records[_normalize(host)]?.isPrivate ?? false;

  /// Whether a lookup of [host] was [record]ed (private or not).
  static bool isKnown(String host) => _records.containsKey(_normalize(host));

  /// Whether the lookup of [host] was [record]ed less than [maxAge] before
  /// [now] (default: the current time).
  static bool isFresh(String host, {DateTime? now, Duration maxAge = ttl}) {
    final record = _records[_normalize(host)];
    if (record == null) return false;
    final age = (now ?? DateTime.now()).difference(record.at);
    return !age.isNegative && age < maxAge;
  }

  /// The addresses the lookup of a [isPrivate] [host] returned (all of them
  /// Tailscale's), in the order of the answer; empty for any other host.
  /// The app connects to one of them rather than resolving the name again.
  static List<String> addressesOf(String host) {
    final record = _records[_normalize(host)];
    return record != null && record.isPrivate ? record.addresses : const [];
  }

  /// Records that [host] resolves to [addresses] (IP literals) at [at]
  /// (default: now): it is private when there is at least one and all are
  /// Tailscale's. Names that are not [isTailnetName] are ignored.
  static void record(String host, Iterable<String> addresses, {DateTime? at}) {
    if (!isTailnetName(host)) return;
    final list = List<String>.unmodifiable(addresses.map((a) => a.trim()));
    _records[_normalize(host)] = _Record(
      addresses: list,
      isPrivate: list.isNotEmpty && list.every(isTailscaleAddress),
      at: at ?? DateTime.now(),
    );
  }

  /// Forgets what [record] learned about [host] (every host when null).
  static void forget([String? host]) {
    if (host == null) {
      _records.clear();
    } else {
      _records.remove(_normalize(host));
    }
  }

  /// Whether [address] (an IPv6 literal) is in fd7a:115c:a1e0::/48, the
  /// unique local range Tailscale gives its devices. Unlike 100.64.0.0/10,
  /// which mobile carriers use too (CGNAT), nothing else uses it.
  static bool isTailscaleUla(String address) {
    final groups = _ipv6(_bare(address).split('%').first);
    return groups != null &&
        groups[0] == 0xfd7a &&
        groups[1] == 0x115c &&
        groups[2] == 0xa1e0;
  }

  /// Whether [address] (an IPv4 or IPv6 literal) is in Tailscale's ranges:
  /// 100.64.0.0/10 (shared address space, which Tailscale uses for its
  /// devices) or fd7a:115c:a1e0::/48.
  static bool isTailscaleAddress(String address) {
    final a = _bare(address);
    final v4 = _ipv4(a);
    if (v4 != null) return v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127;
    final groups = _ipv6(a.split('%').first);
    if (groups == null) return false;
    // IPv4-mapped (::ffff:100.64.0.1).
    if (groups.sublist(0, 5).every((g) => g == 0) && groups[5] == 0xffff) {
      final b = groups[6] & 0xff;
      return groups[6] >> 8 == 100 && b >= 64 && b <= 127;
    }
    return groups[0] == 0xfd7a && groups[1] == 0x115c && groups[2] == 0xa1e0;
  }

  static final _hexGroup = RegExp(r'^[0-9a-f]{1,4}$');

  /// [address] trimmed, in lower case and without brackets.
  static String _bare(String address) {
    final a = address.trim().toLowerCase();
    return a.startsWith('[') && a.endsWith(']')
        ? a.substring(1, a.length - 1)
        : a;
  }

  static String _normalize(String host) {
    var h = host.trim().toLowerCase();
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    return h;
  }

  static List<int>? _ipv4(String text) {
    final parts = text.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return null;
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) return null;
      octets.add(n);
    }
    return octets;
  }

  /// The eight 16-bit groups of an IPv6 literal, or null.
  static List<int>? _ipv6(String text) {
    if (!text.contains(':')) return null;
    final halves = text.split('::');
    if (halves.length > 2) return null;
    List<int>? groups(String part) {
      if (part.isEmpty) return [];
      final result = <int>[];
      final pieces = part.split(':');
      for (var i = 0; i < pieces.length; i++) {
        final piece = pieces[i];
        if (i == pieces.length - 1 && piece.contains('.')) {
          final v4 = _ipv4(piece);
          if (v4 == null) return null;
          result
            ..add(v4[0] << 8 | v4[1])
            ..add(v4[2] << 8 | v4[3]);
          continue;
        }
        if (!_hexGroup.hasMatch(piece)) return null;
        result.add(int.parse(piece, radix: 16));
      }
      return result;
    }

    final head = groups(halves.first);
    if (head == null) return null;
    if (halves.length == 1) return head.length == 8 ? head : null;
    final tail = groups(halves.last);
    if (tail == null || head.length + tail.length > 7) return null;
    return [
      ...head,
      for (var i = head.length + tail.length; i < 8; i++) 0,
      ...tail,
    ];
  }
}

/// What a lookup of a Tailscale name answered, and when.
final class _Record {
  const new({
    required this.addresses,
    required this.isPrivate,
    required this.at,
  });

  final List<String> addresses;
  final bool isPrivate;
  final DateTime at;
}
