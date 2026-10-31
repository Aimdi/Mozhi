import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:mozhi/core/network/http_client_factory.dart';
import 'package:mozhi/core/network/http_proxy_tunnel.dart';
import 'package:translation_repository/translation_repository.dart';

/// The `dart:io` client; see `createHttpClient`.
http.Client createPlatformHttpClient({String? proxy}) {
  final setting = proxy?.trim() ?? '';
  final ProxyAddress? address;
  try {
    address = setting.isEmpty ? null : ProxyAddress.parse(setting);
  } on FormatException {
    return RefusingClient();
  }
  return IOClient(createIoHttpClient(proxy: address));
}

/// The `dart:io` [HttpClient] under the client of `createHttpClient`, with
/// [proxy] if any; its connections are opened by [routeConnections].
/// [connectionTimeout] replaces [connectTimeout] or [proxyConnectTimeout],
/// and [context] the system's TLS trust (tests).
@visibleForTesting
HttpClient createIoHttpClient({
  ProxyAddress? proxy,
  Duration? connectionTimeout,
  SecurityContext? context,
}) {
  final client = HttpClient(context: context)
    ..userAgent = appUserAgent
    ..connectionTimeout =
        connectionTimeout ??
        (proxy == null ? connectTimeout : proxyConnectTimeout)
    ..idleTimeout = idleConnectionTimeout
    // Never the environment's or the system's proxy.
    ..findProxy = (_) => 'DIRECT';
  // Also without a proxy: a Tailscale name on the tailnet is connected to
  // at the address its lookup checked (see routeConnections).
  routeConnections(
    client,
    proxy: proxy,
    bypass: bypassesProxy,
    context: context,
  );
  return client;
}

/// Whether requests to [host] skip the proxy: this device and the private
/// network ([DataDestination.isPrivateHost]) are out of a proxy's (Tor's)
/// reach, except Tor `.onion` and I2P `.i2p` names, which only the proxy
/// can resolve.
bool bypassesProxy(String host) {
  final name = host.toLowerCase();
  return DataDestination.isPrivateHost(name) &&
      !name.endsWith('.onion') &&
      !name.endsWith('.i2p');
}

/// A client that refuses every request with an [InvalidProxyException]:
/// with a broken proxy setting nothing may go out directly instead.
class RefusingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      throw InvalidProxyException(request.url.removeFragment());
}
