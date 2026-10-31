import 'dart:async';

import 'package:mozhi/core/network/tailnet_lookup_io.dart'
    if (dart.library.js_interop) 'package:mozhi/core/network/tailnet_lookup_web.dart'
    as platform;
import 'package:translation_repository/translation_repository.dart';

/// A network interface of the device: its name and its addresses (IP
/// literals), as `NetworkInterface.list` gives them.
typedef LocalInterface = ({String name, List<String> addresses});

/// Looks up Tailscale `.ts.net` names, so that they count as private only
/// when they lead to Tailscale's addresses ([TailnetHosts]) while the
/// device is on its tailnet: a name on a tailnet resolves to 100.64.0.0/10
/// or fd7a:115c:a1e0::/48 and is reached directly (a proxy such as Tor
/// could not reach it), while a Tailscale Funnel name resolves to public
/// relays and is treated like any public server (through the proxy, with
/// consent and only over `https`).
///
/// A lookup's answer proves little by itself: once Tailscale is off, the
/// network's resolver answers for `ts.net` and may give any address, and
/// 100.64.0.0/10 is also what mobile carriers use (CGNAT). So [resolve]
/// first checks that the device has a Tailscale interface
/// ([hasTailscaleInterface], at most every [interfaceMaxAge]): without
/// one, nothing is looked up and every name is public. Whenever the
/// Tailscale addresses of the device change (Tailscale turned on or off,
/// another tailnet), every record is forgotten. A record is looked up
/// again once it is older than [ttl], and a failed lookup forgets it.
///
/// [resolve] runs before every backend request to such a name
/// (`BackendHttpClient`, `WebsiteHttpClient`) and in the connection
/// factory of every `dart:io` client (`routeConnections`), which then
/// connects to the very address that was checked ([connectAddress])
/// instead of resolving the name again. `App` also looks up the
/// configured servers in advance, so that their destination is known
/// before text is sent. Until a lookup answered, and when it fails, the
/// name is public.
///
/// The lookup goes to the system's resolver (Tailscale's MagicDNS when it
/// is on), never through the proxy: that resolver learns the name, as it
/// would for a connection without a proxy. In a browser nothing is looked
/// up (there is no interface to check, and the name stays public).
class TailnetResolver {
  /// [lookup] returns the IP addresses (literals) of a host name and
  /// [interfaces] the device's network interfaces; they default to the
  /// platform's (none in a browser). A lookup or interface listing that
  /// takes longer than [timeout] counts as failed. [clock] tells the time
  /// (tests).
  new({
    Future<List<String>> Function(String host)? lookup,
    Future<List<LocalInterface>> Function()? interfaces,
    this.timeout = const Duration(seconds: 5),
    this.interfaceMaxAge = const Duration(seconds: 2),
    this.ttl = TailnetHosts.ttl,
    DateTime Function()? clock,
  }) : _lookup = lookup ?? platform.lookupAddresses,
       _interfaces = interfaces ?? platform.listInterfaces,
       _clock = clock ?? DateTime.now;

  /// The resolver of this run of the app.
  static TailnetResolver instance = TailnetResolver();

  final Future<List<String>> Function(String host) _lookup;
  final Future<List<LocalInterface>> Function() _interfaces;
  final DateTime Function() _clock;

  /// How long a lookup may take.
  final Duration timeout;

  /// How long the answer of the interface check is used.
  final Duration interfaceMaxAge;

  /// How long a lookup's answer is used before the name is looked up
  /// again.
  final Duration ttl;

  final Map<String, Future<void>> _pending = {};
  _InterfaceCheck? _check;
  Future<_InterfaceCheck>? _checking;

  /// Counts the changes of the device's Tailscale addresses: an answer to
  /// a lookup started before a change is dropped.
  int _generation = 0;

  /// Whether [interfaces] include a Tailscale interface: one with an
  /// address in fd7a:115c:a1e0::/48 ([TailnetHosts.isTailscaleUla], which
  /// only Tailscale uses; on Android its interface is a `tun`), or one
  /// whose name starts with `tailscale` and has an address in
  /// 100.64.0.0/10. Such an address on any other interface (a carrier's
  /// CGNAT address on the mobile data interface) does not count.
  static bool hasTailscaleInterface(List<LocalInterface> interfaces) =>
      _tailscaleAddresses(interfaces).isNotEmpty;

