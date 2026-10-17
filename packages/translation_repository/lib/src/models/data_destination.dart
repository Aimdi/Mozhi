import 'package:meta/meta.dart';
import 'package:translation_repository/src/models/ai_provider_config.dart';

/// Where the text of a translation request goes: the answer to "who can
/// read this?", shown next to every translation and asked about before
/// text leaves the device for the first time.
///
/// Every engine has one (`TranslationEngine` and the repository resolve
/// it); results carry the destination that actually answered (the Mozhi
/// pool may fail over to another instance).
@immutable
sealed class DataDestination {
  const new();

  /// The destination of a server at [url]: [SelfHostedDestination] for
  /// this machine and private networks ([isPrivateHost]), else
  /// [PublicInstanceDestination] (a public Mozhi or LibreTranslate server
  /// run by someone else) or, with [cloudProvider], a
  /// [CloudProviderDestination] named [cloudProvider].
  factory forUrl(String url, {String? engine, String? cloudProvider}) {
    final host = hostOf(url);
    if (isPrivateHost(host)) return SelfHostedDestination(host);
    if (cloudProvider != null) {
      return CloudProviderDestination(cloudProvider, host: host);
    }
    return PublicInstanceDestination(host, engine: engine);
  }

  /// Whether the text stays on this device.
  bool get isOnDevice => this is OnDeviceDestination;

  /// Whether the text is sent over the network (to any server, even one
  /// on the local network).
  bool get leavesDevice => !isOnDevice;

  /// Whether a third party (a public instance's operator or a cloud
  /// provider) receives the text, as opposed to the device or the user's
  /// own servers.
  bool get isThirdParty =>
      this is PublicInstanceDestination || this is CloudProviderDestination;

  /// Whether [host] (as in [Uri.host]) is this machine, a private network
  /// (RFC 1918, ULA, link-local, `.local`, ...), a Tor `.onion` or an I2P
  /// `.i2p` address: servers the user runs or reaches privately.
  static bool isPrivateHost(String host) {
    final h = host.trim().toLowerCase();
    if (h.endsWith('.onion') || h.endsWith('.i2p')) return true;
    return AiProviderConfig.isLocalHost(h);
  }

  /// The host of [url] (empty when [url] has none).
  static String hostOf(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return '';
    if (uri.host.isNotEmpty) return uri.host;
    // "example.org:8080" without a scheme parses the host as the scheme.
    return Uri.tryParse('https://${url.trim()}')?.host ?? '';
  }
}

/// The text stays on this device (offline engine).
final class OnDeviceDestination extends DataDestination {
  const new();

  @override
  bool operator ==(Object other) => other is OnDeviceDestination;

  @override
  int get hashCode => (OnDeviceDestination).hashCode;

  @override
  String toString() => 'OnDeviceDestination()';
}

/// A server on this machine or a private network (or reached through Tor
/// or I2P): the user's own Mozhi, LibreTranslate or local LLM.
final class SelfHostedDestination extends DataDestination {
  const new(this.host);

  final String host;

  @override
  bool operator ==(Object other) =>
      other is SelfHostedDestination && other.host == host;

  @override
  int get hashCode => Object.hash(SelfHostedDestination, host);

  @override
  String toString() => 'SelfHostedDestination($host)';
}

/// A public server run by someone else (a public Mozhi or LibreTranslate
/// instance). Its operator can read the text; for Mozhi, [engine] (e.g.
/// `google`) receives it too.
final class PublicInstanceDestination extends DataDestination {
  const new(this.host, {this.engine});

  final String host;

  /// The upstream engine the instance forwards the text to, if any.
  final String? engine;

  @override
  bool operator ==(Object other) =>
      other is PublicInstanceDestination &&
      other.host == host &&
      other.engine == engine;

  @override
  int get hashCode => Object.hash(PublicInstanceDestination, host, engine);

  @override
  String toString() => 'PublicInstanceDestination($host, $engine)';
}

/// A commercial cloud service (an AI provider such as OpenAI or Anthropic,
/// or DeepL's API), subject to its own privacy policy.
final class CloudProviderDestination extends DataDestination {
  const new(this.name, {this.host = ''});

  /// The provider's display name.
  final String name;

  /// The API host, when known.
  final String host;

  @override
  bool operator ==(Object other) =>
      other is CloudProviderDestination &&
      other.name == name &&
      other.host == host;

  @override
  int get hashCode => Object.hash(CloudProviderDestination, name, host);

  @override
  String toString() => 'CloudProviderDestination($name, $host)';
}

/// How willing the app is to send text over the network. Enforced by the
/// repository, not only by the UI.
enum PrivacyMode {
  /// Only on-device engines; every network translation is refused.
  offlineOnly,

  /// On-device when the language pair is installed; otherwise the user is
  /// asked once per pair (and destination) before text leaves the device.
  offlineFirst,

  /// The configured engines, in their order, without asking (cloud AI
  /// providers still need a one-time consent each).
  online,
}
