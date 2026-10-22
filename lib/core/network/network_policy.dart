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

/// A redirect that [BackendHttpClient] does not follow, refused before
/// anything was sent to its target.
class RedirectRefusedException extends http.ClientException {
  /// From `https` to plain `http`.
  new downgrade(Uri? uri) : super(downgradeMessage, uri);

  /// From a public server to this device, the local network or a `.onion`
  /// or `.i2p` address, or from a `.onion` or `.i2p` server to this device
  /// or the local network.
  new intoPrivateNetwork(Uri? uri) : super(privateNetworkMessage, uri);

  /// To an address that is not `http` or `https`, or has no host.
  new unsupported(Uri? uri) : super(unsupportedMessage, uri);

  /// The message of [RedirectRefusedException.downgrade]; it starts with
  /// [marker], like the others.
  static const downgradeMessage =
      '$marker: a server redirected from https to plain http.';

  /// The message of [RedirectRefusedException.intoPrivateNetwork].
  static const privateNetworkMessage =
      '$marker: a server outside your network redirected to this device, '
      'your local network or a .onion or .i2p address.';

  /// The message of [RedirectRefusedException.unsupported].
  static const unsupportedMessage =
      '$marker: a server redirected to an address that is not http or https.';

  /// How the error is recognised after a client wrapped it.
  static const marker = 'Redirect refused';
}

/// The [http.Client] of the translation backends and the downloads: applies
/// its [NetworkPolicy] to every request (before it is sent, so a refused
/// request never leaves the device) and strips `Cookie` and `Referer`
/// headers, then hands the request to the wrapped client.
///
/// On native platforms it also follows the redirects of GET and HEAD
/// requests that ask for that (`followRedirects`, the default of
/// `http.Request`: the model and dictionary downloads), instead of leaving
/// them to `dart:io`, which would follow any scheme and host unchecked.
/// Each hop is a new request through the wrapped client (so the egress
/// ledger lists every hop), with the same method and headers except
/// `Authorization`, which is dropped once the origin changes; the body of
/// each redirect is drained. Every target (`Location`, resolved against the
/// current URL, without fragment and user info) must pass [policy], and a
/// [RedirectRefusedException] refuses
/// * a scheme other than `http` and `https`,
/// * a downgrade from `https` to `http`,
/// * a hop from a public server to a private host
///   ([DataDestination.isPrivateHost]: this device, the local network, a
///   Tailscale name, `.onion` or `.i2p`), or from a `.onion` or `.i2p`
///   server to this device or the local network: such hosts are reached
///   around the proxy, so the redirect would probe the user's network or
///   reveal their address.
///
/// Redirects to other public `https` servers are followed (download hosts
/// hand files to their CDNs), at most the request's `maxRedirects` times;
/// one more fails with `Redirect limit exceeded`. A redirect without a
/// usable `Location` is returned as it is. After a redirect the response is
/// that of the last hop: its `request` is that hop's request and it is an
/// [http.BaseResponseWithUrl] with that hop's URL.
///
/// Other requests (POST, `followRedirects: false`, which the backend
/// clients use to follow redirects manually or not at all) pass through
/// unchanged; `dart:io` never follows a POST by itself. In a browser
/// everything passes through: `fetch` follows redirects itself, cannot hand
/// them over, and refuses `https` pages loading plain `http`.
class BackendHttpClient extends http.BaseClient {
  new(this._inner, {required this.policy});

  final http.Client _inner;
  final NetworkPolicy policy;

  /// Headers that are never sent to a backend.
  static const strippedHeaders = ['cookie', 'cookie2', 'referer'];

  /// Statuses after which a GET or HEAD request is sent again to
  /// `Location`, as `dart:io` would.
  static const redirectStatuses = {301, 302, 303, 307, 308};

