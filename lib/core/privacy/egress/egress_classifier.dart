import 'package:mozhi/core/privacy/egress/egress_entry.dart';
import 'package:translation_repository/translation_repository.dart';

/// Tells who receives a request and why, from its address and method.
///
/// It runs while the request is sent and keeps only the result: the path
/// and query (which may hold the user's text, as in Mozhi's text-to-speech)
/// are read here and then forgotten.
class EgressClassifier {
  const new();

  /// Cloud services by API host (subdomains included), named as their
  /// providers present themselves.
  static const cloudProviders = {
    'api.openai.com': 'OpenAI',
    'openai.azure.com': 'Azure OpenAI',
    'api.anthropic.com': 'Anthropic',
    'generativelanguage.googleapis.com': 'Google Gemini',
    'api.deepl.com': 'DeepL',
    'api-free.deepl.com': 'DeepL',
    'openrouter.ai': 'OpenRouter',
    'api.mistral.ai': 'Mistral AI',
    'api.groq.com': 'Groq',
    'api.together.xyz': 'Together AI',
    'api.together.ai': 'Together AI',
    'api.deepseek.com': 'DeepSeek',
    'api.x.ai': 'xAI',
    'api.perplexity.ai': 'Perplexity',
    'api.fireworks.ai': 'Fireworks AI',
    'api.cohere.com': 'Cohere',
    'api.cohere.ai': 'Cohere',
  };

  /// Where the on-device models come from (see the `catalog.json` of
  /// bergamot_translator, whisper_speech and tesseract_ocr): Mozilla's
  /// Firefox Translations models on Google Cloud Storage, Whisper on
  /// Hugging Face, Tesseract's language data on GitHub.
  static const modelHosts = {
    'storage.googleapis.com': 'Google Cloud Storage',
    'huggingface.co': 'Hugging Face',
    'hf.co': 'Hugging Face',
    'cdn-lfs.huggingface.co': 'Hugging Face',
    'cdn-lfs-us-1.huggingface.co': 'Hugging Face',
    'github.com': 'GitHub',
    'raw.githubusercontent.com': 'GitHub',
    'objects.githubusercontent.com': 'GitHub',
    'release-assets.githubusercontent.com': 'GitHub',
  };

  /// The destination and purpose of a request to [url] with [method].
  /// [purpose] overrides the guess (the web page translator's client
  /// knows it fetches web pages).
  (EgressDestination, EgressPurpose) classify(
    Uri url, {
    String method = 'GET',
    EgressPurpose? purpose,
  }) {
    final why = purpose ?? purposeOf(url, method: method);
    return (destinationOf(url, why), why);
  }

  /// The purpose of a request to [url], guessed from the endpoints of the
  /// app's backends (Mozhi, LibreTranslate, DeepL, the AI providers) and
  /// the model hosts.
  EgressPurpose purposeOf(Uri url, {String method = 'GET'}) {
    final host = normalizeHost(url.host);
    if (_lookUp(modelHosts, host) != null) return EgressPurpose.modelDownload;
    final path = url.path.toLowerCase();
    bool endsWithAny(List<String> suffixes) => suffixes.any(path.endsWith);
    final writes = const {
      'POST',
      'PUT',
      'PATCH',
    }.contains(method.toUpperCase());

    if (path.contains(':generatecontent') ||
        path.contains(':streamgeneratecontent') ||
        endsWithAny(const [
          '/chat/completions',
          '/completions',
          '/responses',
          '/messages',
          '/api/chat',
          '/api/generate',
        ])) {
      return EgressPurpose.aiModel;
    }
    if (endsWithAny(const ['/api/tts', '/tts'])) return EgressPurpose.speech;
    if (path.endsWith('/api/image')) return EgressPurpose.image;
    if (endsWithAny(const ['/translate', '/detect', '/document'])) {
      return EgressPurpose.translation;
    }
    if (path.contains('/glossaries')) {
      return writes ? EgressPurpose.translation : EgressPurpose.catalog;
    }
    if (endsWithAny(const [
          '/models',
          '/api/tags',
          '/api/show',
          '/api/version',
          '/api/engines',
          '/api/source_languages',
          '/api/target_languages',
          '/languages',
          '/usage',
          '/frontend/settings',
          '/glossary-language-pairs',
        ]) ||
        path.contains('/models/')) {
      return EgressPurpose.catalog;
    }
    return EgressPurpose.other;
  }

  /// The receiver of a request to [url] made for [purpose]: this device,
  /// the local network or Tor/I2P as `DataDestination` sees them
  /// ([DataDestination.forUrl]); otherwise a model host, a website, a
  /// known cloud provider or a public server.
  EgressDestination destinationOf(Uri url, EgressPurpose purpose) {
    final host = normalizeHost(url.host);
    final port = url.hasPort && url.port != _defaultPort(url.scheme)
        ? url.port
        : null;
    final cloud = _lookUp(cloudProviders, host);
    final base = DataDestination.forUrl(
      Uri(scheme: 'https', host: host).toString(),
      cloudProvider: cloud,
    );
    EgressDestination make(EgressDestinationKind kind, [String? name]) =>
        EgressDestination(kind: kind, host: host, port: port, name: name);

    if (base is SelfHostedDestination) {
      if (isLoopback(host)) return make(EgressDestinationKind.thisDevice);
      if (host.endsWith('.onion') || host.endsWith('.i2p')) {
        return make(EgressDestinationKind.hiddenService);
      }
      return make(EgressDestinationKind.localNetwork);
    }
    if (purpose == EgressPurpose.modelDownload) {
      return make(EgressDestinationKind.modelHost, _lookUp(modelHosts, host));
    }
    if (purpose == EgressPurpose.webPage) {
      return make(EgressDestinationKind.website);
    }
    if (cloud != null) return make(EgressDestinationKind.cloudProvider, cloud);
    return make(EgressDestinationKind.publicServer);
  }

  /// [host] in lower case, without a trailing dot or IPv6 brackets.
  static String normalizeHost(String host) {
    var name = host.trim().toLowerCase();
    if (name.endsWith('.')) name = name.substring(0, name.length - 1);
    if (name.startsWith('[') && name.endsWith(']')) {
      name = name.substring(1, name.length - 1);
    }
    return name;
  }

  /// Whether [host] is this device: `localhost`, `127.0.0.0/8` or `::1`.
  static bool isLoopback(String host) {
    final name = normalizeHost(host);
    return name == 'localhost' ||
        name.endsWith('.localhost') ||
        name.startsWith('127.') ||
        name == '::1' ||
        name == '0:0:0:0:0:0:0:1';
  }

  /// The value of [host] or of its closest parent domain in [table].
  static String? _lookUp(Map<String, String> table, String host) {
    var name = host;
    while (true) {
      final value = table[name];
      if (value != null) return value;
      final dot = name.indexOf('.');
      if (dot < 0) return null;
      name = name.substring(dot + 1);
    }
  }

  static int? _defaultPort(String scheme) => switch (scheme.toLowerCase()) {
    'https' => 443,
    'http' => 80,
    _ => null,
  };
}