  /// The Tailscale addresses of [interfaces] (see [hasTailscaleInterface]),
  /// sorted.
  static List<String> _tailscaleAddresses(List<LocalInterface> interfaces) {
    final found = <String>{};
    for (final interface in interfaces) {
      final named = interface.name.toLowerCase().startsWith('tailscale');
      for (final address in interface.addresses) {
        if (TailnetHosts.isTailscaleUla(address) ||
            (named && TailnetHosts.isTailscaleAddress(address))) {
          found.add(address.toLowerCase());
        }
      }
    }
    return found.toList()..sort();
  }

  /// Looks [host] up when it is a Tailscale name, the device has a
  /// Tailscale interface and the last lookup of [host] is older than [ttl]
  /// (or there is none), and records the answer. Without a Tailscale
  /// interface nothing is looked up. Never throws: a failed lookup forgets
  /// [host] (the name is public and is looked up again next time). Lookups
  /// of the same name share one.
  Future<void> resolve(String host) {
    if (!TailnetHosts.isTailnetName(host)) return Future.value();
    final key = host.trim().toLowerCase();
    final pending = _pending[key];
    if (pending != null) return pending;
    final lookup = _resolve(host);
    _pending[key] = lookup;
    return lookup.whenComplete(() => _pending.remove(key));
  }

  Future<void> _resolve(String host) async {
    final check = await _currentCheck();
    if (!check.up) {
      // Nothing to trust without Tailscale (and nothing recorded since
      // the change, which forgot every record).
      TailnetHosts.forget(host);
      return;
    }
    if (TailnetHosts.isFresh(host, now: _clock(), maxAge: ttl)) return;
    final generation = _generation;
    try {
      final addresses = await _lookup(host).timeout(timeout);
      if (generation == _generation) {
        TailnetHosts.record(host, addresses, at: _clock());
      }
    } on Object {
      // Unknown: public until a lookup succeeds.
      if (generation == _generation) TailnetHosts.forget(host);
    }
  }

  /// The interface check, made again once it is older than
  /// [interfaceMaxAge]. Checks running at once share one.
  Future<_InterfaceCheck> _currentCheck() {
    final check = _check;
    if (check != null) {
      final age = _clock().difference(check.at);
      if (!age.isNegative && age < interfaceMaxAge) return Future.value(check);
    }
    return _checking ??= _checkInterfaces().whenComplete(
      () => _checking = null,
    );
  }

  Future<_InterfaceCheck> _checkInterfaces() async {
    List<LocalInterface> interfaces;
    try {
      interfaces = await _interfaces().timeout(timeout);
    } on Object {
      interfaces = const [];
    }
    final next = _InterfaceCheck(_tailscaleAddresses(interfaces), _clock());
    final previous = _check;
    _check = next;
    if (previous == null || previous.signature != next.signature) {
      // Answers learned on another network (or before any check) are not
      // trusted on this one.
      _generation++;
      TailnetHosts.forget();
    }
    return next;
  }

  /// The address to connect to for [host], or null when [host] is not a
  /// private Tailscale name ([TailnetHosts.isPrivate]) while the last
  /// interface check found a Tailscale interface: one of the addresses
  /// its lookup returned (all of them Tailscale's), an fd7a:115c:a1e0::/48
  /// one first when the device has such an address (only Tailscale routes
  /// it), else a 100.64.0.0/10 one. Connecting there instead of resolving
  /// the name again keeps another answer from moving the connection.
  String? connectAddress(String host) {
    final check = _check;
    if (check == null || !check.up || !TailnetHosts.isPrivate(host)) {
      return null;
    }
    final addresses = TailnetHosts.addressesOf(host);
    if (addresses.isEmpty) return null;
    final preferred = addresses.where(
      (address) => TailnetHosts.isTailscaleUla(address) == check.hasUla,
    );
    return preferred.isEmpty ? addresses.first : preferred.first;
  }

  /// [resolve]s the hosts of [urls] (blank and invalid URLs are skipped).
  Future<void> resolveUrls(Iterable<String> urls) => Future.wait([
    for (final url in urls) resolve(DataDestination.hostOf(url)),
  ]);
}

/// What an interface check found: the device's Tailscale [addresses]
/// (none without a Tailscale interface), at [at].
final class _InterfaceCheck {
  new(this.addresses, this.at)
    : hasUla = addresses.any(TailnetHosts.isTailscaleUla);

  final List<String> addresses;
  final DateTime at;
  final bool hasUla;

  bool get up => addresses.isNotEmpty;

  String get signature => addresses.join(',');
}