  /// The methods whose redirects are followed here.
  static const _redirectedMethods = {'GET', 'HEAD'};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    policy.check(request.url);
    // BaseRequest.headers ignores the case of names.
    strippedHeaders.forEach(request.headers.remove);
    if (kIsWeb ||
        !request.followRedirects ||
        !_redirectedMethods.contains(request.method)) {
      return await _inner.send(request);
    }
    return await _sendFollowingRedirects(request);
  }

  /// Sends [request] without letting the wrapped client follow redirects,
  /// and follows them here, checking every hop.
  Future<http.StreamedResponse> _sendFollowingRedirects(
    http.BaseRequest request,
  ) async {
    final limit = request.maxRedirects;
    final headers = Map.of(request.headers);
    final abortTrigger = switch (request) {
      http.Abortable(:final abortTrigger) => abortTrigger,
      _ => null,
    };
    var hop = request..followRedirects = false;
    for (var redirects = 0; ; redirects++) {
      final response = await _inner.send(hop);
      final target = redirectStatuses.contains(response.statusCode)
          ? _location(hop.url, response.headers['location'])
          : null;
      if (target == null) {
        return redirects == 0 ? response : _RedirectedResponse(response, hop);
      }
      await response.stream.drain<void>();
      if (redirects >= limit) {
        throw http.ClientException('Redirect limit exceeded', _redact(hop.url));
      }
      _checkRedirect(hop.url, target);
      if (!_isSameOrigin(hop.url, target)) {
        headers.removeWhere((name, _) => name.toLowerCase() == 'authorization');
      }
      hop =
          (abortTrigger == null
                ? http.Request(request.method, target)
                : http.AbortableRequest(
                    request.method,
                    target,
                    abortTrigger: abortTrigger,
                  ))
            ..followRedirects = false
            ..persistentConnection = request.persistentConnection
            ..headers.addAll(headers);
    }
  }

  /// Throws when a redirect from [from] to [to] must not be followed: the
  /// [policy]'s exceptions, or a [RedirectRefusedException].
  void _checkRedirect(Uri from, Uri to) {
    if (!(to.isScheme('http') || to.isScheme('https')) || to.host.isEmpty) {
      throw RedirectRefusedException.unsupported(_redact(to));
    }
    policy.check(to);
    if (from.isScheme('https') && to.isScheme('http')) {
      throw RedirectRefusedException.downgrade(_redact(to));
    }
    final intoPrivate =
        DataDestination.isPrivateHost(to.host) &&
        !DataDestination.isPrivateHost(from.host);
    final intoLocal = _isLocal(to.host) && isHiddenServiceHost(from.host);
    if (intoPrivate || intoLocal) {
      throw RedirectRefusedException.intoPrivateNetwork(_redact(to));
    }
  }

  /// Whether [host] is this device or the local network, reached around a
  /// proxy (unlike `.onion` and `.i2p`, which only a proxy reaches).
  static bool _isLocal(String host) =>
      DataDestination.isPrivateHost(host) && !isHiddenServiceHost(host);

  /// [location] resolved against [url], without fragment and user info, or
  /// null when it is blank or not a URL.
  static Uri? _location(Uri url, String? location) {
    final trimmed = location?.trim() ?? '';
    final reference = trimmed.isEmpty ? null : Uri.tryParse(trimmed);
    if (reference == null) return null;
    final target = url.resolveUri(reference).removeFragment();
    return target.userInfo.isEmpty ? target : target.replace(userInfo: '');
  }

  static bool _isSameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  @override
  void close() => _inner.close();
}

/// The response of the last hop of a request [BackendHttpClient] followed
/// through redirects: [request] is that hop's request and [url] its URL.
class _RedirectedResponse extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  new(http.StreamedResponse response, http.BaseRequest hop)
    : url = hop.url,
      super(
        response.stream,
        response.statusCode,
        contentLength: response.contentLength,
        request: hop,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );

  @override
  final Uri url;
}

/// The [http.Client] of the web page translator: a website the user asked
/// for is fetched as a browser would, plain `http` included, but a Tor
/// `.onion` or I2P `.i2p` address without a proxy is refused before it is
/// looked up ([ProxyRequiredException], as for the backends), and `Cookie`
/// and `Referer` headers are stripped. [close] does nothing: the owner of
/// the wrapped client (`NetworkSession`) closes it.
class WebsiteHttpClient extends http.BaseClient {
  new(this._inner, {required this.policy});

  final http.Client _inner;

  /// Only its proxy rule for `.onion` and `.i2p` applies.
  final NetworkPolicy policy;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (policy.hiddenServicesNeedProxy &&
        !policy.hasProxy &&
        isHiddenServiceHost(request.url.host)) {
      throw ProxyRequiredException(_redact(request.url));
    }
    BackendHttpClient.strippedHeaders.forEach(request.headers.remove);
    return await _inner.send(request);
  }

  @override
  void close() {}
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
  invalidProxy,

  /// A download's redirect that [BackendHttpClient] does not follow
  /// ([RedirectRefusedException]: https to http, into the private network,
  /// another scheme).
  redirectRefused;

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
    if (text.contains(RedirectRefusedException.marker)) return redirectRefused;
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
      NetworkPolicyError.redirectRefused => l10n.commonErrorRedirectRefused,
      null => null,
    };
