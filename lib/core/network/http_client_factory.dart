import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/core/network/http_client_factory_io.dart'
    if (dart.library.js_interop) 'package:mozhi/core/network/http_client_factory_web.dart'
    as platform;

/// The `User-Agent` of every request on native platforms: the app's name
/// only, without a version, the Dart version or anything about the device.
/// Browsers do not let the web app set it.
const appUserAgent = 'Mozhi';

/// How long connecting directly to a server (TCP and, for `https`, the TLS
/// handshake) may take on native platforms.
///
/// Well below the Mozhi request timeout (`MozhiApiClient.defaultTimeout`),
/// so that a server that drops packets fails as a connection error rather
/// than a request timeout. Nothing was sent then, so the request fails over
/// to the next Mozhi instance even when it carries the user's text, which a
/// timeout never does (`MozhiPool.canFailOver`).
const connectTimeout = Duration(seconds: 7);

/// [connectTimeout] for a client with a proxy. It covers the whole tunnel:
/// the connection to the proxy, its answer to `CONNECT` (Tor first has to
/// build a circuit to the server) and, for `https`, the TLS handshake with
/// the server through the tunnel (see `routeThroughProxy`), so a server
/// that never answers through the proxy fails as a connection error too.
const proxyConnectTimeout = Duration(seconds: 20);

/// How long a kept-alive connection may stay idle before it is closed on
/// native platforms (`dart:io` defaults to 15 s): a pause in typing does
/// not cost a new TCP and TLS handshake, which takes seconds through Tor.
const idleConnectionTimeout = Duration(seconds: 90);

/// Creates the HTTP client of the app. The one place where clients are
/// made: every translation backend shares one (see `NetworkSession`).
///
/// On Android (`dart:io`) it is a `dart:io` client that
/// * keeps no cookies (it has no cookie jar) and sends no `Referer`,
/// * sends `User-Agent:` [appUserAgent], gives up connecting after
///   [connectTimeout] ([proxyConnectTimeout] with a [proxy]) and keeps idle
///   connections open for [idleConnectionTimeout],
/// * ignores the `http_proxy` environment and the system proxy, and with
///   [proxy] (`host:port`, see [ProxyAddress.parse]) sends every request
///   through that HTTP proxy, except requests to this device and the
///   private network (which a proxy such as Tor could not reach); plain
///   `http` goes through a `CONNECT` tunnel too, the only method Tor's
///   HTTP tunnel port (Orbot's `127.0.0.1:8118`) accepts, and the
///   connection timeout covers opening the tunnel and the TLS handshake
///   through it.
///
/// A [proxy] that cannot be parsed never falls back to a direct connection:
/// the client then refuses every request with an [InvalidProxyException].
///
/// On the web it is the browser's `fetch` client: [proxy] is ignored (the
/// browser's own proxy applies), cross-origin requests carry no cookies, the
/// browser decides the `User-Agent`, and the page's referrer policy
/// (`no-referrer`, web/index.html) keeps it from sending a `Referer`.
http.Client createHttpClient({String? proxy}) =>
    platform.createPlatformHttpClient(proxy: proxy);

/// An HTTP proxy, `host:port`.
@immutable
class ProxyAddress {
  const new(this.host, this.port);

  /// Parses `host:port` (`127.0.0.1:8118`, `[::1]:8118`,
  /// `proxy.lan:3128`); an `http://` prefix and a trailing `/` are
  /// tolerated. Throws [FormatException] for anything else, including
  /// other schemes (SOCKS is not supported), user names, paths and a
  /// missing or out-of-range port.
  factory parse(String input) {
    var text = input.trim();
    final scheme = RegExp(
      '^([a-z][a-z0-9+.-]*)://',
      caseSensitive: false,
    ).firstMatch(text);
    if (scheme != null) {
      if (scheme[1]!.toLowerCase() != 'http') {
        throw FormatException('Only HTTP proxies are supported', input);
      }
      text = text.substring(scheme.end);
    }
    if (text.endsWith('/')) text = text.substring(0, text.length - 1);
    final Uri uri;
    try {
      uri = Uri.parse('http://$text');
    } on FormatException {
      throw FormatException('Not a proxy address (host:port)', input);
    }
    final validHost =
        uri.host.isNotEmpty &&
        (uri.host.contains(':') || _hostPattern.hasMatch(uri.host));
    if (!validHost ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw FormatException('Not a proxy address (host:port)', input);
    }
    return ProxyAddress(uri.host, uri.port);
  }

  static final _hostPattern = RegExp(r'^[a-z0-9_-]+(\.[a-z0-9_-]+)*$');

  /// Host name or IP address (IPv6 without brackets).
  final String host;
  final int port;

  /// `host:port`, with brackets around an IPv6 address.
  String get authority => host.contains(':') ? '[$host]:$port' : '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is ProxyAddress && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'ProxyAddress($authority)';
}

/// Thrown, before anything is sent, by a client whose proxy setting is
/// not a valid `host:port` (see [createHttpClient]).
class InvalidProxyException extends http.ClientException {
  new(Uri? uri) : super(defaultMessage, uri);

  /// The message, also used to recognise the error after a client wrapped
  /// it (see `NetworkPolicyError.of`).
  static const defaultMessage =
      'The proxy setting is not a valid host:port, so nothing is sent until '
      'it is fixed.';
}
