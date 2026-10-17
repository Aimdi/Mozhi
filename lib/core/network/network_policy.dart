import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mozhi/core/network/http_client_factory.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// Whether plain `http` to [uri] is acceptable: only for this device, the
/// private network, Tor `.onion` and I2P `.i2p` hosts
/// ([DataDestination.isPrivateHost]). Anything else must use `https`.
/// Always true for other schemes.
bool isCleartextAllowed(Uri uri) =>
    !uri.isScheme('http') || DataDestination.isPrivateHost(uri.host);

/// Whether [host] is a Tor `.onion` or I2P `.i2p` name, which only a proxy
/// can reach.
bool isHiddenServiceHost(String host) {
  var name = host.trim().toLowerCase();
  if (name.endsWith('.')) name = name.substring(0, name.length - 1);
  return name.endsWith('.onion') || name.endsWith('.i2p');
}

/// The rules every request to a translation backend (Mozhi, LibreTranslate,
/// DeepL, AI providers) follows. Applied by [BackendHttpClient] before
/// anything is sent; not meant for clients that fetch arbitrary websites.
@immutable
class NetworkPolicy {
  /// [hasProxy]: whether an HTTP proxy is configured for this session.
  /// [hiddenServicesNeedProxy]: whether `.onion` and `.i2p` hosts need one
  /// (false in a browser, which may reach them itself, e.g. Tor Browser).
  const new({required this.hasProxy, this.hiddenServicesNeedProxy = true});

  final bool hasProxy;
  final bool hiddenServicesNeedProxy;

  /// Throws, for a request to [url] that the rules forbid:
  /// * [ProxyRequiredException] for a `.onion` / `.i2p` host without a
  ///   proxy (it could not be resolved, and trying would leak the name to
  ///   the DNS resolver);
  /// * [CleartextRefusedException] for plain `http` to a public host.
  void check(Uri url) {
    if (hiddenServicesNeedProxy && !hasProxy && isHiddenServiceHost(url.host)) {
      throw ProxyRequiredException(_redact(url));
    }
    if (!isCleartextAllowed(url)) {
      throw CleartextRefusedException(_redact(url));
    }
  }

  @override
  bool operator ==(Object other) =>
      other is NetworkPolicy &&
      other.hasProxy == hasProxy &&
      other.hiddenServicesNeedProxy == hiddenServicesNeedProxy;

  @override
  int get hashCode => Object.hash(hasProxy, hiddenServicesNeedProxy);
}

/// [url] without user info, query and fragment (they may hold credentials
/// or the user's text).
Uri _redact(Uri url) => Uri(
  scheme: url.scheme,
  host: url.host,
  port: url.hasPort ? url.port : null,
  path: url.path,
);

/// Plain `http` to a public server, refused before anything was sent.
class CleartextRefusedException extends http.ClientException {
  new(Uri? uri) : super(defaultMessage, uri);

  /// The message; it starts with [marker].
  static const defaultMessage =
      '$marker: plain http is only allowed for this device, the local '
      'network and .onion or .i2p addresses.';

  /// How the error is recognised after a client wrapped it.
  static const marker = 'Use https for public servers';
}

/// A Tor `.onion` or I2P `.i2p` address without a proxy, refused before
/// anything was sent (or looked up).
class ProxyRequiredException extends http.ClientException {
  new(Uri? uri) : super(defaultMessage, uri);

  /// The message; it starts with [marker].
  static const defaultMessage =
      '$marker: set an HTTP proxy such as Orbot (127.0.0.1:8118) to reach '
      'this address.';

  /// How the error is recognised after a client wrapped it.
  static const marker = 'Tor and I2P addresses need a proxy';
}

/// The [http.Client] of the translation backends: applies its
/// [NetworkPolicy] to every request (before it is sent, so a refused
/// request never leaves the device) and strips `Cookie` and `Referer`
/// headers, then hands the request to the wrapped client.
///
/// Redirects are not seen here when the wrapped client follows them; the
/// backend clients follow theirs manually (or not at all) on native
/// platforms, so every hop is checked.
class BackendHttpClient extends http.BaseClient {
  new(this._inner, {required this.policy});

  final http.Client _inner;
  final NetworkPolicy policy;

  /// Headers that are never sent to a backend.
  static const strippedHeaders = ['cookie', 'cookie2', 'referer'];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    policy.check(request.url);
    // BaseRequest.headers ignores the case of names.
    strippedHeaders.forEach(request.headers.remove);
    return await _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// Why a request was refused by the [NetworkPolicy] or by a broken proxy
/// setting.
enum NetworkPolicyError {
  /// Plain `http` to a public server ([CleartextRefusedException]).
  cleartext,

  /// `.onion` / `.i2p` without a proxy ([ProxyRequiredException]).
  proxyRequired,

  /// The proxy setting is not a valid `host:port`
  /// ([InvalidProxyException]).
  invalidProxy;

  /// The policy error behind [error], or null. Also recognises the errors
  /// after a backend client wrapped them (`MozhiApiException`,
  /// `LlmApiException`, `MtApiException`), which keep the message.
  static NetworkPolicyError? of(Object? error) {
    if (error == null) return null;
    final text = switch (error) {
      MozhiApiException(:final message) => message,
      LlmApiException(:final message) => message,
      MtApiException(:final message, :final detail) => '$message $detail',
      http.ClientException(:final message) => message,
      _ => error.toString(),
    };
    if (text.contains(CleartextRefusedException.marker)) return cleartext;
    if (text.contains(ProxyRequiredException.marker)) return proxyRequired;
    if (text.contains(InvalidProxyException.defaultMessage)) {
      return invalidProxy;
    }
    return null;
  }
}

/// The localised message for a [NetworkPolicyError] behind [error], or
/// null when [error] is something else. Error presenters call this first.
String? describeNetworkPolicyError(AppLocalizations l10n, Object? error) =>
    switch (NetworkPolicyError.of(error)) {
      NetworkPolicyError.cleartext => l10n.commonErrorCleartextRefused,
      NetworkPolicyError.proxyRequired => l10n.commonErrorProxyRequired,
      NetworkPolicyError.invalidProxy => l10n.commonErrorInvalidProxy,
      null => null,
    };
