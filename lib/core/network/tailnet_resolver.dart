import 'dart:async';

import 'package:mozhi/core/network/tailnet_lookup_io.dart'
    if (dart.library.js_interop) 'package:mozhi/core/network/tailnet_lookup_web.dart'
    as platform;
import 'package:translation_repository/translation_repository.dart';

/// Looks up Tailscale `.ts.net` names, so that they count as private only
/// when they lead to Tailscale's addresses ([TailnetHosts]): a name on a
/// tailnet resolves to 100.64.0.0/10 or fd7a:115c:a1e0::/48 and is reached
/// directly (a proxy such as Tor could not reach it), while a Tailscale
/// Funnel name resolves to public relays and is treated like any public
/// server (through the proxy, with consent and only over `https`).
///
/// [resolve] runs before every backend request to such a name
/// (`BackendHttpClient`) and before its connection picks the proxy or a
/// direct route (`routeThroughProxy`); `App` also looks up the configured
/// servers in advance, so that their destination is known before text is
/// sent. Until a lookup answered, and when it fails, the name is public.
///
/// The lookup goes to the system's resolver (Tailscale's MagicDNS when it
/// is on), never through the proxy: that resolver learns the name, as it
/// would for a connection without a proxy. In a browser nothing is looked
/// up (the name stays public).
class TailnetResolver {
  /// [lookup] returns the IP addresses (literals) of a host name; it
  /// defaults to the platform's resolver (none in a browser).
  /// A lookup that takes longer than [timeout] counts as failed.
  new({
    Future<List<String>> Function(String host)? lookup,
    this.timeout = const Duration(seconds: 5),
  }) : _lookup = lookup ?? platform.lookupAddresses;

  /// The resolver of this run of the app.
  static TailnetResolver instance = TailnetResolver();

  final Future<List<String>> Function(String host) _lookup;

  /// How long a lookup may take.
  final Duration timeout;
  final Map<String, Future<void>> _pending = {};

  /// Looks [host] up when it is a Tailscale name whose addresses are not
  /// known yet ([TailnetHosts.isKnown]) and records the answer. Never
  /// throws: a failed lookup records nothing (the name stays public and is
  /// looked up again next time). Lookups of the same name share one.
  Future<void> resolve(String host) {
    if (!TailnetHosts.isTailnetName(host) || TailnetHosts.isKnown(host)) {
      return Future.value();
    }
    final key = host.trim().toLowerCase();
    final pending = _pending[key];
    if (pending != null) return pending;
    final lookup = _record(host);
    _pending[key] = lookup;
    return lookup.whenComplete(() => _pending.remove(key));
  }

  Future<void> _record(String host) async {
    try {
      TailnetHosts.record(host, await _lookup(host).timeout(timeout));
    } on Object {
      // Unknown: public until a lookup succeeds.
    }
  }

  /// [resolve]s the hosts of [urls] (blank and invalid URLs are skipped).
  Future<void> resolveUrls(Iterable<String> urls) => Future.wait([
    for (final url in urls) resolve(DataDestination.hostOf(url)),
  ]);
}
