import 'dart:convert';

import 'package:cryptography/dart.dart';
import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// Which server an AI or translation provider sends to, for telling apart
/// two providers of the same id (on two devices, or before and after it
/// was removed): the same service, provider type and normalized base URL
/// ([normalizedProviderUrl]) make the same server.
abstract final class ProviderIdentity {
  /// Whether [a] and [b] send to the same server the same way.
  static bool sameServer(AiProviderConfig a, AiProviderConfig b) =>
      a.service == b.service &&
      a.provider == b.provider &&
      normalizedProviderUrl(a.baseUrl) == normalizedProviderUrl(b.baseUrl);

  /// The SHA-256 (hex) of [provider]'s server: equal for providers on the
  /// same server ([sameServer]), and it doesn't reveal the address (or a
  /// password in it) where it is stored.
  static String serverHash(AiProviderConfig provider) {
    final digest = const DartSha256().hashSync(
      utf8.encode(
        [
          provider.service.name,
          provider.provider.name,
          normalizedProviderUrl(provider.baseUrl),
        ].join('\n'),
      ),
    );
    return [
      for (final byte in digest.bytes) byte.toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// [url] normalized for [sameServer]: trimmed, `https://` added (or
  /// `http://` for a local host) when it has no scheme, as the clients
  /// do, scheme and host in lower case, without the default port, the
  /// fragment and trailing slashes. Empty for an empty [url] (a service's
  /// official API).
  static String normalizedProviderUrl(String url) {
    var text = url.trim();
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.isEmpty) return '';
    if (!text.contains('://')) {
      final host = Uri.tryParse('http://$text')?.host ?? '';
      text = '${AiProviderConfig.isLocalHost(host) ? 'http' : 'https'}://$text';
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority) return text;
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      userInfo: uri.userInfo,
      host: uri.host.toLowerCase(),
      port: uri.hasPort ? uri.port : null,
      path: path,
      query: uri.hasQuery ? uri.query : null,
    ).toString();
  }
}

/// An AI or translation provider removed from this device: its [id] and
/// the [ProviderIdentity.serverHash] of the server it sent to. A settings
/// merge never adds it back, and gives a provider of another server that
/// arrives with the same id an id of its own (`SettingsBackupSection`), so
/// that nothing still naming [id] (a choice of engine somewhere) picks up
/// a different provider.
class RemovedProvider extends Equatable {
  const new({required this.id, required this.server});

  /// Parses [toJson] output; null when it is invalid.
  static RemovedProvider? tryParse(Object? json) {
    if (json case {'id': final String id, 'server': final String server}
        when id.isNotEmpty && server.isNotEmpty) {
      return RemovedProvider(id: id, server: server);
    }
    return null;
  }

  final String id;
  final String server;

  Map<String, Object?> toJson() => {'id': id, 'server': server};

  @override
  List<Object?> get props => [id, server];
}
