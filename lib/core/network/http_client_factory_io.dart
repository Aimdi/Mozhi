import 'dart:io';

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
  final client = HttpClient()
    ..userAgent = appUserAgent
    ..connectionTimeout = connectTimeout
    // Never the environment's or the system's proxy.
    ..findProxy = (_) => 'DIRECT';
  if (address != null) {
    routeThroughProxy(client, address, bypass: bypassesProxy);
  }
  return IOClient(client);
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
