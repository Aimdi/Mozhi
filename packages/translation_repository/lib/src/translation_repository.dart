import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:mt_api/mt_api.dart';
import 'package:translation_repository/src/cache/metadata_store.dart';
import 'package:translation_repository/src/cache/persisted_metadata.dart';
import 'package:translation_repository/src/cache/translation_cache.dart';
import 'package:translation_repository/src/chunking/chunked_translation.dart';
import 'package:translation_repository/src/chunking/paragraph_chunker.dart';
import 'package:translation_repository/src/language_catalog.dart';
import 'package:translation_repository/src/language_matcher.dart';
import 'package:translation_repository/src/models/models.dart';
import 'package:translation_repository/src/offline/offline_requests.dart';
import 'package:translation_repository/src/offline/offline_translator.dart';
import 'package:translation_repository/src/prompts/mt_prompts.dart';
import 'package:translation_repository/src/prompts/response_parsers.dart';
import 'package:translation_repository/src/prompts/translation_prompts.dart';
import 'package:translation_repository/src/quality/personal_data.dart';
import 'package:translation_repository/src/quality/text_masker.dart';
import 'package:translation_repository/src/quality/translation_qa.dart';
import 'package:translation_repository/src/repository/ai_translation_stream.dart';
import 'package:translation_repository/src/repository/llm_pool.dart';
import 'package:translation_repository/src/repository/mappers.dart';
import 'package:translation_repository/src/repository/mozhi_pool.dart';
import 'package:translation_repository/src/repository/mt_engines.dart';
import 'package:translation_repository/src/repository/offline_engine.dart';
import 'package:translation_repository/src/repository/repository_exceptions.dart';

typedef MozhiClientFactory = MozhiApiClient Function(Uri baseUrl);
typedef LlmClientFactory = LlmClient Function(LlmEndpoint endpoint);

/// Creates the DeepL client of a [MtService.deepl] provider.
typedef DeeplClientFactory = DeeplClient Function(AiProviderConfig config);

/// Creates the LibreTranslate client of a [MtService.libreTranslate]
/// provider.
typedef LibreTranslateClientFactory = LibreTranslateClient Function(
  AiProviderConfig config,
);

/// The single entry point the app uses for anything translation related.
///
/// Configuration is pushed by the app whenever settings change
/// ([updateConfiguration]). Mozhi requests go to the first reachable
/// instance in [instances] order: on a failure another instance might not
/// repeat (network errors, timeouts, 3xx/4xx from a proxy, 429, 5xx that
/// are not Mozhi input errors) the next instance is tried and, on success,
/// becomes the preferred one ([activeInstance]) until the instance order
/// changes or [resetActiveInstance] is called. Requests that carry the
/// user's text or image are not re-sent after a timeout, because the slow
/// instance may already have received them.
///
/// Language lists and engine lists are cached in memory per instance+engine
/// (keyed by the instance that answered; cleared by [updateConfiguration]
/// when instances change, or `refresh: true`). With a [MetadataStore] they
/// are also persisted (see [getEngines]): a stored list is served at once
/// and revalidated in the background, and [metadataChanged] fires when the
/// revalidated list differs. Final translations are
/// cached in a [TranslationCache] ([clearCache]); a provider's entries are
/// dropped whenever its configuration changes.
class TranslationRepository {
  /// [mozhiClientFactory] / [llmClientFactory] / [deeplClientFactory] /
  /// [libreTranslateClientFactory] create the HTTP clients (defaults:
  /// `MozhiApiClient(baseUrl: ...)`, `LlmClient(endpoint)`,
  /// `DeeplClient(authKey: apiKey, baseUrl: ...)`,
  /// `LibreTranslateClient(baseUrl: ..., apiKey: ...)`). Clients are cached
  /// per Mozhi instance URL and per provider connection settings.
  ///
  /// [offline] enables the on-device engine ([TranslationEngine.offline])
  /// when it [OfflineTranslator.isAvailable]; it is also used to identify
  /// the source language privately where a detection is needed.
  ///
  /// [cache] stores final results (default: a [TranslationCache] with its
  /// default size and lifetime; pass `TranslationCache(maxEntries: 0)` to
  /// disable caching).
  ///
  /// `snapshotInterval` throttles intermediate AI streaming snapshots.
  ///
  /// AI inputs longer than `aiChunkThreshold` characters
  /// (`localAiChunkThreshold` for providers on this machine or the local
  /// network, whose models usually have small context windows, and
  /// `onDeviceAiChunkThreshold` for models on this device
  /// ([AiProviderConfig.isOnDevice]), which run with a small context to
  /// spare the phone's memory) are translated in parts of at most that size
  /// (see [translate]); all must be at least 1 ([RangeError] otherwise).
  ///
  /// `detectionHintTimeout` is how long the final result of a short
  /// auto-detected AI translation may wait for the second language
  /// detection (see [translate]).
  ///
  /// [metadataStore] persists the Mozhi engine and language lists across
  /// launches (none by default); stored lists older than [metadataMaxAge]
  /// are ignored. [clock] (default [DateTime.now]) timestamps them (and
  /// expires [allowOnce] approvals).
  ///
  /// The privacy settings start strict ([PrivacyMode.offlineFirst], no
  /// approved pairs, no consented providers) until [updatePrivacy] is
  /// called.
  new({
    MozhiClientFactory? mozhiClientFactory,
    LlmClientFactory? llmClientFactory,
    DeeplClientFactory? deeplClientFactory,
    LibreTranslateClientFactory? libreTranslateClientFactory,
    OfflineTranslator? offline,
    TranslationCache? cache,
    this._snapshotInterval = const Duration(milliseconds: 50),
    this._aiChunkThreshold = defaultAiChunkThreshold,
    this._localAiChunkThreshold = defaultLocalAiChunkThreshold,
    this._onDeviceAiChunkThreshold = defaultOnDeviceAiChunkThreshold,
    this._detectionHintTimeout = defaultDetectionHintTimeout,
    MetadataStore? metadataStore,
    Duration metadataMaxAge = defaultMetadataMaxAge,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _metadata = metadataStore == null
           ? null
           : PersistedMetadata(
               metadataStore,
               maxAge: metadataMaxAge,
               clock: clock ?? DateTime.now,
             ),
       _mozhi = MozhiPool(mozhiClientFactory ?? _defaultMozhiClient),
       _llm = LlmPool(llmClientFactory ?? _defaultLlmClient),
       _mt = MtEngines(
         deepl: deeplClientFactory,
         libre: libreTranslateClientFactory,
       ),
       _offline = offline == null ? null : OfflineEngine(offline),
       _cache = cache ?? TranslationCache() {
    if (_aiChunkThreshold < 1) {
      throw RangeError.value(_aiChunkThreshold, 'aiChunkThreshold');
    }
    if (_localAiChunkThreshold < 1) {
      throw RangeError.value(_localAiChunkThreshold, 'localAiChunkThreshold');
    }
    if (_onDeviceAiChunkThreshold < 1) {
      throw RangeError.value(
        _onDeviceAiChunkThreshold,
        'onDeviceAiChunkThreshold',
      );
    }
  }

  /// Default `aiChunkThreshold`: AI inputs of cloud providers longer than
  /// this many characters are translated in parts.
  static const defaultAiChunkThreshold = 6000;

  /// Default `localAiChunkThreshold`: AI inputs of local providers longer
  /// than this many characters are translated in parts.
  static const defaultLocalAiChunkThreshold = 2500;

  /// Default `onDeviceAiChunkThreshold`: AI inputs of models on this device
  /// longer than this many characters are translated in parts. Their
  /// context is about 4096 tokens for the prompt and the reply together,
  /// and text in scripts without spaces takes up to a token per character:
  /// a part, its instructions and its translation fit.
  static const defaultOnDeviceAiChunkThreshold = 1200;

  /// Default `detectionHintTimeout`.
  static const defaultDetectionHintTimeout = Duration(seconds: 2);

  /// Default `metadataMaxAge`: how long persisted engine and language lists
  /// may be served (e.g. while offline).
  static const defaultMetadataMaxAge = Duration(days: 7);

  static MozhiApiClient _defaultMozhiClient(Uri baseUrl) =>
      MozhiApiClient(baseUrl: baseUrl);

  static LlmClient _defaultLlmClient(LlmEndpoint endpoint) =>
      LlmClient(endpoint);

  final MozhiPool _mozhi;
  final LlmPool _llm;
  final MtEngines _mt;
  final OfflineEngine? _offline;
  final TranslationCache _cache;

  /// Translations of the parts of long AI inputs (see [translate]).
  final MemoryChunkCache _chunkCache = MemoryChunkCache();
  final Duration _snapshotInterval;
  final int _aiChunkThreshold;
  final int _localAiChunkThreshold;
  final int _onDeviceAiChunkThreshold;
  final Duration _detectionHintTimeout;
  final DateTime Function() _clock;
  List<AiProviderConfig> _providers = const [];

  PrivacyMode _privacyMode = PrivacyMode.offlineFirst;
  Set<String> _approvedPairs = const {};
  Set<String> _consentedProviders = const {};

  /// Ids of providers that rejected the default temperature (HTTP 400) in
  /// this session; their requests go without it.
  final Set<String> _rejectsTemperature = {};

  /// One-shot approvals ([allowOnce]), oldest first.
  final List<_OnceGrant> _grants = [];

  /// Whether offline-first mode may load lists over the network in this
  /// session (see [metadataDeferred]).
  bool _metadataUnlocked = false;

  /// Keyed by the URL of the instance that answered (+ engine and direction
  /// for languages).
  final Map<String, Future<List<TranslationEngine>>> _engines = {};
  final Map<String, Future<List<Language>>> _languages = {};

  final PersistedMetadata? _metadata;
  final _metadataChanges = StreamController<void>.broadcast();

  /// Bumped whenever the in-memory lists are dropped, so background
  /// revalidations started before do not repopulate them.
  int _metadataGeneration = 0;

  /// Fires when a background revalidation (see [getEngines]) found a Mozhi
  /// engine or language list that differs from the persisted one served
  /// before. Listeners reload the lists (the fresh ones are then served
  /// from memory).
  Stream<void> get metadataChanged => _metadataChanges.stream;

  static const _jsonRetryInstruction =
      'Your previous reply could not be parsed. Reply again with ONLY the '
      'single valid JSON object in the requested schema: no prose, no '
      'Markdown, no code fences.';

  /// The user's saved glossaries (Settings > AI > Glossaries) for a
  /// language pair: their terms and the keys that are case-sensitive.
  /// Every translation ([translate], [compare], [refine],
  /// [translateImage]) applies them together with the request's own
  /// `TranslationOptions.glossary`, whose terms win on the same source
  /// term. Null (the default): only the request's glossary.
  SavedGlossaryLookup? savedGlossaries;

  /// [request] with the [savedGlossaries] of its language pair merged into
  /// its options (see [mergeSavedGlossary]).
  TranslationRequest _withSavedGlossaries(TranslationRequest request) {
    final lookup = savedGlossaries;
    if (lookup == null) return request;
    final saved = lookup(request.source.code, request.target.code);
    final options = mergeSavedGlossary(request.options, saved);
    return identical(options, request.options)
        ? request
        : request.copyWith(options: options);
  }

  void updateConfiguration({
    required List<MozhiInstance> instances,
    required List<AiProviderConfig> providers,
  }) {
    if (_mozhi.update(instances)) _clearMozhiCaches();
    final current = {for (final provider in providers) provider.id: provider};
    for (final previous in _providers) {
      if (current[previous.id] != previous) _invalidateProvider(previous.id);
    }
    _providers = List.unmodifiable(providers);
    _llm.update(providers);
    _mt.update(providers);
  }

  /// Drops cached translations of the engines of provider [id].
  void _invalidateProvider(String id) {
    _cache
      ..invalidateEngine('ai:$id')
      ..invalidateEngine('mt:$id');
    // Parts are not kept by engine: all of them go.
    _chunkCache.clear();
  }

  List<MozhiInstance> get instances => _mozhi.instances;
  List<AiProviderConfig> get providers => _providers;

  /// Instance currently preferred for Mozhi calls (null when none).
  MozhiInstance? get activeInstance => _mozhi.active;

  /// Forgets the instance a failover switched to, so the next Mozhi request
  /// starts at the first configured instance again (e.g. after the user
  /// chose that instance explicitly).
  void resetActiveInstance() => _mozhi.resetPreferred();

  /// Whether the on-device engine is available (an [OfflineTranslator] was
  /// injected and is available on this platform).
  bool get hasOfflineEngine => _offline?.isAvailable ?? false;

  /// Removes every cached translation (also of the parts of long texts).
  void clearCache() {
    _cache.clear();
    _chunkCache.clear();
  }

  // ---------------------------------------------------------------------
  // Privacy
  // ---------------------------------------------------------------------

  /// How long an [allowOnce] approval waits for its request.
  static const consentOnceLifetime = Duration(minutes: 2);

  /// The key of the language pair [source] > [target] in [approvedPairs]
  /// (`de>en`; the source is `auto` when it is detected). Requests that
  /// carry text in one language only (romanization, text-to-speech) use
  /// that language twice (`ja>ja`); proofreading and language detection
  /// use `auto>auto`.
  static String pairKey(String source, String target) => '$source>$target';

  /// The provider id ([AiProviderConfig.id]) of an AI or machine
  /// translation engine id (`ai:<id>`, `mt:<id>`), else null: what
  /// [updatePrivacy]'s `consentedProviders` lists.
  static String? providerIdOf(String engineId) {
    for (final prefix in const ['ai:', 'mt:']) {
      if (engineId.startsWith(prefix) && engineId.length > prefix.length) {
        return engineId.substring(prefix.length);
      }
    }
    return null;
  }

  /// The privacy settings (pushed by the app whenever they change):
  ///
  /// * [PrivacyMode.offlineOnly]: nothing leaves the device. Every request
  ///   whose destination [DataDestination.leavesDevice] fails with a
  ///   [ConsentRequiredException] of [ConsentKind.offlineOnly], and no
  ///   engine or language list is loaded over the network (lists in memory
  ///   or in the [MetadataStore] are still served).
  /// * [PrivacyMode.offlineFirst]: text leaves the device (to any server,
  ///   the user's own included) only for the language pairs in
  ///   [approvedPairs] ([pairKey]); otherwise [ConsentKind.pair]. Mozhi
  ///   lists are not refreshed by themselves (see [metadataDeferred]).
  /// * [PrivacyMode.online]: the configured engines are used without
  ///   asking.
  ///
  /// In every mode, text goes to a [CloudProviderDestination] only when its
  /// provider id is in [consentedProviders] ([ConsentKind.cloudProvider]
  /// otherwise; checked before the pair).
  ///
  /// The rules are checked before any request, separately for every engine
  /// a request involves (an assisting AI engine, each engine in [compare],
  /// a Mozhi instance used for language detection, Reverso after Google
  /// text-to-speech), so text never moves on to another back end by
  /// itself. The consent for a Mozhi request covers the instances in the
  /// user's list: the failover may try them in order (never after
  /// [PrivacyMode.offlineOnly] was turned on), and the result names the
  /// instance that answered. Connection tests the user starts in settings
  /// ([pingInstance], [listModels], [testProvider]) carry no user text and
  /// are not restricted.
  ///
  /// [maskPersonalData] sets [TranslationRepository.maskPersonalData]
  /// (null keeps it).
  void updatePrivacy({
    required PrivacyMode mode,
    Iterable<String> approvedPairs = const [],
    Iterable<String> consentedProviders = const [],
    bool? maskPersonalData,
  }) {
    _privacyMode = mode;
    _approvedPairs = Set.unmodifiable(approvedPairs);
    _consentedProviders = Set.unmodifiable(consentedProviders);
    if (maskPersonalData != null) this.maskPersonalData = maskPersonalData;
  }

  /// The personal data shield (on by default): before a translation's
  /// text goes to a destination that [DataDestination.leavesDevice] (every
  /// engine but the offline one), e-mail addresses, phone numbers, IBANs,
  /// payment card numbers and IP addresses (`PersonalData`) are replaced by
  /// placeholders, which are put back into the translation; results say
  /// how many items stayed on the device
  /// ([TranslationResult.maskedPersonalData]). Applies to [translate] (also
  /// the language detections it makes, [compare] and [backTranslate]),
  /// [refine], [detectLanguage] and every AI extra: [getAlternatives],
  /// [getInsights], [getSuggestions], [explain], [lookUp]
  /// ([DictionaryEntry.maskedPersonalData]), [romanize], [align],
  /// [checkMeaning], [proofread] ([ProofreadResult.maskedPersonalData]) and
  /// the options of [translateImage] (the image itself cannot be masked).
  /// The free-text translation options (context, tone notes, one-off
  /// instructions) are masked together with the text, so a value that
  /// occurs in both gets the same placeholder; DeepL gets its context
  /// masked. The extras' prompts say what the placeholders stand for
  /// ([TranslationPrompts.maskedPersonalDataNote]), and their replies get
  /// the values back on the device (a placeholder the model changed stays
  /// as it was written). Text-to-speech ([textToSpeech]) cannot be masked:
  /// it would read the placeholders aloud. Masked data is never sent
  /// unmasked: when an engine loses a placeholder, the translation keeps
  /// the gap and gets [TranslationWarningKind.personalDataLost].
  bool maskPersonalData = true;

  /// Whether text for [destination] gets the personal data shield (see
  /// [maskPersonalData]).
  bool _shields(DataDestination? destination) =>
      maskPersonalData && destination != null && destination.leavesDevice;

  /// [text] with its personal data masked ([MaskStyle.brackets]), or null
  /// when it has none.
  static MaskedText? _maskPersonal(String text) {
    final spans = PersonalData.find(text);
    return spans.isEmpty ? null : TextMasker.mask(text, spans);
  }

  /// [text] as it may go to [destination]: with its personal data masked
  /// when the shield applies (see [maskPersonalData]).
  String _shielded(String text, DataDestination? destination) =>
      _shields(destination) ? _maskPersonal(text)?.text ?? text : text;

  /// [texts] as they may go to [destination]: masked together (one set of
  /// tokens, so a value that occurs in several of them gets one token) when
  /// the shield applies (see [maskPersonalData]).
  _Shield _shieldTexts(DataDestination? destination, List<String> texts) {
    if (!_shields(destination)) return _Shield(texts);
    // Personal data never spans the separator, so the parts stay apart.
    final joined = [
      for (final text in texts) text.replaceAll(_pairSeparator, ' '),
    ].join(_pairSeparator);
    final masked = _maskPersonal(joined);
    if (masked == null) return _Shield(texts);
    return _Shield(masked.text.split(_pairSeparator), masked: masked);
  }

  /// [request] (its text and free-text options: context, tone notes and
  /// instructions) and [extra] texts as they may go to [destination],
  /// masked together (see [_shieldTexts]); `extra` holds the [extra] texts
  /// as they are sent, in order.
  ({TranslationRequest request, List<String> extra, _Shield shield})
  _shieldRequest(
    DataDestination? destination,
    TranslationRequest request, [
    List<String> extra = const [],
  ]) {
    final options = request.options;
    final shield = _shieldTexts(destination, [
      request.text,
      options.context,
      options.formalityContext,
      options.instructions,
      ...extra,
    ]);
    if (shield.masked == null) {
      return (request: request, extra: extra, shield: shield);
    }
    final texts = shield.texts;
    return (
      request: request.copyWith(
        text: texts[0],
        options: options.copyWith(
          context: texts[1],
          formalityContext: texts[2],
          instructions: texts[3],
        ),
      ),
      extra: texts.sublist(4),
      shield: shield,
    );
  }

  /// Whether a request of [engine] for text in [source] translated into
  /// [target] would stop for the user's consent ([ConsentRequiredException])
  /// with the current privacy settings, e.g. to choose a fallback engine
  /// that needs no new consent. Nothing is used up or unlocked:
  /// [allowOnce] approvals are not counted. True for an engine whose
  /// provider is not configured.
  bool needsConsent(
    TranslationEngine engine, {
    required Language source,
    required Language target,
  }) {
    final destination = _destinationFor(engine);
    if (destination == null) return true;
    return _denial(
          destination,
          engineId: engine.id,
          providerId: engine.isAi || engine.isMt
              ? _configFor(engine, engine.isAi ? 'ai:' : 'mt:')?.id
              : null,
          source: source.code,
          target: target.code,
          useGrants: false,
          probe: true,
        ) !=
        null;
  }

  /// See [updatePrivacy].
  PrivacyMode get privacyMode => _privacyMode;

  /// See [updatePrivacy].
  Set<String> get approvedPairs => _approvedPairs;

  /// See [updatePrivacy].
  Set<String> get consentedProviders => _consentedProviders;

  /// Lets the next request that [consent] stopped through once ("Send just
  /// this once"): the next request of `consent.engineId` for the same
  /// language pair may send its text to `consent.destination` (for Mozhi:
  /// and on to the other instances of the user's list, as the failover
  /// does) despite the missing pair approval ([ConsentKind.pair]) or
  /// provider consent ([ConsentKind.cloudProvider]), only for that kind of
  /// consent. Another back end the request would involve (a Mozhi instance
  /// detecting the language for an AI engine, Reverso speech) is not
  /// covered.
  ///
  /// The approval is used up by the next request of that engine and pair
  /// that checks it, whether or not it needed it, and expires after
  /// [consentOnceLifetime]. A job that the user approved as a whole (a web
  /// page, a document) passes the number of [requests] it makes: the
  /// approval then lets that many through (each use keeps it alive for
  /// another [consentOnceLifetime]). [ConsentKind.offlineOnly] cannot be
  /// overridden ([ArgumentError]); [requests] must be at least 1
  /// ([RangeError]).
  void allowOnce(ConsentRequiredException consent, {int requests = 1}) {
    if (consent.kind == ConsentKind.offlineOnly) {
      throw ArgumentError.value(
        consent.kind,
        'consent',
        'Offline-only mode cannot be overridden for one request',
      );
    }
    RangeError.checkValueInInterval(requests, 1, 1 << 30, 'requests');
    _dropExpiredGrants();
    _grants.add(
      _OnceGrant(
        kind: consent.kind,
        engineId: consent.engineId,
        destination: consent.destination,
        pair: pairKey(consent.source ?? 'auto', consent.target ?? 'auto'),
        expires: _clock().add(consentOnceLifetime),
        remaining: requests,
      ),
    );
  }

  /// Withdraws what [allowOnce] let through for [consent] (the same kind
  /// of consent, engine, destination and language pair) and no request
  /// has used yet: a job the user approved as a whole that ended early
  /// (cancelled, or fewer requests than counted) leaves nothing behind
  /// that would let a later, unrelated request through without asking.
  void revokeOnce(ConsentRequiredException consent) {
    final pair = pairKey(consent.source ?? 'auto', consent.target ?? 'auto');
    _grants.removeWhere(
      (grant) =>
          grant.kind == consent.kind &&
          grant.engineId == consent.engineId &&
          grant.destination == consent.destination &&
          grant.pair == pair,
    );
  }

  /// Where the text of engine [engineId] goes: [OnDeviceDestination] for
  /// the offline engine; for Mozhi engines (`mozhi:<engine>`) the active
  /// instance ([activeInstance]; [SelfHostedDestination] for private
  /// networks, Tor and I2P, else [PublicInstanceDestination] with the
  /// upstream engine); for AI providers [CloudProviderDestination] named
  /// after the provider, or [SelfHostedDestination] for local ones (Ollama,
  /// LM Studio, ...), and [OnDeviceDestination] for models on this device
  /// ([AiProviderConfig.isOnDevice]: no consent is asked, they work in
  /// [PrivacyMode.offlineOnly], need no approved pairs and get no personal
  /// data shield, as nothing leaves the device); DeepL is always
  /// `CloudProviderDestination('DeepL')`; LibreTranslate is a public
  /// instance or self-hosted, by its URL.
  ///
  /// Results carry the destination that actually answered
  /// ([TranslationResult.destination]). [ArgumentError] for an AI or
  /// machine translation engine whose provider is not configured.
  DataDestination destinationOf(String engineId) {
    if (engineId == TranslationEngine.offlineId ||
        engineId.startsWith('offline:')) {
      return const OnDeviceDestination();
    }
    if (engineId.startsWith('mozhi:')) {
      return _mozhiDestination(engineId.substring('mozhi:'.length));
    }
    final id = providerIdOf(engineId);
    final config = _providers.firstWhereOrNull((p) => p.id == id);
    if (config == null) {
      throw ArgumentError.value(engineId, 'engineId', 'Unknown engine');
    }
    return _providerDestination(config);
  }

  /// The destination of Mozhi [engine] on [instance] (default: the active
  /// one; a nameless public destination when none is configured).
  DataDestination _mozhiDestination(String engine, [MozhiInstance? instance]) {
    final url = (instance ?? _mozhi.active)?.url;
    final upstream = engine.isEmpty ? null : engine;
    if (url == null) return PublicInstanceDestination('', engine: upstream);
    return DataDestination.forUrl(url, engine: upstream);
  }

  static DataDestination _providerDestination(AiProviderConfig config) {
    if (config.isOnDevice) return const OnDeviceDestination();
    final base = config.baseUrl.trim();
    switch (config.service) {
      case MtService.llm:
        final name = config.name.trim();
        return DataDestination.forUrl(
          base,
          cloudProvider: name.isEmpty ? DataDestination.hostOf(base) : name,
        );
      case MtService.deepl:
        return CloudProviderDestination(
          'DeepL',
          host: base.isEmpty
              ? DeeplClient.defaultBaseUrl(config.apiKey ?? '').host
              : DataDestination.hostOf(base),
        );
      case MtService.libreTranslate:
        return DataDestination.forUrl(
          base.isEmpty ? LibreTranslateClient.officialBaseUrl.toString() : base,
        );
    }
  }

  /// The destination of [engine], or null when its provider is not
  /// configured (the request fails with an [ArgumentError] without being
  /// sent).
  DataDestination? _destinationFor(TranslationEngine engine) =>
      switch (engine.kind) {
        EngineKind.offline => const OnDeviceDestination(),
        EngineKind.mozhi => _mozhiDestination(mozhiEngineId(engine)),
        EngineKind.ai => switch (_configFor(engine, 'ai:')) {
          final config? => _providerDestination(config),
          null => null,
        },
        EngineKind.mt => switch (_configFor(engine, 'mt:')) {
          final config? => _providerDestination(config),
          null => null,
        },
      };

  /// The consent a request of [engine] for [source] > [target] (language
  /// codes) still needs, or null when its text may go to the engine's
  /// destination (or the engine is not configured).
  ConsentRequiredException? _consentFor(
    TranslationEngine engine, {
    required String source,
    required String target,
  }) {
    final destination = _destinationFor(engine);
    if (destination == null) return null;
    return _denial(
      destination,
      engineId: engine.id,
      providerId: engine.isAi || engine.isMt
          ? _configFor(engine, engine.isAi ? 'ai:' : 'mt:')?.id
          : null,
      source: source,
      target: target,
    );
  }

  /// [_consentFor] as an error to throw.
  void _ensureAllowed(
    TranslationEngine engine, {
    required String source,
    required String target,
  }) {
    final denied = _consentFor(engine, source: source, target: target);
    if (denied != null) throw denied;
  }

  /// Why text of [engineId] for [source] > [target] may not go to
  /// [destination] (see [updatePrivacy]), or null when it may.
  /// [providerId] is the provider of a [CloudProviderDestination]. With
  /// [useGrants], matching [allowOnce] approvals are used up. A [probe]
  /// only asks: it does not unlock the metadata (see [metadataDeferred]).
  ConsentRequiredException? _denial(
    DataDestination destination, {
    required String engineId,
    required String source,
    required String target,
    String? providerId,
    bool useGrants = true,
    bool probe = false,
  }) {
    if (!destination.leavesDevice) return null;
    ConsentRequiredException denied(ConsentKind kind) =>
        ConsentRequiredException(
          kind: kind,
          destination: destination,
          engineId: engineId,
          source: source,
          target: target,
        );
    if (_privacyMode == PrivacyMode.offlineOnly) {
      return denied(ConsentKind.offlineOnly);
    }
    final pair = pairKey(source, target);
    bool granted(ConsentKind kind) =>
        useGrants && _takeGrant(kind, engineId, destination, pair);
    if (destination is CloudProviderDestination) {
      final grant = granted(ConsentKind.cloudProvider);
      if (!grant && !_consentedProviders.contains(providerId)) {
        return denied(ConsentKind.cloudProvider);
      }
    }
    if (_privacyMode == PrivacyMode.offlineFirst) {
      final grant = granted(ConsentKind.pair);
      if (!grant && !_approvedPairs.contains(pair)) {
        return denied(ConsentKind.pair);
      }
      if (!probe) _unlockMetadata();
    }
    return null;
  }

  /// Removes the [allowOnce] approval for [kind], [engineId], [destination]
  /// and [pair], if any; returns whether there was one.
  bool _takeGrant(
    ConsentKind kind,
    String engineId,
    DataDestination destination,
    String pair,
  ) {
    _dropExpiredGrants();
    final index = _grants.indexWhere(
      (grant) =>
          grant.kind == kind &&
          grant.engineId == engineId &&
          grant.destination == destination &&
          grant.pair == pair,
    );
    if (index < 0) return false;
    final grant = _grants[index];
    if (--grant.remaining <= 0) {
      _grants.removeAt(index);
    } else {
      grant.expires = _clock().add(consentOnceLifetime);
    }
    return true;
  }

  void _dropExpiredGrants() {
    final now = _clock();
    _grants.removeWhere((grant) => !grant.expires.isAfter(now));
  }

  /// The `allow` filter of a Mozhi request that passed the consent check:
  /// the consent for a Mozhi request covers the instances in the user's
  /// list (the failover may try them in order), unless the user turned on
  /// [PrivacyMode.offlineOnly] meanwhile.
  bool _mozhiFailoverAllowed(MozhiInstance _) =>
      _privacyMode != PrivacyMode.offlineOnly;

  /// Engines: Mozhi engines advertised by the active instance (via
  /// `/api/engines`, `subtitle` = instance display name, i.e. its label or
  /// host), then the enabled providers in configuration order (AI providers:
  /// `ai:<id>`, `subtitle` = model, `promptProfile` resolved; machine
  /// translation services: `mt:<id>`, `subtitle` = service or host,
  /// `mtService`), then [TranslationEngine.offline] when [hasOfflineEngine].
  /// If no instance is reachable, returns only the other engines (and does
  /// not throw) unless there are none, in which case the last error is
  /// thrown.
  ///
  /// `refresh: true` reloads the Mozhi engine and language lists and the
  /// services' language lists, and starts at the first instance again.
  ///
  /// With a [MetadataStore], the Mozhi engine list and each Mozhi engine's
  /// language lists ([getSourceLanguages], [getTargetLanguages]) are stored
  /// as JSON with a timestamp, keyed by instance URL (+ engine and
  /// direction). When a list is not in memory, the stored one of the
  /// active instance (else of the first configured instance that has one)
  /// is returned at once, if younger than `metadataMaxAge`, and reloaded in
  /// the background; when the reloaded list differs, it replaces the
  /// served one in memory and [metadataChanged] fires. A failed background
  /// reload keeps nothing in memory, so the next call tries again. Without
  /// a usable stored list, the list is loaded as without a store. With
  /// `refresh: true` the engine list is loaded from the network first and
  /// the stored one is only the fallback when no instance answers. Failures
  /// are never stored; corrupt stored data is ignored. AI, machine
  /// translation and offline engines are computed locally and not stored.
  ///
  /// In [PrivacyMode.offlineOnly] nothing is loaded over the network: the
  /// Mozhi engines are listed only when their list is in memory or stored
  /// (of any age, without revalidation), and so are the Mozhi language
  /// lists; machine translation services' lists only when in memory. A
  /// list that would need the network fails with a
  /// [ConsentRequiredException] of [ConsentKind.offlineOnly] (for
  /// [getEngines] only when there are no other engines). In
  /// [PrivacyMode.offlineFirst] the Mozhi lists behave the same while
  /// [metadataDeferred] (the exception is then a [ConsentKind.pair] one
  /// without a language pair); `refresh: true` ends that.
  Future<List<TranslationEngine>> getEngines({bool refresh = false}) async {
    if (refresh) {
      _metadataUnlocked = true;
      _clearMozhiCaches();
      _mozhi.resetPreferred();
      _mt.clearLanguages();
    }
    final others = [
      for (final provider in _providers)
        if (provider.enabled) _engineFor(provider),
      if (hasOfflineEngine) TranslationEngine.offline(),
    ];
    if (_mozhi.instances.isEmpty) return others;
    try {
      return [...await _loadMozhiEngines(networkFirst: refresh), ...others];
    } on Object {
      if (others.isEmpty) rethrow;
      return others;
    }
  }

  static TranslationEngine _engineFor(AiProviderConfig provider) =>
      provider.isMtService
      ? TranslationEngine(
          id: 'mt:${provider.id}',
          kind: EngineKind.mt,
          name: provider.name,
          subtitle: _mtSubtitle(provider),
          providerId: provider.id,
          isLocal: provider.isLocal,
          mtService: provider.service,
        )
      : TranslationEngine(
          id: 'ai:${provider.id}',
          kind: EngineKind.ai,
          name: provider.name,
          subtitle: provider.model,
          providerId: provider.id,
          isLocal: provider.isLocal,
          promptProfile: provider.resolvedPromptProfile,
          onDevice: provider.isOnDevice,
        );

  static String _mtSubtitle(AiProviderConfig provider) {
    final url = provider.baseUrl.trim();
    final host = url.isEmpty
        ? ''
        : Uri.tryParse(url.contains('://') ? url : 'https://$url')?.host ?? '';
    if (host.isNotEmpty) return host;
    return provider.service == MtService.deepl ? 'DeepL API' : 'LibreTranslate';
  }

  Future<List<TranslationEngine>> _loadMozhiEngines({
    required bool networkFirst,
  }) => _cachedMozhi(
    _engines,
    '',
    fetch: (client) async => [
      for (final MapEntry(key: id, value: name)
          in (await client.getEngines()).entries)
        {'id': id, 'name': name},
    ],
    build: _enginesFromJson,
    engineId: 'mozhi:',
    networkFirst: networkFirst,
  );

  /// Mozhi engines from their JSON form (`[{"id": ..., "name": ...}]`);
  /// [FormatException] when [json] has another shape.
  static List<TranslationEngine> _enginesFromJson(
    Object? json,
    MozhiInstance instance,
  ) {
    if (json is! List<Object?>) {
      throw const FormatException('Expected a list of engines');
    }
    return List<TranslationEngine>.unmodifiable([
      for (final item in json)
        switch (item) {
          {'id': final String id, 'name': final String name} =>
            TranslationEngine(
              id: 'mozhi:$id',
              kind: EngineKind.mozhi,
              name: name.isEmpty ? id : name,
              subtitle: instance.displayName,
              mozhiEngine: id,
            ),
          _ => throw const FormatException('Invalid engine'),
        },
    ]);
  }

  /// Languages from their JSON form ([Language.toJson]);
  /// [FormatException] when [json] has another shape.
  static List<Language> _languagesFromJson(Object? json, MozhiInstance _) {
    if (json is! List<Object?>) {
      throw const FormatException('Expected a list of languages');
    }
    return List<Language>.unmodifiable(json.map(_languageFromJson));
  }

  static Language _languageFromJson(Object? json) {
    if (json case {'code': final String code, 'name': final String name}) {
      final nativeName = json['nativeName'];
      final isCustom = json['isCustom'] ?? false;
      if (nativeName is String? && isCustom is bool) {
        return code == Language.auto.code && !isCustom
            ? Language.auto
            : Language(
                code: code,
                name: name,
                nativeName: nativeName,
                isCustom: isCustom,
              );
      }
    }
    throw const FormatException('Invalid language');
  }

  void _clearMozhiCaches() {
    _metadataGeneration++;
    _engines.clear();
    _languages.clear();
  }

  /// Instances to look for a stored list in: the active one, then the
  /// others in configuration order.
  List<MozhiInstance> get _storedCandidates {
    final active = _mozhi.active;
    return [
      ?active,
      for (final instance in _mozhi.instances)
        if (instance.url != active?.url) instance,
    ];
  }

  /// The first usable stored list [name] (see [_storedCandidates]) built
  /// with [build] (of any age with [anyAge]), or null.
  Future<({StoredMetadata stored, T value})?> _readStored<T>(
    String name,
    T Function(Object? json, MozhiInstance instance) build, {
    bool anyAge = false,
  }) async {
    final metadata = _metadata;
    if (metadata == null) return null;
    for (final instance in _storedCandidates) {
      final stored = await metadata.read(instance.url, name, anyAge: anyAge);
      if (stored == null) continue;
      try {
        return (stored: stored, value: build(stored.data, instance));
      } on Object {
        // Corrupt or outdated data: ignored.
      }
    }
    return null;
  }

  /// Returns the cached future for [suffix] on the active instance, or
  /// loads it: from the [MetadataStore] (revalidated in the background, see
  /// [getEngines]) or, with failover, by [fetch] (a JSON-encodable value,
  /// stored on success) turned into the list by [build]. [networkFirst]
  /// loads with [fetch] first and serves the stored list only when that
  /// fails.
  ///
  /// The entry is kept under the instance that actually answered, so a
  /// later failover back to the first instance does not serve the other
  /// instance's list. Failed loads are evicted so the next call retries.
  ///
  /// When lists may not be loaded over the network ([PrivacyMode
  /// .offlineOnly], or offline first while [metadataDeferred]) only the
  /// memory and the store are asked (the stored list, of any age, is not
  /// revalidated nor kept in memory, so that it is reloaded once the
  /// network may be used); without either, a [ConsentRequiredException]
  /// for [engineId] (`mozhi:<engine>`, see [_listsUnavailable]).
  Future<T> _cachedMozhi<T>(
    Map<String, Future<T>> cache,
    String suffix, {
    required Future<Object?> Function(MozhiApiClient client) fetch,
    required T Function(Object? json, MozhiInstance instance) build,
    required String engineId,
    bool networkFirst = false,
  }) {
    String keyFor(String url) => suffix.isEmpty ? url : '$url|$suffix';
    final name = suffix.isEmpty ? 'engines' : suffix;
    final key = keyFor(_mozhi.active?.url ?? '');
    final cached = cache[key];
    if (cached != null) return cached;
    if (!_metadataNetworkAllowed) return _storedOnly(name, build, engineId);
    final generation = _metadataGeneration;
    late final Future<T> future;

    Future<(String url, Object? json, T value)> load() =>
        _mozhi.run((client, instance) async {
          final json = await fetch(client);
          return (instance.url, json, build(json, instance));
        });

    Future<void> revalidate(StoredMetadata stored) async {
      try {
        final (url, json, value) = await load();
        if (generation != _metadataGeneration) return;
        await _metadata?.write(url, name, json);
        if (!identical(cache[key], future)) return;
        cache
          ..removeWhere((entry, _) => entry == key)
          ..[keyFor(url)] = Future.value(value);
        if (url != stored.url || jsonEncode(json) != stored.encodedData) {
          if (!_metadataChanges.isClosed) _metadataChanges.add(null);
        }
      } on Object {
        cache.removeWhere((_, value) => identical(value, future));
      }
    }

    Future<T> run() async {
      if (!networkFirst) {
        final stored = await _readStored(name, build);
        if (stored != null) {
          unawaited(revalidate(stored.stored));
          return stored.value;
        }
      }
      try {
        final (url, json, value) = await load();
        if (generation == _metadataGeneration) {
          unawaited(_metadata?.write(url, name, json));
        }
        final actual = keyFor(url);
        if (actual != key && identical(cache[key], future)) {
          cache
            ..removeWhere((entry, _) => entry == key)
            ..[actual] = future;
        }
        return value;
      } on Object {
        cache.removeWhere((_, value) => identical(value, future));
        if (networkFirst) {
          final stored = await _readStored(name, build);
          if (stored != null) return stored.value;
        }
        rethrow;
      }
    }

    future = run();
    cache[key] = future;
    return future;
  }

  /// The stored list [name] (see [_cachedMozhi] while lists may not be
  /// loaded over the network).
  Future<T> _storedOnly<T>(
    String name,
    T Function(Object? json, MozhiInstance instance) build,
    String engineId,
  ) async {
    final stored = await _readStored(name, build, anyAge: true);
    if (stored != null) return stored.value;
    throw _listsUnavailable(engineId);
  }

  /// Why a list of [engineId] cannot be loaded now: [ConsentKind
  /// .offlineOnly], or (offline first, [metadataDeferred]) a
  /// [ConsentKind.pair] exception without a language pair, which
  /// [allowMetadataRequests] lifts.
  ConsentRequiredException _listsUnavailable(String engineId) =>
      ConsentRequiredException(
        kind: _privacyMode == PrivacyMode.offlineOnly
            ? ConsentKind.offlineOnly
            : ConsentKind.pair,
        destination: engineId.startsWith('mozhi:')
            ? _mozhiDestination(engineId.substring('mozhi:'.length))
            : destinationOf(engineId),
        engineId: engineId,
      );

  /// Whether engine and language lists may be loaded over the network now
  /// (see [metadataDeferred]).
  bool get _metadataNetworkAllowed => switch (_privacyMode) {
    PrivacyMode.online => true,
    PrivacyMode.offlineOnly => false,
    PrivacyMode.offlineFirst => _metadataUnlocked,
  };

  /// In [PrivacyMode.offlineFirst], whether Mozhi engine and language lists
  /// are still only served from memory and the [MetadataStore] (stored
  /// lists of any age, not refreshed at launch), so that the app does not
  /// contact a server before the user lets it. The lists are loaded over
  /// the network again, for the rest of the session, after
  /// [allowMetadataRequests], `getEngines(refresh: true)`, or a request the
  /// privacy settings let leave the device (then [metadataChanged] fires so
  /// that the lists are reloaded). Machine translation services' lists are
  /// not deferred (they are loaded only for a service the user set up and
  /// picked).
  bool get metadataDeferred =>
      _privacyMode == PrivacyMode.offlineFirst && !_metadataUnlocked;

  /// Lets offline-first mode load engine and language lists over the
  /// network for the rest of the session (see [metadataDeferred]), e.g. when
  /// the user opens the engine picker. The caller reloads the lists.
  void allowMetadataRequests() => _metadataUnlocked = true;

  /// A request may leave the device: in offline-first mode, the lists may
  /// be refreshed from now on ([metadataChanged] fires once).
  void _unlockMetadata() {
    if (_metadataUnlocked) return;
    _metadataUnlocked = true;
    if (_privacyMode == PrivacyMode.offlineFirst &&
        !_metadataChanges.isClosed) {
      _metadataChanges.add(null);
    }
  }

  /// Mozhi: `/api/source_languages` mapped to [Language] (id `auto` ->
  /// [Language.auto] first, names from the engine, `nativeName` from
  /// `LanguageCatalog` when known). AI: [Language.auto] + catalogue.
  /// Offline: [Language.auto] + the backend's languages. Machine
  /// translation services: [Language.auto] + the service's list (cached).
  Future<List<Language>> getSourceLanguages(TranslationEngine engine) =>
      switch (engine.kind) {
        EngineKind.ai => Future.sync(
          () => [Language.auto, ...LanguageCatalog.all],
        ),
        EngineKind.mozhi => _mozhiLanguages(engine, source: true),
        EngineKind.offline => Future.sync(
          () => _offlineFor(engine).sourceLanguages,
        ),
        EngineKind.mt => Future.sync(
          () => _mt.sourceLanguages(
            _mtProviderFor(engine),
            unlessCached: _mtOffline(engine),
          ),
        ),
      };

  /// Mozhi: `/api/target_languages` (for DeepL, regional ids Mozhi cannot
  /// translate into are mapped to their base language, and `zh-hant` is
  /// dropped). AI: catalogue. Offline: the backend's languages. Machine
  /// translation services: the service's list (cached).
  Future<List<Language>> getTargetLanguages(TranslationEngine engine) =>
      switch (engine.kind) {
        EngineKind.ai => Future.sync(() => LanguageCatalog.all),
        EngineKind.mozhi => _mozhiLanguages(engine, source: false),
        EngineKind.offline => Future.sync(() => _offlineFor(engine).languages),
        EngineKind.mt => Future.sync(
          () => _mt.targetLanguages(
            _mtProviderFor(engine),
            unlessCached: _mtOffline(engine),
          ),
        ),
      };

  /// In [PrivacyMode.offlineOnly], the error for a machine translation
  /// service's language list that is not in memory; else null.
  Object Function()? _mtOffline(TranslationEngine engine) =>
      _privacyMode == PrivacyMode.offlineOnly
      ? () => _listsUnavailable(engine.id)
      : null;

  Future<List<Language>> _mozhiLanguages(
    TranslationEngine engine, {
    required bool source,
  }) {
    final id = mozhiEngineId(engine);
    return _cachedMozhi(
      _languages,
      '$id|${source ? 'source' : 'target'}',
      fetch: (client) async {
        final languages = source
            ? await client.getSourceLanguages(id)
            : await client.getTargetLanguages(id);
        final fixed = !source && id.toLowerCase() == 'deepl'
            ? fixMozhiDeeplTargets(languages)
            : languages;
        return [
          for (final language in mapMozhiLanguages(fixed)) language.toJson(),
        ];
      },
      build: _languagesFromJson,
      engineId: engine.id,
    );
  }

  /// Mozhi, offline and machine translation engines: one complete result.
  /// Mozhi results carry transliterations, word choices and synonyms; an
  /// empty translation of non-empty text is a retryable
  /// `MozhiApiException` (status 502, "Google returned an empty
  /// translation."). AI: streams growing snapshots (`isComplete: false`)
  /// and a final `isComplete: true` result; the `[[lang:xx]]` marker is
  /// parsed into `detectedSource` and never shown; `<think>` content never
  /// appears; text is passed through `ResponseParsers.cleanTranslation` on
  /// completion. Empty/whitespace input emits nothing and completes.
  /// `detectedSource` is normalised and only set for an auto source.
  ///
  /// Translation-specialised AI models ([TranslationEngine.usesMtProfile])
  /// get `MtPrompts` (no options, no marker, the model card's sampling
  /// unless the provider sets a temperature) and need a source language:
  /// for an auto source it is identified on the device when possible, else
  /// (for non-local engines) with Mozhi, else
  /// [SourceLanguageRequiredException] is emitted.
  ///
  /// Partial AI snapshots carry `detectedSource` as soon as the model's
  /// `[[lang:xx]]` marker has arrived (with empty text if nothing follows it
  /// yet), so a caller can stop early when the source is the target.
  ///
  /// Long AI inputs (more than `aiChunkThreshold` characters, or
  /// `localAiChunkThreshold` for local providers and
  /// `onDeviceAiChunkThreshold` for models on this device; see the
  /// constructor) are translated in parts: split at paragraph boundaries
  /// (overlong paragraphs at sentence ends, never inside fenced code
  /// blocks), two parts at a time, each part after the first with the end
  /// of the previous one for reference (in the user message, as data).
  /// With an auto source the first part is translated alone and its
  /// detected language is used for the others (unless it is the target
  /// language: then they stay auto).
  /// Snapshots combine the parts in order, joined with the original
  /// whitespace between them, and carry the first part's `detectedSource`;
  /// the result is complete once every part is. An error in one part
  /// cancels the others and is emitted.
  ///
  /// Short input (at most 3 words) with an auto source on a cloud AI engine
  /// with [TranslationEngine.supportsExtras] is also checked with a second
  /// detection ([detectLanguage]) in parallel. When it is unsure, names
  /// other likely languages or disagrees with the translation's
  /// `detectedSource`, the final result has `detectionUncertain` and up to
  /// 3 `detectedAlternatives` (the request's `recentSourceLanguages` first).
  /// The check never fails the translation (its errors are ignored); when
  /// it is still running as the translation finishes, the finished text is
  /// emitted as a partial snapshot right away and the final result waits
  /// for the check at most `detectionHintTimeout` (then without the hint,
  /// and the check is aborted). The check is a streamed request without
  /// reasoning effort and without a retry, so cancelling the translation
  /// cancels it too.
  ///
  /// Final results are served from and stored in the cache (results served
  /// from it have `fromCache: true`; long inputs are cached as a whole,
  /// never per part); `refresh: true` skips the lookup (e.g. "Regenerate").
  /// For short auto-detected AI input the request's `recentSourceLanguages`
  /// are part of the cache key, and a result of input that gets the second
  /// detection is only stored with that detection's verdict (never one
  /// from [compare], nor one whose check failed or timed out).
  ///
  /// Errors are forwarded as-is (`MozhiApiException`, `LlmApiException`,
  /// `LlmRefusalException`, `MtApiException`,
  /// `OfflineModelMissingException`, `OfflineLanguageUnsupportedException`,
  /// [SourceLanguageRequiredException]). Cancelling the subscription
  /// cancels the underlying HTTP request (AI, DeepL and LibreTranslate).
  ///
  /// A custom language on an engine that cannot take one, or an engine
  /// whose provider is not configured, is reported as an [ArgumentError]
  /// stream error.
  Stream<TranslationResult> translate(
    TranslationEngine engine,
    TranslationRequest request, {
    bool refresh = false,
  }) => _translate(engine, request, refresh: refresh, detectionHint: true);

  /// [translate]; [detectionHint] enables the second detection of short
  /// input (compare mode does without it).
  Stream<TranslationResult> _translate(
    TranslationEngine engine,
    TranslationRequest request, {
    required bool refresh,
    required bool detectionHint,
  }) {
    if (request.text.trim().isEmpty) return const Stream.empty();
    final sanitized = _sanitizeRequest(request);
    if (sanitized == null) return Stream.error(_emptyCustomLanguage(request));
    final safe = _withSavedGlossaries(sanitized);
    // Checked before the cache too: a network engine is not used (not even
    // its cached results) without the user's consent.
    final denied = _consentFor(
      engine,
      source: safe.source.code,
      target: safe.target.code,
    );
    if (denied != null) return Stream.error(denied);
    Stream<TranslationResult> fetch() =>
        _translateUncached(engine, safe, refresh: refresh);
    final key = _cacheKeyOf(engine, safe);
    if (refresh) _cache.remove(engine, key);
    if (!_wantsDetectionHint(engine, safe)) {
      return _cache.cachedTranslate(engine, key, fetch);
    }
    // Only results with the second detection's verdict are stored, so a
    // result without it (compare mode, a failed or timed out check) never
    // stands in for one with it.
    return _cachedOrFetch(
      engine,
      key,
      () => detectionHint
          ? _withDetectionHint(
              engine,
              safe,
              fetch(),
              onVerdict: (result) => _cache.store(engine, key, result),
            )
          : fetch(),
    );
  }

  /// Longest (trimmed) input, in characters and in words, whose recent
  /// source languages can change the result: the prompt's hint for short
  /// text and the second detection.
  static const int _recentLanguagesMaxChars =
      _hintMaxChars > TranslationPrompts.shortTextMaxChars
      ? _hintMaxChars
      : TranslationPrompts.shortTextMaxChars;
  static const int _recentLanguagesMaxWords =
      _hintMaxWords > TranslationPrompts.shortTextMaxWords
      ? _hintMaxWords
      : TranslationPrompts.shortTextMaxWords;

  /// [request] as the cache keys it. Its recent source languages only steer
  /// short auto-detected AI input (the prompt's hint and the order of the
  /// second detection's alternatives); elsewhere they are dropped so that
  /// they do not split the cache.
  static TranslationRequest _cacheKeyOf(
    TranslationEngine engine,
    TranslationRequest request,
  ) {
    if (request.recentSourceLanguages.isEmpty) return request;
    final text = request.text.trim();
    final relevant =
        engine.isAi &&
        request.source.isAuto &&
        text.runes.length <= _recentLanguagesMaxChars &&
        text.split(RegExp(r'\s+')).length <= _recentLanguagesMaxWords;
    return relevant
        ? request
        : request.copyWith(recentSourceLanguages: const []);
  }

  /// The cached result for [key] on [engine] (marked `fromCache`), else the
  /// events of [fetch], which is responsible for storing its result.
  Stream<TranslationResult> _cachedOrFetch(
    TranslationEngine engine,
    TranslationRequest key,
    Stream<TranslationResult> Function() fetch,
  ) {
    late final StreamController<TranslationResult> controller;
    StreamSubscription<TranslationResult>? subscription;
    controller = StreamController<TranslationResult>(
      onListen: () {
        final hit = _cache.lookup(engine, key);
        if (hit != null) {
          controller.add(hit.fromCache ? hit : hit.copyWith(fromCache: true));
          unawaited(controller.close());
          return;
        }
        subscription = fetch().listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  /// Security W4: free-form (custom) language names end up in the system
  /// prompt and may come from a link. They are passed through
  /// [TranslationPrompts.sanitizeCustomLanguage] (one line, no quotes or
  /// angle brackets, at most 60 characters) before anything else sees them,
  /// so results and cache entries carry the sanitised name. Null when a
  /// custom name is empty after sanitising.
  static TranslationRequest? _sanitizeRequest(TranslationRequest request) {
    final source = _sanitizeLanguage(request.source);
    final target = _sanitizeLanguage(request.target);
    if (source == null || target == null) return null;
    if (identical(source, request.source) &&
        identical(target, request.target)) {
      return request;
    }
    return request.copyWith(source: source, target: target);
  }

  static Language? _sanitizeLanguage(Language language) {
    if (!language.isCustom) return language;
    final name = TranslationPrompts.sanitizeCustomLanguage(language.code);
    if (name.isEmpty) return null;
    return name == language.code && name == language.name
        ? language
        : Language.custom(name);
  }

  static ArgumentError _emptyCustomLanguage(TranslationRequest request) {
    final empty =
        request.source.isCustom && _sanitizeLanguage(request.source) == null
        ? request.source
        : request.target;
    return ArgumentError.value(
      empty.code,
      empty == request.source ? 'source' : 'target',
      'Custom language name is empty',
    );
  }

  /// The engine's translation of [request], every result with its
  /// [TranslationResult.destination].
  /// With [refresh], the parts of a long AI input are translated again too
  /// (not served from the part cache).
  Stream<TranslationResult> _translateUncached(
    TranslationEngine engine,
    TranslationRequest request, {
    bool refresh = false,
  }) {
    final destination = _destinationFor(engine);
    final shield = _shields(destination);
    final results = switch (engine.kind) {
      EngineKind.mozhi => _machineTranslation(
        engine,
        request,
        shield: shield,
        glossary: request.options.glossary,
        style: MaskStyle.brackets,
        limit: mozhiCharacterLimit(mozhiEngineId(engine)),
        concurrency: mozhiConcurrency(mozhiEngineId(engine)),
        send: (part, {required masked, abort, original}) =>
            _translateMozhi(engine, part, abort: abort),
      ),
      EngineKind.ai => _translateAi(
        engine,
        request,
        shield: shield,
        refresh: refresh,
      ),
      // Cancelling the subscription stops the work on the device.
      EngineKind.offline => _abortable(
        (abort) => translateOffline(
          _offlineFor(engine),
          engine,
          request,
          abort: abort,
        ),
      ),
      EngineKind.mt => _translateMt(engine, request, shield: shield),
    };
    return _withDestination(_checked(engine, request, results), destination);
  }

  /// Most characters a Mozhi engine gets in one request: longer input is
  /// translated in paragraphs (see [translate]). Upstream services limit
  /// their requests (Google about 5000 characters, DeepL's web API, Reverso
  /// and MyMemory far less).
  static int mozhiCharacterLimit(String engine) =>
      switch (engine.toLowerCase()) {
        'google' => 4500,
        'yandex' => 4500,
        'deepl' => 1500,
        'reverso' => 1500,
        'libre' => 2000,
        'duckduckgo' || 'bing' => 1000,
        'mymemory' => 450,
        _ => 1500,
      };

  /// How many parts of a long input go to one Mozhi engine at a time:
  /// 2, or 1 for upstreams with strict rate limits.
  static int mozhiConcurrency(String engine) => switch (engine.toLowerCase()) {
    'deepl' || 'reverso' || 'mymemory' => 1,
    _ => 2,
  };

  /// Most characters the DeepL API gets in one request (its limit is a
  /// 128 KiB request body).
  static const deeplCharacterLimit = 10000;

  /// Most characters a LibreTranslate server gets in one request (public
  /// servers often limit requests to a few thousand characters).
  static const libreCharacterLimit = 2500;

  /// A machine translation service's translation of [request] (see
  /// [_machineTranslation]); DeepL gets the masks as XML tags
  /// (`tag_handling=xml`), its glossaries, its quality-optimised model when
  /// the provider prefers it and, with [shield], its context with the
  /// personal data masked. LibreTranslate gets the glossary applied on the
  /// device.
  Stream<TranslationResult> _translateMt(
    TranslationEngine engine,
    TranslationRequest request, {
    required bool shield,
  }) {
    final AiProviderConfig config;
    try {
      config = _mtProviderFor(engine);
    } on Object catch (error, stackTrace) {
      return Stream.error(error, stackTrace);
    }
    final deepl = config.service == MtService.deepl;
    final context = request.options.context;
    final work = deepl && shield && context.trim().isNotEmpty
        ? request.copyWith(
            options: request.options.copyWith(
              context: _shielded(context, _providerDestination(config)),
            ),
          )
        : request;
    return _machineTranslation(
      engine,
      work,
      shield: shield,
      glossary: deepl ? const {} : request.options.glossary,
      style: deepl ? MaskStyle.xml : MaskStyle.brackets,
      limit: deepl ? deeplCharacterLimit : libreCharacterLimit,
      concurrency: 2,
      send: (part, {required masked, abort, original}) => _mt.translate(
        engine,
        config,
        part,
        abort: abort,
        xmlTags: deepl && masked,
        identifySource: () => _identifyOnDevice((original ?? part).text),
      ),
    );
  }

  /// The language of [text] by the on-device identifier, or null when
  /// there is none or it cannot tell (never a request).
  Future<String?> _identifyOnDevice(String text) async {
    final offline = _offline;
    if (offline == null || !offline.isAvailable) return null;
    try {
      return normalizeDetected(await offline.translator.identifyLanguage(text));
    } on Object {
      return null;
    }
  }

  /// A non-AI engine's translation of [request] with [send] (one request
  /// of a part of the text, already masked):
  ///
  /// * Formatting (`TextMasker.formatSpans`: tags, entities, URLs, e-mail
  ///   addresses, placeholders; when `TranslationOptions.preserveFormatting`)
  ///   and, with [shield], personal data are replaced by [style] tokens and
  ///   put back afterwards. So are the terms of [glossary] (for engines that
  ///   cannot apply one: where `TranslationPrompts.glossaryOccurrences`
  ///   finds them, whole words only and never inside a URL, an e-mail
  ///   address, a tag or a placeholder), whose tokens get the terms'
  ///   renderings instead.
  ///   When the engine damages the tokens, the part is sent once more with
  ///   only the personal data masked (and plain when there is none): the
  ///   glossary is then not applied, which the checks report
  ///   ([TranslationWarningKind.glossary]). Personal data is never sent
  ///   unmasked: a lost token of it stays lost
  ///   ([TranslationWarningKind.personalDataLost]).
  /// * Input longer than [limit] characters is split at paragraphs
  ///   (`ParagraphChunker`) and translated [concurrency] parts at a time;
  ///   snapshots combine the parts (see `chunkedTranslation`).
  ///
  /// The final result has [TranslationResult.maskedPersonalData].
  Stream<TranslationResult> _machineTranslation(
    TranslationEngine engine,
    TranslationRequest request, {
    required bool shield,
    required MaskStyle style,
    required int limit,
    required int concurrency,
    required _Send send,
    Map<String, String> glossary = const {},
  }) {
    final report = _MaskReport();
    Stream<TranslationResult> one(TranslationRequest part) => _abortable(
      (abort) => _protectedRequest(
        part,
        shield: shield,
        glossary: glossary,
        style: style,
        report: report,
        send: (masked, {required isMasked}) =>
            send(masked, masked: isMasked, abort: abort, original: part),
      ),
    );
    final chunks = request.text.length > limit
        ? ParagraphChunker.split(request.text, maxChars: limit)
        : const <TextChunk>[];
    final results = chunks.length < 2
        ? one(request)
        : chunkedTranslation(
            engine: engine,
            request: request,
            chunks: chunks,
            translate: (chunk, _) => one(chunk),
            languageFor: _languageFor,
            concurrency: concurrency,
          );
    return results.map(
      (result) => result.isComplete ? report.applyTo(result) : result,
    );
  }

  /// One request of [request] with [send], its protected spans masked (see
  /// [_machineTranslation]).
  static Future<TranslationResult> _protectedRequest(
    TranslationRequest request, {
    required bool shield,
    required MaskStyle style,
    required _MaskReport report,
    required Future<TranslationResult> Function(
      TranslationRequest request, {
      required bool isMasked,
    })
    send,
    Map<String, String> glossary = const {},
  }) async {
    final personal = shield
        ? PersonalData.find(request.text)
        : const <ProtectedSpan>[];
    final formatting = request.options.preserveFormatting || glossary.isNotEmpty
        ? TextMasker.formatSpans(request.text)
        : const <ProtectedSpan>[];
    final format = request.options.preserveFormatting
        ? formatting
        : const <ProtectedSpan>[];
    final terms = [
      for (final term in TranslationPrompts.glossaryOccurrences(
        glossary,
        request.text,
        caseSensitive: request.options.caseSensitiveGlossaryTerms,
      ))
        // Never inside a URL, an e-mail address, a tag or a placeholder,
        // masked or not.
        if (!formatting.any((s) => s.start < term.end && term.start < s.end))
          ProtectedSpan(
            term.start,
            term.end,
            kind: ProtectedKind.glossary,
            replacement: term.rendering,
          ),
    ];
    if (personal.isEmpty && format.isEmpty && terms.isEmpty) {
      return await send(request, isMasked: false);
    }
    final masked = TextMasker.mask(request.text, [
      ...format,
      ...personal,
      ...terms,
    ], style: style);
    report.personal += masked.personalCount;
    final first = await send(
      request.copyWith(text: masked.text),
      isMasked: true,
    );
    final restored = masked.restore(first.text);
    if (restored.isComplete) return _restoredResult(first, restored, masked);
    if (masked.formatCount == 0 && masked.glossaryCount == 0) {
      // Only personal data is masked, and it never goes as it is.
      report.lost = true;
      return _restoredResult(first, restored, masked);
    }
    // The engine damaged the tokens: once more with only the personal data
    // masked.
    if (personal.isEmpty) return await send(request, isMasked: false);
    final personalOnly = TextMasker.mask(request.text, personal, style: style);
    final second = await send(
      request.copyWith(text: personalOnly.text),
      isMasked: true,
    );
    final again = personalOnly.restore(second.text);
    if (!again.isComplete) report.lost = true;
    return _restoredResult(second, again, personalOnly);
  }

  /// [result] of masked text with [restored] text (and its
  /// transliterations restored with [masked]; the source's with the text
  /// the tokens replaced, not the glossary renderings).
  static TranslationResult _restoredResult(
    TranslationResult result,
    RestoredText restored,
    MaskedText masked,
  ) => result.copyWith(
    text: restored.text,
    sourceTransliteration: result.sourceTransliteration.isEmpty
        ? null
        : masked.restore(result.sourceTransliteration, original: true).text,
    targetTransliteration: result.targetTransliteration.isEmpty
        ? null
        : masked.restore(result.targetTransliteration).text,
  );

  /// The checks after a translation ([TranslationQa]) for the final
  /// results of [results] (the translation of [request] by [engine]): their
  /// warnings are added to [TranslationResult.warnings]. Glossary targets
  /// are only checked for engines that use glossaries
  /// ([TranslationEngine.supportsGlossary]: AI engines with options, DeepL,
  /// and Mozhi and LibreTranslate, which get it applied on the device).
  /// With an on-device identifier, the output of a network engine is also
  /// checked for still being in the source language
  /// ([TranslationWarningKind.wrongLanguage]).
  Stream<TranslationResult> _checked(
    TranslationEngine engine,
    TranslationRequest request,
    Stream<TranslationResult> results,
  ) => results.asyncMap((result) async {
    if (!result.isComplete) return result;
    final warnings = [
      ...result.warnings,
      ...TranslationQa.check(
        source: request.text,
        output: result.text,
        sourceLanguage: request.source,
        target: request.target,
        detectedSource: result.detectedSource,
        glossary: engine.supportsGlossary ? request.options.glossary : const {},
        caseSensitiveGlossaryTerms: request.options.caseSensitiveGlossaryTerms,
        ai: engine.isAi,
      ),
    ];
    if (!warnings.any((warning) => warning.isSuspect) &&
        await _stayedInSourceLanguage(engine, request, result)) {
      warnings.add(
        const TranslationWarning(TranslationWarningKind.wrongLanguage),
      );
    }
    return warnings.isEmpty
        ? result
        : result.copyWith(warnings: List.unmodifiable(warnings));
  });

  /// Least letters of output [_stayedInSourceLanguage] identifies.
  static const _minIdentifiedLetters = 20;

  static final _letter = RegExp(r'\p{L}', unicode: true);

  /// Whether the on-device identifier finds [result] (of a network engine)
  /// still in the source language of [request] (explicit or detected),
  /// which is not the target: the engine ignored the target language.
  Future<bool> _stayedInSourceLanguage(
    TranslationEngine engine,
    TranslationRequest request,
    TranslationResult result,
  ) async {
    if (engine.isOffline ||
        request.target.isCustom ||
        request.source.isCustom ||
        !TranslationQa.checksSuspects(request.text)) {
      return false;
    }
    final from = request.source.isAuto
        ? result.detectedSource
        : request.source.code;
    if (from == null || _sameLanguage(from, request.target.code)) return false;
    if (_letter.allMatches(result.text).length < _minIdentifiedLetters) {
      return false;
    }
    final code = await _identifyOnDevice(result.text);
    return code != null &&
        _sameLanguage(code, from) &&
        !_sameLanguage(code, request.target.code);
  }

  /// [results] with [destination] where they have none yet.
  static Stream<TranslationResult> _withDestination(
    Stream<TranslationResult> results,
    DataDestination? destination,
  ) {
    if (destination == null) return results;
    return results.map(
      (result) => result.destination == null
          ? result.copyWith(destination: destination)
          : result,
    );
  }

  /// A single-result stream whose cancellation completes the abort trigger
  /// passed to [run].
  static Stream<T> _abortable<T>(Future<T> Function(Future<void> abort) run) {
    final abort = Completer<void>();
    late final StreamController<T> controller;
    controller = StreamController<T>(
      onListen: () {
        Future.sync(() => run(abort.future))
            .then(
              (value) {
                if (controller.isClosed) return;
                controller.add(value);
                unawaited(controller.close());
              },
              onError: (Object error, StackTrace stackTrace) {
                if (controller.isClosed) return;
                controller.addError(error, stackTrace);
                unawaited(controller.close());
              },
            )
            .ignore();
      },
      onCancel: () {
        if (!abort.isCompleted) abort.complete();
      },
    );
    return controller.stream;
  }

  /// Completing [abort] (the subscription was cancelled, e.g. the input
  /// changed) cancels the request, which is not sent to another instance
  /// then.
  Future<TranslationResult> _translateMozhi(
    TranslationEngine engine,
    TranslationRequest request, {
    Future<void>? abort,
  }) async {
    _checkMozhiLanguages(request.source, request.target);
    final id = mozhiEngineId(engine);
    final stopwatch = Stopwatch()..start();
    final (translation, instance) = await _mozhi.run(
      (client, instance) async {
        final result = await client.translate(
          engine: id,
          from: request.source.code,
          to: mozhiTargetCode(id, request.target.code),
          text: request.text,
          abortTrigger: abort,
        );
        if (result.translatedText.trim().isEmpty) {
          // DeepL (DeepLX) reports upstream failures as 200 with an empty
          // text (mozhi-contract G2); DeepLX limits are per instance.
          throw MozhiApiException(
            '${engine.name} returned an empty translation.',
            statusCode: 502,
          );
        }
        return (result, instance);
      },
      failOverOnTimeout: false,
      allow: _mozhiFailoverAllowed,
    );
    return mapMozhiTranslation(
      engine,
      request,
      translation,
      elapsed: stopwatch.elapsed,
    ).copyWith(destination: _mozhiDestination(id, instance));
  }

  /// With [shield], personal data is masked before the text (and its
  /// context, tone notes and instructions) goes to the model and put back
  /// into every snapshot (see [maskPersonalData]).
  /// General-profile models get a default temperature
  /// ([_defaultTemperature]) and, when a part's translation fails the
  /// checks worth it ([TranslationQa.worthRetrying]), one more attempt
  /// with a corrective note ([_retriedOnce]).
  Stream<TranslationResult> _translateAi(
    TranslationEngine engine,
    TranslationRequest request, {
    bool shield = false,
    bool refresh = false,
  }) {
    final config = _configFor(engine, 'ai:');
    if (config == null || config.isMtService) {
      return Stream.error(
        ArgumentError.value(engine.id, 'engine', 'Unknown AI provider'),
      );
    }
    // The text and its free-text options share one set of tokens.
    final sent = _shieldRequest(
      shield ? _providerDestination(config) : null,
      request,
    );
    final masked = sent.shield.masked;
    final work = sent.request;
    final profile = config.resolvedPromptProfile;
    final results = profile.isTranslationOnly
        ? _translateWithMtProfile(
            engine,
            config,
            profile,
            work,
            refresh: refresh,
          )
        : _inChunks(
            engine,
            config,
            work,
            (chunk, context) => _retriedOnce(
              engine: engine,
              chunk: chunk,
              open: (extra) => _streamTranslation(config, [
                ...TranslationPrompts.translate(
                  chunk,
                  precedingText: context.precedingText,
                  precedingTranslation: context.precedingTranslation,
                  earlierTerms: context.terms,
                ),
                ...extra,
              ]),
            ),
            refresh: refresh,
          );
    return masked == null ? results : _unmasked(results, masked);
  }

  /// [results] of masked text with the tokens of [masked] put back (into
  /// every snapshot); final results get
  /// [TranslationResult.maskedPersonalData] and, when a token of personal
  /// data was lost, [TranslationWarningKind.personalDataLost].
  static Stream<TranslationResult> _unmasked(
    Stream<TranslationResult> results,
    MaskedText masked,
  ) => results.map((result) {
    final restored = masked.restore(result.text);
    if (!result.isComplete) return result.copyWith(text: restored.text);
    return result.copyWith(
      text: restored.text,
      maskedPersonalData: masked.personalCount,
      warnings: restored.lostPersonalData
          ? List.unmodifiable([
              ...result.warnings,
              const TranslationWarning(TranslationWarningKind.personalDataLost),
            ])
          : null,
    );
  });

  /// Default temperature of AI translations (see [_defaultTemperature]):
  /// low, for faithful and consistent output (providers default to about
  /// 1.0).
  static const defaultAiTemperature = 0.2;

  /// Reasoning models, which reject or ignore sampling parameters (OpenAI
  /// o-series and GPT-5, DeepSeek R1 / reasoner, QwQ, "thinking" models).
  static final _reasoningModel = RegExp(
    r'(?:^|[/:])(?:o\d(?:-|$)|gpt-5)|reasoner|thinking|qwq|'
    r'(?:^|[/:\-])r1(?:[\-:]|$)',
    caseSensitive: false,
  );

  /// The temperature a translation with [config] gets when its provider
  /// sets none: [defaultAiTemperature] for models known to accept it; null
  /// (the provider's default) for Anthropic, reasoning models, providers
  /// with a reasoning effort and providers that rejected it before.
  double? _defaultTemperature(AiProviderConfig config) {
    if (config.provider == LlmProvider.anthropic ||
        config.effort != null ||
        _rejectsTemperature.contains(config.id) ||
        _reasoningModel.hasMatch(config.model.trim())) {
      return null;
    }
    return defaultAiTemperature;
  }

  /// The streamed reply to a translation request of [messages] with
  /// [config] at the default temperature ([_defaultTemperature]). When the
  /// server rejects the request (HTTP 400) before any text, it is sent once
  /// more without the temperature, which the provider then never gets
  /// again this session.
  Stream<String> _streamTranslation(
    AiProviderConfig config,
    List<LlmMessage> messages,
  ) {
    final client = _llm.clientFor(config);
    final temperature = config.temperature == null
        ? _defaultTemperature(config)
        : null;
    final request = _llmRequest(
      config,
      messages,
      defaultTemperature: temperature,
    );
    if (temperature == null) return client.streamChat(request);
    late final StreamController<String> controller;
    StreamSubscription<String>? subscription;
    var received = false;
    void listen(LlmRequest request, {required bool retry}) {
      subscription = client
          .streamChat(request)
          .listen(
            (delta) {
              received = true;
              controller.add(delta);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (retry &&
                  !received &&
                  error is LlmApiException &&
                  error.statusCode == 400) {
                _rejectsTemperature.add(config.id);
                listen(_withoutTemperature(request), retry: false);
                return;
              }
              controller.addError(error, stackTrace);
              unawaited(controller.close());
            },
            onDone: controller.close,
            cancelOnError: true,
          );
    }

    controller = StreamController<String>(
      onListen: () => listen(request, retry: true),
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  static LlmRequest _withoutTemperature(LlmRequest request) => LlmRequest(
    model: request.model,
    messages: request.messages,
    maxTokens: request.maxTokens,
    jsonOutput: request.jsonOutput,
    effort: request.effort,
    contextWindow: request.contextWindow,
    topP: request.topP,
    topK: request.topK,
    repeatPenalty: request.repeatPenalty,
    stop: request.stop,
  );

  /// The translation of [chunk] streamed from [open] (no extra messages),
  /// checked when complete ([TranslationQa.check]). When the checks find
  /// problems worth it ([TranslationQa.worthRetrying]), the model gets one
  /// more attempt, like the JSON retry: its reply and a short corrective
  /// note ([TranslationQa.correctiveNote]) are added to the conversation.
  /// That attempt's snapshots follow; the stream ends with the better of
  /// both results (fewer problems; the second on a tie), or with the first
  /// when the second fails.
  Stream<TranslationResult> _retriedOnce({
    required TranslationEngine engine,
    required TranslationRequest chunk,
    required Stream<String> Function(List<LlmMessage> extra) open,
  }) {
    late final StreamController<TranslationResult> controller;
    StreamSubscription<TranslationResult>? subscription;
    TranslationResult? first;
    var firstScore = 0;

    List<TranslationWarning> problems(TranslationResult result) => [
      for (final warning in TranslationQa.check(
        source: chunk.text,
        output: result.text,
        sourceLanguage: chunk.source,
        target: chunk.target,
        detectedSource: result.detectedSource,
        glossary: chunk.options.glossary,
        caseSensitiveGlossaryTerms: chunk.options.caseSensitiveGlossaryTerms,
        ai: true,
      ))
        if (TranslationQa.worthRetrying([warning])) warning,
    ];
    int score(List<TranslationWarning> warnings) =>
        warnings.fold(0, (sum, w) => sum + (w.isSuspect ? 2 : 1));

    void finish(TranslationResult result) {
      if (controller.isClosed) return;
      controller.add(result);
      unawaited(controller.close());
    }

    void attempt(List<LlmMessage> extra) {
      final retry = extra.isNotEmpty;
      subscription =
          aiTranslationStream(
            open: () => open(extra),
            engine: engine,
            request: chunk,
            snapshotInterval: _snapshotInterval,
          ).listen(
            (result) {
              if (!result.isComplete) {
                controller.add(result);
                return;
              }
              final found = problems(result);
              if (retry) {
                final previous = first!;
                final better = score(found) <= firstScore ? result : previous;
                finish(
                  better.copyWith(
                    detectedSource:
                        better.detectedSource ?? previous.detectedSource,
                  ),
                );
                return;
              }
              if (found.isEmpty || !TranslationQa.worthRetrying(found)) {
                finish(result);
                return;
              }
              first = result;
              firstScore = score(found);
              attempt([
                if (result.text.trim().isNotEmpty)
                  LlmMessage.assistant(result.text),
                LlmMessage.user(
                  TranslationQa.correctiveNote(found, target: chunk.target),
                ),
              ]);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (retry) {
                finish(first!);
                return;
              }
              if (controller.isClosed) return;
              controller.addError(error, stackTrace);
              unawaited(controller.close());
            },
            cancelOnError: true,
          );
    }

    controller = StreamController<TranslationResult>(
      onListen: () => attempt(const []),
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  /// The longest AI input of [engine] with [config] that is sent in one
  /// request (see the constructor).
  int _chunkLimit(TranslationEngine engine, AiProviderConfig config) =>
      config.isOnDevice
      ? _onDeviceAiChunkThreshold
      : engine.isLocal || config.isLocal
      ? _localAiChunkThreshold
      : _aiChunkThreshold;

  /// [translate] applied to [request] (with an empty context), or to the
  /// parts of its text when it is longer than the chunk threshold of
  /// [config] (see the constructor and [chunkedTranslation]: each part with
  /// its [ChunkContext], parts served from and stored in the part cache
  /// unless [refresh]).
  Stream<TranslationResult> _inChunks(
    TranslationEngine engine,
    AiProviderConfig config,
    TranslationRequest request,
    Stream<TranslationResult> Function(
      TranslationRequest chunk,
      ChunkContext context,
    )
    translate, {
    bool refresh = false,
  }) {
    final limit = _chunkLimit(engine, config);
    if (request.text.length <= limit) {
      return translate(request, const ChunkContext());
    }
    final chunks = ParagraphChunker.split(request.text, maxChars: limit);
    if (chunks.length < 2) return translate(request, const ChunkContext());
    return chunkedTranslation(
      engine: engine,
      request: request,
      chunks: chunks,
      translateInContext: translate,
      languageFor: _languageFor,
      cache: _chunkCache,
      refresh: refresh,
    );
  }

  Stream<TranslationResult> _translateWithMtProfile(
    TranslationEngine engine,
    AiProviderConfig config,
    PromptProfile profile,
    TranslationRequest request, {
    bool refresh = false,
  }) async* {
    if (request.source.isCustom || request.target.isCustom) {
      final custom = request.source.isCustom ? request.source : request.target;
      throw ArgumentError.value(
        custom.code,
        request.source.isCustom ? 'source' : 'target',
        '${engine.name} only translates between real languages',
      );
    }
    String? detected;
    var explicit = request;
    if (request.source.isAuto) {
      detected = await _detectSource(
        engine,
        request.text,
        isLocal: engine.isLocal || config.isLocal,
        target: request.target.code,
      );
      explicit = request.copyWith(source: _languageFor(detected));
    }
    if (LanguageMatcher.normalize(explicit.source.code) ==
        LanguageMatcher.normalize(explicit.target.code)) {
      // Nothing to translate; do not spend a generation on an echo.
      yield TranslationResult(
        engineId: engine.id,
        engineName: engine.name,
        text: request.text,
        detectedSource: detected,
        elapsed: Duration.zero,
      );
      return;
    }
    final sampling = MtPrompts.sampling(profile);
    yield* _inChunks(
      engine,
      config,
      explicit,
      // The templates of translation-specialised models take no context.
      (chunk, _) => aiTranslationStream(
        open: () => _llm
            .clientFor(config)
            .streamChat(
              _llmRequest(
                config,
                MtPrompts.translate(profile, chunk),
                sampling: sampling,
              ),
            ),
        engine: engine,
        request: chunk,
        snapshotInterval: _snapshotInterval,
        parseMarker: false,
        detectedSource: detected,
      ),
      refresh: refresh,
    );
  }

  static Language _languageFor(String code) =>
      LanguageCatalog.byCode(code) ??
      Language(code: code, name: LanguageCatalog.nameOf(code));

  /// The language of [text] for an engine that needs an explicit source:
  /// on-device identification first (private), then Mozhi google unless
  /// the engine [isLocal] (the user keeps that text off the network) or the
  /// privacy settings do not let the text (translated into [target]) go to
  /// the Mozhi instance on their own: an approval of the engine's own
  /// destination ([allowOnce]) does not cover another destination. Mozhi
  /// instances the settings do not allow are skipped (the failure is the
  /// [ConsentRequiredException]).
  Future<String> _detectSource(
    TranslationEngine engine,
    String text, {
    required bool isLocal,
    required String target,
  }) async {
    Object? failure;
    final offline = _offline;
    if (offline != null && offline.isAvailable) {
      try {
        final code = normalizeDetected(
          await offline.translator.identifyLanguage(text),
        );
        if (code != null) return code;
      } on Object catch (error) {
        failure = error;
      }
    }
    final active = _mozhi.active;
    if (!isLocal && active != null) {
      final denied = _denial(
        _mozhiDestination(_detectionEngine),
        engineId: 'mozhi:$_detectionEngine',
        source: Language.auto.code,
        target: target,
        useGrants: false,
      );
      if (denied != null) {
        failure = denied;
      } else {
        try {
          return (await _detectWithMozhi(text)).code;
        } on Object catch (error) {
          failure = error;
        }
      }
    }
    throw SourceLanguageRequiredException(engineId: engine.id, cause: failure);
  }

  /// The Mozhi engine that detects languages.
  static const _detectionEngine = 'google';

  /// The Mozhi engine that translates images.
  static const _imageEngine = 'google';

  /// How long a Mozhi image translation may take ([translateImage]): the
  /// upload, Google's answer and the image Mozhi sends back all have to fit
  /// in it, so it is longer than the instance's request timeout.
  static const mozhiImageTimeout = Duration(seconds: 90);

  /// Most Mozhi instances one image is sent to ([translateImage]): the
  /// preferred instance and one failover. Every attempt uploads the whole
  /// photo again, to another operator.
  static const maxImageInstances = 2;

  /// What [translateImage] reports (as a retryable `MozhiApiException`,
  /// status 502) when Mozhi answered without an image and without text: it
  /// passes Google's answer on without checking it, so a refusal looks
  /// like this (and so does a photo Google found no text in).
  static const imageNoResultMessage =
      'Google returned no result for the image.';

  /// Most words of input that gets a second language detection.
  static const _hintMaxWords = 3;

  /// Most characters of such input (scripts without spaces).
  static const _hintMaxChars = 64;

  /// Whether [request] (sanitised) gets a second language detection: short
  /// text with an auto source on a cloud AI engine that can run the
  /// detection prompt. Local models usually serve one request at a time, so
  /// a second one would delay the translation.
  bool _wantsDetectionHint(
    TranslationEngine engine,
    TranslationRequest request,
  ) {
    if (!request.source.isAuto || !engine.supportsExtras || engine.isLocal) {
      return false;
    }
    final config = _configFor(engine, 'ai:');
    if (config == null ||
        config.isMtService ||
        config.isLocal ||
        config.resolvedPromptProfile.isTranslationOnly) {
      return false;
    }
    final text = request.text.trim();
    return text.length <= _hintMaxChars &&
        text.split(RegExp(r'\s+')).length <= _hintMaxWords;
  }

  /// Forwards [translation] and adds a second opinion on the language of
  /// `request.text` to its final result (see [translate]). [onVerdict]
  /// gets that final result when an opinion arrived in time.
  ///
  /// The device answers first ([OfflineTranslator.identifyLanguage], no
  /// request): when it names the language the model marked, that is the
  /// verdict. The [detectLanguage] prompt only runs when the device is
  /// unsure (or has no identifier) or disagrees with the model's marker; it
  /// is best effort: streamed (so that cancelling the returned stream, and
  /// giving up after `detectionHintTimeout`, abort the request), without
  /// reasoning effort and without a retry for invalid JSON; its failures
  /// are ignored. When the model is not asked and the device disagreed, the
  /// result is marked uncertain with the device's language as the
  /// alternative (and not stored). With the personal data shield, the
  /// detection gets the masked text.
  Stream<TranslationResult> _withDetectionHint(
    TranslationEngine engine,
    TranslationRequest request,
    Stream<TranslationResult> translation, {
    required void Function(TranslationResult result) onVerdict,
  }) {
    late final StreamController<TranslationResult> controller;
    StreamSubscription<TranslationResult>? subscription;
    StreamSubscription<String>? detecting;
    DetectedLanguage? detection;
    var translated = false;
    var askedModel = false;
    TranslationResult? held;
    TranslationResult? lastPartial;
    Timer? timer;
    final offline = _offline;
    final onDevice = offline != null && offline.isAvailable;
    // The device's opinion: pending until it answered (null: unsure).
    var deviceAnswered = !onDevice;
    String? device;
    String? marked;

    bool agrees(String? shown) =>
        device != null && shown != null && _sameLanguage(device!, shown);

    void stopDetecting() {
      unawaited(detecting?.cancel());
      detecting = null;
    }

    void emitFinal(TranslationResult result) {
      final verdict = detection;
      if (verdict != null) {
        final last = _withDetectionVerdict(result, verdict, request);
        controller.add(last);
        onVerdict(last);
      } else if (agrees(result.detectedSource)) {
        controller.add(result);
        onVerdict(result);
      } else if (device != null) {
        // The model was not asked in time: the device's doubt stands.
        controller.add(
          _withDetectionVerdict(
            result,
            DetectedLanguage(code: device!),
            request,
          ),
        );
      } else {
        controller.add(result);
      }
    }

    void release() {
      timer?.cancel();
      timer = null;
      final result = held;
      held = null;
      if (result == null || controller.isClosed) return;
      // A detection that has not answered by now is no longer needed.
      stopDetecting();
      emitFinal(result);
      if (translated) unawaited(controller.close());
    }

    void detected(String output) {
      detecting = null;
      try {
        detection = ResponseParsers.parseDetectedLanguage(output);
      } on Object {
        // Best effort: no hint.
      }
      release();
    }

    void askModel() {
      if (askedModel || controller.isClosed) return;
      askedModel = true;
      try {
        final config = _extrasProviderFor(engine);
        final output = StringBuffer();
        detecting = _llm
            .clientFor(config)
            .streamChat(
              _llmRequest(
                config,
                TranslationPrompts.detectLanguage(
                  _shielded(request.text, _destinationFor(engine)),
                ),
                jsonOutput: true,
                withEffort: false,
              ),
            )
            .listen(
              output.write,
              onError: (Object _) {
                detecting = null;
                release();
              },
              onDone: () => detected(output.toString()),
              cancelOnError: true,
            );
      } on Object {
        detecting = null;
      }
    }

    /// Whether the final result must wait (for the device or the model).
    bool waiting() => !deviceAnswered || detecting != null;

    void onDeviceAnswer(String? code) {
      if (deviceAnswered || controller.isClosed) return;
      deviceAnswered = true;
      device = code;
      final shown = held?.detectedSource ?? marked;
      if (code == null ||
          (shown != null && !agrees(shown)) ||
          (held != null && shown == null)) {
        askModel();
      }
      if (held != null && !waiting()) release();
    }

    void onResult(TranslationResult result) {
      if (result.detectedSource case final code?) marked = code;
      if (!result.isComplete) {
        lastPartial = result;
        controller.add(result);
        // The marker came early: ask the model now when the device
        // disagrees.
        if (deviceAnswered &&
            device != null &&
            marked != null &&
            !agrees(marked)) {
          askModel();
        }
        return;
      }
      release();
      if (deviceAnswered && device != null && !agrees(result.detectedSource)) {
        askModel();
      }
      if (!waiting()) {
        emitFinal(result);
        return;
      }
      // Show the finished text now; completion waits for the detection.
      final partial = result.copyWith(isComplete: false);
      if (lastPartial?.text != partial.text ||
          lastPartial?.detectedSource != partial.detectedSource) {
        controller.add(partial);
      }
      held = result;
      timer = Timer(_detectionHintTimeout, release);
    }

    controller = StreamController<TranslationResult>(
      onListen: () {
        subscription = translation.listen(
          onResult,
          onError: controller.addError,
          onDone: () {
            translated = true;
            if (held != null) return;
            stopDetecting();
            unawaited(controller.close());
          },
        );
        // Started after the translation, which they must never hold up.
        if (onDevice) {
          offline.translator
              .identifyLanguage(request.text)
              .then(
                (code) => onDeviceAnswer(normalizeDetected(code)),
                onError: (Object _) => onDeviceAnswer(null),
              )
              .ignore();
        } else {
          askModel();
        }
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        timer?.cancel();
        held = null;
        deviceAnswered = true;
        stopDetecting();
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// [result] marked as uncertain when [detection] is unsure, names other
  /// likely languages or disagrees with `result.detectedSource`.
  static TranslationResult _withDetectionVerdict(
    TranslationResult result,
    DetectedLanguage? detection,
    TranslationRequest request,
  ) {
    if (detection == null) return result;
    final shown = result.detectedSource;
    final detected = normalizeDetected(detection.code);
    final disagrees =
        shown != null && detected != null && !_sameLanguage(detected, shown);
    final candidates = <String>[];
    void add(String code) {
      final normalized = normalizeDetected(code);
      if (normalized == null ||
          (shown != null && _sameLanguage(normalized, shown)) ||
          candidates.any((c) => _sameLanguage(c, normalized))) {
        return;
      }
      candidates.add(normalized);
    }

    detection.alternatives.forEach(add);
    final hasAlternatives = candidates.isNotEmpty;
    if (!detection.isUncertain && !disagrees && !hasAlternatives) {
      return result;
    }
    if (shown == null || disagrees) {
      candidates.clear();
      add(detection.code);
      detection.alternatives.forEach(add);
    }
    final recent = [
      for (final code in request.recentSourceLanguages)
        ...candidates.where((c) => _sameLanguage(c, code)),
    ];
    final ordered = {...recent, ...candidates};
    return result.copyWith(
      detectionUncertain: true,
      detectedAlternatives: List.unmodifiable(ordered.take(3)),
    );
  }

  /// Whether two language codes name the same language (ignoring region
  /// and script).
  static bool _sameLanguage(String a, String b) =>
      _primarySubtag(a) == _primarySubtag(b);

  static String _primarySubtag(String code) =>
      LanguageMatcher.normalize(code).split('-').first.toLowerCase();

  /// Runs [engines] concurrently and emits a [CompareEntry] per engine as
  /// soon as it finishes (only final results; failures as
  /// `CompareEntry.failure`). Every engine is translated on its own, like
  /// [translate] (so results come from and go to the cache; short input
  /// gets no second language detection): Mozhi engines get one
  /// single-engine request each, because `engine=all` and comma-separated
  /// lists crash Mozhi servers whose DuckDuckGo upstream is
  /// unreachable (mozhi-contract G1) and drop failures silently.
  Stream<CompareEntry> compare(
    List<TranslationEngine> engines,
    TranslationRequest request, {
    bool refresh = false,
  }) {
    final unique = {for (final engine in engines) engine.id: engine}.values;
    if (request.text.trim().isEmpty || unique.isEmpty) {
      return const Stream.empty();
    }
    final subscriptions = <StreamSubscription<TranslationResult>>[];
    late final StreamController<CompareEntry> controller;
    var cancelled = false;

    void emit(CompareEntry entry) {
      if (!cancelled && !controller.isClosed) controller.add(entry);
    }

    // Only the final result of an AI stream is complete; every stream
    // closes after an error.
    Future<void> run(TranslationEngine engine) {
      final completer = Completer<void>();
      var reported = false;
      void report(CompareEntry entry) {
        if (reported) return;
        reported = true;
        emit(entry);
      }

      subscriptions.add(
        _translate(engine, request, refresh: refresh, detectionHint: false)
            .where((result) => result.isComplete)
            .listen(
              (result) => report(CompareEntry.success(result)),
              onError: (Object error) => report(
                CompareEntry.failure(
                  engineId: engine.id,
                  engineName: engine.name,
                  error: error,
                ),
              ),
              onDone: completer.complete,
            ),
      );
      return completer.future;
    }

    controller = StreamController<CompareEntry>(
      onListen: () {
        unawaited(
          Future.wait(unique.map(run)).whenComplete(() {
            if (!controller.isClosed) unawaited(controller.close());
          }),
        );
      },
      onCancel: () async {
        cancelled = true;
        await Future.wait([
          for (final subscription in subscriptions) subscription.cancel(),
        ]);
      },
    );
    return controller.stream;
  }

  /// With the personal data shield (see [maskPersonalData]) the request,
  /// [translation] and [span] are masked together, and the alternatives and
  /// explanations get the values back.
  Future<AlternativeTranslations> getAlternatives(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    int count = 3,
    String? span,
    String uiLanguage = 'English',
  }) {
    final sent = _shieldRequest(_destinationFor(engine), request, [
      translation,
      ?span,
    ]);
    return _chatJson(
      engine,
      () => sent.shield.withNote(
        TranslationPrompts.alternatives(
          sent.request,
          sent.extra.first,
          count: count,
          span: span == null ? null : sent.extra.last,
          uiLanguage: uiLanguage,
        ),
      ),
      (output) =>
          ResponseParsers.parseAlternatives(sent.shield.restore(output)),
      source: request.source.code,
      target: request.target.code,
    );
  }

  /// With the personal data shield (see [maskPersonalData]) the request and
  /// [translation] are masked together; the insights get the values back
  /// (and are located in the unmasked [translation]).
  Future<List<WordInsight>> getInsights(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    String uiLanguage = 'English',
  }) {
    final sent = _shieldRequest(_destinationFor(engine), request, [
      translation,
    ]);
    return _chatJson(
      engine,
      () => sent.shield.withNote(
        TranslationPrompts.insights(
          sent.request,
          sent.extra.single,
          uiLanguage: uiLanguage,
        ),
      ),
      (output) => ResponseParsers.parseInsights(
        sent.shield.restore(output),
        translation: translation,
      ),
      source: request.source.code,
      target: request.target.code,
    );
  }

  /// With the personal data shield (see [maskPersonalData]) the request and
  /// [translation] are masked together; the suggestions get the values
  /// back ([refine] masks their instructions again).
  Future<List<RefinementSuggestion>> getSuggestions(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    String uiLanguage = 'English',
  }) {
    final sent = _shieldRequest(_destinationFor(engine), request, [
      translation,
    ]);
    return _chatJson(
      engine,
      () => sent.shield.withNote(
        TranslationPrompts.suggestions(
          sent.request,
          sent.extra.single,
          uiLanguage: uiLanguage,
        ),
      ),
      (output) => ResponseParsers.parseSuggestions(sent.shield.restore(output)),
      source: request.source.code,
      target: request.target.code,
    );
  }

  /// Streams Markdown as text deltas (concatenate them for the full text).
  /// Requires an AI engine with [TranslationEngine.supportsExtras] (an
  /// [ArgumentError] stream error otherwise). With the personal data
  /// shield (see [maskPersonalData]) the request, [translation] and
  /// [question] are masked together, and the deltas get the values back (a
  /// token split across deltas comes with the next one).
  Stream<String> explain(
    TranslationEngine engine,
    TranslationRequest request,
    String translation, {
    String? question,
    String uiLanguage = 'English',
  }) async* {
    final config = _extrasProviderFor(engine);
    _ensureAllowed(
      engine,
      source: request.source.code,
      target: request.target.code,
    );
    final sent = _shieldRequest(_destinationFor(engine), request, [
      translation,
      ?question,
    ]);
    yield* sent.shield.restoreDeltas(
      _llm
          .clientFor(config)
          .streamChat(
            _llmRequest(
              config,
              sent.shield.withNote(
                TranslationPrompts.explain(
                  sent.request,
                  sent.extra.first,
                  question: question == null ? null : sent.extra.last,
                  uiLanguage: uiLanguage,
                ),
              ),
            ),
          ),
    );
  }

  /// A dictionary entry for [word] (definitions in [uiLanguage],
  /// translations into [target]). [verbosity] sets how many senses,
  /// examples and notes are asked for. [DictionaryEntry.didYouMean] holds
  /// the corrected spelling when [word] looks misspelled. With the
  /// personal data shield (see [maskPersonalData]) [word] and [context] are
  /// masked together, the entry gets the values back and says how many
  /// items stayed on the device ([DictionaryEntry.maskedPersonalData]).
  Future<DictionaryEntry> lookUp(
    TranslationEngine engine,
    String word, {
    required Language source,
    required Language target,
    String context = '',
    String uiLanguage = 'English',
    DictionaryVerbosity verbosity = DictionaryVerbosity.standard,
  }) {
    final shield = _shieldTexts(_destinationFor(engine), [word, context]);
    return _chatJson(
      engine,
      () => shield.withNote(
        TranslationPrompts.dictionary(
          shield.texts[0],
          source: source,
          targetLanguage: target,
          context: shield.texts[1],
          uiLanguage: uiLanguage,
          verbosity: verbosity,
        ),
      ),
      (output) {
        final entry = ResponseParsers.parseDictionary(
          shield.restore(output),
          query: word,
        );
        return shield.personalCount == 0
            ? entry
            : entry.withMaskedPersonalData(shield.personalCount);
      },
      source: source.code,
      target: target.code,
    );
  }

  // Round 3 extras.

  /// Revises [currentTranslation] of [request] according to [instruction]
  /// ("More formal", "Shorter", a suggestion's instruction, ...) instead of
  /// translating again: the model makes minimal edits and keeps the
  /// meaning, glossary terms, formatting and placeholders (see
  /// `TranslationPrompts.refine`).
  ///
  /// Streams snapshots exactly like [translate] for AI engines (growing
  /// `isComplete: false` snapshots, then one `isComplete: true` result
  /// cleaned with `ResponseParsers.cleanTranslation`; `detectedSource` from
  /// the `[[lang:xx]]` marker when the source is auto). Results are never
  /// cached. Empty/whitespace [TranslationRequest.text] emits nothing.
  ///
  /// Errors are stream errors: an [ArgumentError] for engines that are not
  /// AI engines, unknown providers, a blank [instruction] or
  /// [currentTranslation], or an empty custom language name; an
  /// [UnsupportedError] for translation-specialised models
  /// ([TranslationEngine.usesMtProfile]: TranslateGemma, Hy-MT), which
  /// cannot follow instructions, and when the text or [currentTranslation]
  /// is longer than the provider's chunk threshold (see the constructor):
  /// [translate] splits such text into parts, but a refinement needs the
  /// whole text and translation in one request, which would overflow the
  /// small context windows of local models (in both cases re-translate
  /// with [translate] and the instruction instead); provider errors as-is.
  /// Cancelling the subscription cancels the HTTP request.
  Stream<TranslationResult> refine(
    TranslationEngine engine,
    TranslationRequest request, {
    required String currentTranslation,
    required String instruction,
  }) async* {
    if (request.text.trim().isEmpty) return;
    final config = _aiProviderFor(engine);
    if (config.resolvedPromptProfile.isTranslationOnly) {
      throw UnsupportedError(
        '${engine.name} only supports plain translation and cannot refine '
        'a translation; translate again instead.',
      );
    }
    final limit = _chunkLimit(engine, config);
    if (request.text.length > limit || currentTranslation.length > limit) {
      throw UnsupportedError(
        'The text is too long for ${engine.name} to refine in one request; '
        'translate it again instead.',
      );
    }
    final sanitized = _sanitizeRequest(request);
    if (sanitized == null) throw _emptyCustomLanguage(request);
    final safe = _withSavedGlossaries(sanitized);
    _ensureAllowed(engine, source: safe.source.code, target: safe.target.code);
    final destination = _destinationFor(engine);
    // The text, its options, its translation and the instruction (which
    // may come from a suggestion) share one set of tokens.
    final sent = _shieldRequest(destination, safe, [
      currentTranslation,
      instruction,
    ]);
    final masked = sent.shield.masked;
    final work = sent.request;
    final messages = TranslationPrompts.refine(
      work,
      currentTranslation: sent.extra.first,
      instruction: sent.extra.last,
    );
    final results = aiTranslationStream(
      open: () => _streamTranslation(config, messages),
      engine: engine,
      request: work,
      snapshotInterval: _snapshotInterval,
    );
    yield* _withDestination(
      masked == null ? results : _unmasked(results, masked),
      destination,
    );
  }

  /// Joins two texts that are masked together (no personal data pattern
  /// matches across it).
  static const _pairSeparator = '\u0000';

  /// [text] (in [language], which may be auto) in the Latin script, using
  /// the standard romanization of the language (`TranslationPrompts
  /// .romanizationSystem`: Hepburn, Hanyu Pinyin with tone marks, Revised
  /// Romanization, ISO 15919 / IAST, ALA-LC, ...), with line breaks kept.
  ///
  /// Text without letters of a non-Latin script
  /// (`LanguageCatalog.hasNonLatinLetters`) is returned unchanged without a
  /// request; use `LanguageCatalog.usesNonLatinScript` to decide when to
  /// offer romanization. Text longer than the provider's chunk threshold
  /// (see the constructor) is romanized in parts, one request after the
  /// other, split like [translate] splits long input (parts without
  /// non-Latin letters are kept as they are). Requires an AI engine with
  /// [TranslationEngine.supportsExtras] ([ArgumentError] otherwise). An
  /// empty reply is an `LlmApiException`. With the personal data shield
  /// (see [maskPersonalData]) the text is masked before it is split, and
  /// the romanization gets the values back.
  Future<String> romanize(
    TranslationEngine engine, {
    required String text,
    required Language language,
  }) async {
    final config = _extrasProviderFor(engine);
    if (!LanguageCatalog.hasNonLatinLetters(text)) return text;
    _ensureAllowed(engine, source: language.code, target: language.code);
    final shield = _shieldTexts(_destinationFor(engine), [text]);
    final sent = shield.texts.single;
    final limit = _chunkLimit(engine, config);
    final chunks = sent.length > limit
        ? ParagraphChunker.split(sent, maxChars: limit)
        : const <TextChunk>[];
    if (chunks.length < 2) {
      return shield.restore(await _romanize(config, sent, language, shield));
    }
    final parts = <String>[];
    for (final chunk in chunks) {
      parts.add(
        LanguageCatalog.hasNonLatinLetters(chunk.text)
            ? await _romanize(config, chunk.text, language, shield)
            : chunk.text,
      );
    }
    return shield.restore(ParagraphChunker.joinTranslations(chunks, parts));
  }

  /// [text] romanized in one request (see [romanize]), with the note of
  /// [shield] about its tokens.
  Future<String> _romanize(
    AiProviderConfig config,
    String text,
    Language language,
    _Shield shield,
  ) async {
    final output = await _llm
        .clientFor(config)
        .chat(
          _llmRequest(
            config,
            shield.withNote(
              TranslationPrompts.romanize(text, language: language),
            ),
          ),
        );
    final romanized = ResponseParsers.cleanRomanization(output, source: text);
    if (romanized.trim().isEmpty) {
      throw const LlmApiException('The model returned an empty response.');
    }
    return romanized;
  }

  /// The sentences of [translation] (of [source]) the on-device [engine] is
  /// unsure about (`OfflineSentence.isLowConfidence`), as the sentence in
  /// [source] and its range in [translation], in order.
  ///
  /// The text is translated again on the device with details (instant:
  /// the engine caches its sentences); nothing leaves the device and
  /// nothing is counted. Empty when the translator cannot tell (it is not a
  /// [DetailedOfflineTranslator]), for blank texts and identical
  /// languages. Only for the on-device engine ([ArgumentError] for other
  /// engines); language errors are those of its translations.
  Future<List<AlignedSpan>> lowConfidenceSentences(
    TranslationEngine engine, {
    required String source,
    required String translation,
    required Language sourceLanguage,
    required Language targetLanguage,
  }) async => await lowConfidenceOffline(
    _offlineFor(engine),
    engine,
    source: source,
    translation: translation,
    sourceLanguage: sourceLanguage,
    targetLanguage: targetLanguage,
  );

  /// Which phrases of [source] and its [translation] correspond, as
  /// character ranges in both texts (for highlighting a phrase and its
  /// counterpart). The model lists the corresponding phrases; they are
  /// located in the texts by `ResponseParsers.parseAlignment` (pairs it
  /// cannot locate are dropped).
  ///
  /// Only the first `TranslationPrompts.maxAlignmentChars` (3000)
  /// characters of each text are sent, so longer texts are aligned only at
  /// their beginning. Blank texts give an empty list without a request.
  /// Requires an AI engine with [TranslationEngine.supportsExtras]
  /// ([ArgumentError] otherwise); invalid JSON is retried once, like the
  /// other JSON extras.
  ///
  /// The on-device engine ([TranslationEngine.isOffline]) aligns words
  /// itself, free and instantly, without sending anything (`alignOffline`;
  /// whole texts, any length), when its translator is a
  /// [DetailedOfflineTranslator] ([ArgumentError] otherwise).
  Future<List<AlignedSpan>> align(
    TranslationEngine engine, {
    required String source,
    required String translation,
    required Language sourceLanguage,
    required Language targetLanguage,
  }) async {
    if (engine.isOffline) {
      return await alignOffline(
        _offlineFor(engine),
        engine,
        source: source,
        translation: translation,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
      );
    }
    if (source.trim().isEmpty || translation.trim().isEmpty) {
      _extrasProviderFor(engine);
      return const [];
    }
    final shield = _shieldTexts(_destinationFor(engine), [source, translation]);
    return await _chatJson(
      engine,
      () => shield.withNote(
        TranslationPrompts.align(
          source: shield.texts[0],
          translation: shield.texts[1],
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
        ),
      ),
      (output) => ResponseParsers.parseAlignment(
        shield.restore(output),
        source: source,
        translation: translation,
      ),
      source: sourceLanguage.code,
      target: targetLanguage.code,
    );
  }

  /// Checks whether [translation] (in [targetLanguage]) means the same as
  /// [source] (in [sourceLanguage], which may be auto): the model
  /// translates the translation back into the source language and compares
  /// its meaning with the original (see `TranslationPrompts.meaningCheck`).
  ///
  /// The result has the back-translation, a [MeaningVerdict] and the real
  /// differences in meaning (omissions, additions, wrong negation, numbers
  /// or tense, mistranslated terms; never style) as [MeaningIssue]s located
  /// in both texts by `ResponseParsers.parseMeaningCheck` (issues it cannot
  /// locate are dropped but still count toward the verdict, which is never
  /// `same` when the model listed differences; at most
  /// `TranslationPrompts.maxMeaningIssues`).
  /// Problems are written in [uiLanguage] (an English language name).
  ///
  /// Only the first `TranslationPrompts.maxMeaningCheckChars` (4000)
  /// characters of each text are compared ([MeaningCheck.isPartial] is then
  /// true). Every call is a new (possibly paid) request: results are not
  /// cached. Requires an AI engine with [TranslationEngine.supportsExtras]
  /// ([ArgumentError] otherwise; other engines can [backTranslate]); blank
  /// texts are an [ArgumentError] too, without a request. Invalid JSON is
  /// retried once, like the other JSON extras.
  Future<MeaningCheck> checkMeaning(
    TranslationEngine engine, {
    required String source,
    required String translation,
    required Language sourceLanguage,
    required Language targetLanguage,
    String uiLanguage = 'English',
  }) async {
    _extrasProviderFor(engine);
    if (source.trim().isEmpty) {
      throw ArgumentError.value(source, 'source', 'Is empty');
    }
    if (translation.trim().isEmpty) {
      throw ArgumentError.value(translation, 'translation', 'Is empty');
    }
    final shield = _shieldTexts(_destinationFor(engine), [source, translation]);
    return await _chatJson(
      engine,
      () => shield.withNote(
        TranslationPrompts.meaningCheck(
          source: shield.texts[0],
          translation: shield.texts[1],
          sourceLanguage: sourceLanguage,
          targetLanguage: targetLanguage,
          uiLanguage: uiLanguage,
        ),
      ),
      (output) => ResponseParsers.parseMeaningCheck(
        shield.restore(output),
        source: source,
        translation: translation,
      ),
      source: sourceLanguage.code,
      target: targetLanguage.code,
    );
  }

  /// [translation] (in [from]) translated back into [to] (the language of
  /// the original text) with [engine]: the meaning check for engines
  /// without AI extras (Mozhi, DeepL, LibreTranslate, offline, and
  /// translation-specialised AI models), which the user compares with the
  /// original themselves. See [backTranslateResult].
  Future<String> backTranslate(
    TranslationEngine engine, {
    required String translation,
    required Language from,
    required Language to,
    bool refresh = false,
  }) async => (await backTranslateResult(
    engine,
    translation: translation,
    from: from,
    to: to,
    refresh: refresh,
  )).text;

  /// [backTranslate] with the whole final [TranslationResult]: it is
  /// [translate] of a plain request (default options) for [translation]
  /// from [from] into [to], so it works with every engine, honours the
  /// translation cache (a cached result has `fromCache: true`: nothing was
  /// sent, so usage counters should skip it; `refresh: true` skips the
  /// lookup) and fails like [translate] (e.g. an [ArgumentError] for a
  /// custom language on a Mozhi engine).
  ///
  /// [to] must not be auto and [translation] must not be blank
  /// ([ArgumentError] without a request).
  Future<TranslationResult> backTranslateResult(
    TranslationEngine engine, {
    required String translation,
    required Language from,
    required Language to,
    bool refresh = false,
  }) async {
    if (to.isAuto) {
      throw ArgumentError.value(
        to.code,
        'to',
        'Back-translation needs the language of the original text',
      );
    }
    if (translation.trim().isEmpty) {
      throw ArgumentError.value(translation, 'translation', 'Is empty');
    }
    return await translate(
      engine,
      TranslationRequest(text: translation, source: from, target: to),
      refresh: refresh,
    ).lastWhere((result) => result.isComplete);
  }

  /// Proofreads [text] with the AI [engine] (see
  /// [TranslationPrompts.proofread]): [readingLevel] other than
  /// [ReadingLevel.standard] rewords for that CEFR level, and a [variety]
  /// converts to that regional variety; by default the author's level and
  /// variety are kept. With the personal data shield (see
  /// [maskPersonalData]) [text] and [context] are masked together, and the
  /// result gets the values back (its edits are located in [text]) and
  /// says how many items stayed on the device
  /// ([ProofreadResult.maskedPersonalData]).
  Future<ProofreadResult> proofread(
    TranslationEngine engine,
    String text, {
    WritingStyle style = WritingStyle.general,
    CorrectionLevel level = CorrectionLevel.standard,
    Formality formality = Formality.automatic,
    ReadingLevel readingLevel = ReadingLevel.standard,
    ProofreadVariety? variety,
    String context = '',
    String uiLanguage = 'English',
  }) {
    final shield = _shieldTexts(_destinationFor(engine), [text, context]);
    return _chatJson(
      engine,
      () => shield.withNote(
        TranslationPrompts.proofread(
          shield.texts[0],
          style: style,
          level: level,
          formality: formality,
          readingLevel: readingLevel,
          variety: variety,
          context: shield.texts[1],
          uiLanguage: uiLanguage,
        ),
      ),
      (output) {
        final result = ResponseParsers.parseProofread(
          shield.restore(output),
          input: text,
        );
        return shield.personalCount == 0
            ? result
            : result.withMaskedPersonalData(shield.personalCount);
      },
      source: Language.auto.code,
      target: Language.auto.code,
    );
  }

  /// Uses the AI [engine] when it [TranslationEngine.supportsExtras]; the
  /// on-device identifier when [engine] is the offline engine; else Mozhi
  /// google with `from=auto` (taking `detected`); else the on-device
  /// identifier when available ([SourceLanguageRequiredException] when it
  /// cannot tell); else throws a [StateError]. The privacy settings apply
  /// with the pair `auto>auto`: when they do not let the text go to Mozhi,
  /// the on-device identifier answers if there is one, else a
  /// [ConsentRequiredException] is thrown.
  Future<DetectedLanguage> detectLanguage(
    String text, {
    TranslationEngine? engine,
  }) async {
    if (engine != null && engine.supportsExtras) {
      return await _chatJson(
        engine,
        () => TranslationPrompts.detectLanguage(
          _shielded(text, _destinationFor(engine)),
        ),
        ResponseParsers.parseDetectedLanguage,
        source: Language.auto.code,
        target: Language.auto.code,
      );
    }
    final offline = _offline;
    final onDevice = offline != null && offline.isAvailable;
    // Checked first, but only used up when Mozhi is asked.
    ConsentRequiredException? mozhiDenial({bool useGrants = false}) => _denial(
      _mozhiDestination(_detectionEngine),
      engineId: 'mozhi:$_detectionEngine',
      source: Language.auto.code,
      target: Language.auto.code,
      useGrants: useGrants,
    );
    if (onDevice &&
        ((engine?.isOffline ?? false) ||
            _mozhi.instances.isEmpty ||
            // The device answers when the text may not leave it.
            mozhiDenial() != null)) {
      final code = normalizeDetected(
        await offline.translator.identifyLanguage(text),
      );
      if (code == null) {
        throw SourceLanguageRequiredException(engineId: engine?.id);
      }
      return DetectedLanguage(code: code);
    }
    if (_mozhi.instances.isEmpty) {
      throw StateError(
        'Language detection needs an AI engine or a Mozhi instance.',
      );
    }
    final denied = mozhiDenial(useGrants: true);
    if (denied != null) throw denied;
    return await _detectWithMozhi(text);
  }

  /// Detects the language of [text] with Mozhi google (the consent was
  /// checked by the caller); with the personal data shield, the instance
  /// gets the masked text.
  Future<DetectedLanguage> _detectWithMozhi(String text) async {
    final sent = _shielded(text, _mozhiDestination(_detectionEngine));
    final translation = await _mozhi.run(
      (client, _) => client.translate(
        engine: _detectionEngine,
        from: 'auto',
        to: 'en',
        text: sent,
      ),
      failOverOnTimeout: false,
      allow: _mozhiFailoverAllowed,
    );
    final code = normalizeDetected(translation.detectedLanguage);
    if (code == null) {
      throw const MozhiApiException('The language could not be detected.');
    }
    return DetectedLanguage(code: code);
  }

  /// Mozhi `/api/tts` on the active instance with failover (not after a
  /// timeout). [engine] is `google` (default) or `reverso`. When Google
  /// fails on every instance, Reverso is tried before giving up (the Google
  /// error is rethrown).
  ///
  /// The privacy settings apply with the pair `<languageCode>><languageCode>`
  /// ([pairKey]): a [ConsentRequiredException] before any request when the
  /// text may not go to the instance (callers fall back to the device's
  /// voice); Reverso is only tried when the settings allow it on its own
  /// (an [allowOnce] approval for Google does not cover it).
  Future<Uint8List> textToSpeech({
    required String text,
    required String languageCode,
    String engine = 'google',
  }) async {
    ConsentRequiredException? denial(String ttsEngine, {bool once = true}) =>
        _denial(
          _mozhiDestination(ttsEngine),
          engineId: 'mozhi:$ttsEngine',
          source: languageCode,
          target: languageCode,
          useGrants: once,
        );
    final denied = denial(engine);
    if (denied != null) throw denied;
    Future<Uint8List> speak(String ttsEngine) => _mozhi.run(
      (client, _) => client.textToSpeech(
        engine: ttsEngine,
        language: languageCode,
        text: text,
      ),
      failOverOnTimeout: false,
      allow: _mozhiFailoverAllowed,
    );
    try {
      return await speak(engine);
    } on Object catch (error, stackTrace) {
      if (engine != 'google' ||
          _mozhi.instances.isEmpty ||
          denial('reverso', once: false) != null) {
        rethrow;
      }
      try {
        return await speak('reverso');
      } on Object {
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  /// AI engine with vision: `TranslationPrompts.translateImage` (not for
  /// translation-specialised models). Mozhi engine: `/api/image` (requires
  /// PNG; Google only, so the Google engine is used whichever Mozhi engine
  /// is passed). Other engines throw an [ArgumentError]: an image picked for
  /// the offline or a machine translation engine is never sent to Mozhi.
  ///
  /// Mozhi (`/api/image` relays to Google Translate's image translation):
  ///
  /// * [source] and [target] are mapped onto the Google engine's language
  ///   lists first (`zh` -> `zh-CN`, `zh-Hant` -> `zh-TW`, `he` -> `iw`); a
  ///   language Google does not list throws an [ArgumentError] (`source` or
  ///   `target`) before anything is uploaded.
  /// * The request may take [mozhiImageTimeout].
  /// * An answer without an image and without text (Google refused the
  ///   request, or found no text) is a retryable `MozhiApiException` (502,
  ///   [imageNoResultMessage]).
  /// * Retryable failures move on to another instance, but the photo is
  ///   sent to at most [maxImageInstances] instances, and never again after
  ///   a timeout.
  Future<ImageTranslationResult> translateImage(
    TranslationEngine engine,
    Uint8List imageBytes, {
    required String mimeType,
    required Language source,
    required Language target,
    TranslationOptions options = const TranslationOptions(),
  }) => _translateImage(
    engine,
    imageBytes,
    mimeType: mimeType,
    source: source,
    target: target,
    options: switch (savedGlossaries) {
      final lookup? => mergeSavedGlossary(
        options,
        lookup(source.code, target.code),
      ),
      null => options,
    },
  );

  Future<ImageTranslationResult> _translateImage(
    TranslationEngine engine,
    Uint8List imageBytes, {
    required String mimeType,
    required Language source,
    required Language target,
    required TranslationOptions options,
  }) async {
    if (engine.isAi) {
      final config = _extrasProviderFor(engine);
      final safe = _sanitizeRequest(
        TranslationRequest(text: '', source: source, target: target),
      );
      if (safe == null) {
        throw _emptyCustomLanguage(
          TranslationRequest(text: '', source: source, target: target),
        );
      }
      _ensureAllowed(
        engine,
        source: safe.source.code,
        target: safe.target.code,
      );
      // The image cannot be masked; the free-text options can.
      final destination = _providerDestination(config);
      final sent = _shieldRequest(
        destination,
        TranslationRequest(
          text: '',
          source: safe.source,
          target: safe.target,
          options: options,
        ),
      );
      final output = sent.shield.restore(
        await _llm
            .clientFor(config)
            .chat(
              _llmRequest(
                config,
                sent.shield.withNote(
                  TranslationPrompts.translateImage(
                    imageBytes,
                    mimeType: mimeType,
                    source: safe.source,
                    target: safe.target,
                    options: sent.request.options,
                  ),
                ),
              ),
            ),
      );
      final split = ResponseParsers.splitLanguageMarker(output);
      return ImageTranslationResult(
        translatedText: ResponseParsers.cleanTranslation(
          split.text,
          source: '',
        ),
        destination: destination,
      );
    }
    if (!engine.isMozhi) {
      throw ArgumentError.value(
        engine.id,
        'engine',
        'Image translation requires an AI or Mozhi engine',
      );
    }
    _checkMozhiLanguages(source, target);
    if (mimeType.toLowerCase() != 'image/png') {
      throw ArgumentError.value(
        mimeType,
        'mimeType',
        'Mozhi image translation requires a PNG image',
      );
    }
    // Mozhi translates images with Google, whichever engine was picked.
    const engineId = 'mozhi:$_imageEngine';
    final denied = _denial(
      _mozhiDestination(_imageEngine),
      engineId: engineId,
      source: source.code,
      target: target.code,
    );
    if (denied != null) throw denied;
    final from = source.isAuto
        ? source.code
        : await _mozhiImageLanguage(source, source: true);
    final to = await _mozhiImageLanguage(target, source: false);
    // Every attempt uploads the photo again: one failover at most.
    var attempts = 0;
    final (translation, image, instance) = await _mozhi.run(
      (client, instance) async {
        final translation = await client.translateImage(
          pngBytes: imageBytes,
          from: from,
          to: to,
          timeout: mozhiImageTimeout,
        );
        final image = decodeBase64Image(translation.translatedImageBase64);
        if (image == null &&
            translation.sourceText.trim().isEmpty &&
            translation.translatedText.trim().isEmpty) {
          // Google's answer, unchecked by Mozhi: refused (often per
          // instance address) or nothing found. Another instance may get
          // an answer.
          throw const MozhiApiException(imageNoResultMessage, statusCode: 502);
        }
        return (translation, image, instance);
      },
      failOverOnTimeout: false,
      allow: (instance) =>
          _mozhiFailoverAllowed(instance) && attempts++ < maxImageInstances,
    );
    return ImageTranslationResult(
      translatedImage: image,
      sourceText: translation.sourceText,
      translatedText: translation.translatedText,
      destination: _mozhiDestination(_imageEngine, instance),
    );
  }

  /// The engine whose language lists [translateImage] maps codes with.
  static final _imageLanguageEngine = TranslationEngine.mozhi(
    _imageEngine,
    'Google',
  );

  /// Google's legacy codes for catalogue codes (used without a list).
  static const _googleLegacyCodes = {'he': 'iw', 'jv': 'jw'};

  /// The code Mozhi's Google engine knows [language] by (`zh` -> `zh-CN`,
  /// `zh-Hant` -> `zh-TW`, `he` -> `iw`): the closest entry of its
  /// [source] or target language list ([LanguageMatcher]). Without a list
  /// (no instance answered, or metadata may not be loaded now), the
  /// catalogue code with Google's legacy codes.
  ///
  /// Throws an [ArgumentError] (named `source` or `target`) when the list
  /// has no such language, before the photo is uploaded for a request
  /// Google would reject.
  Future<String> _mozhiImageLanguage(
    Language language, {
    required bool source,
  }) async {
    List<Language> available;
    try {
      available = await _mozhiLanguages(_imageLanguageEngine, source: source);
    } on Object {
      available = const [];
    }
    final listed = [
      for (final entry in available)
        if (!entry.isAuto) entry,
    ];
    if (listed.isEmpty) {
      final code = LanguageMatcher.normalize(language.code);
      return _googleLegacyCodes[code] ?? code;
    }
    final match = LanguageMatcher.match(language, listed);
    if (match == null) {
      throw ArgumentError.value(
        language.code,
        source ? 'source' : 'target',
        'Google (Mozhi) does not translate images in this language',
      );
    }
    return match.code;
  }

  /// Latency of `/api/version` on [instance]; throws on failure.
  Future<Duration> pingInstance(MozhiInstance instance) =>
      _mozhi.withClient(instance, (client) => client.ping());

  /// Loads the model of a local AI [engine] (Ollama, LM Studio, llama.cpp:
  /// [TranslationEngine.isLocal] or a local provider, and models on this
  /// device, [AiProviderConfig.isOnDevice], which load in the app, also in
  /// [PrivacyMode.offlineOnly]) into memory, so that the first translation
  /// does not wait for it (`LlmClient.warmUp`; no user text is sent).
  /// Returns whether the server (or the device) warmed the model up; false
  /// without a request for other engines, unknown providers and providers
  /// whose destination the privacy settings keep the device from
  /// contacting ([PrivacyMode.offlineOnly]), and false when the request
  /// fails.
  Future<bool> warmUp(TranslationEngine engine) async {
    if (!engine.isAi) return false;
    final config = _configFor(engine, 'ai:');
    if (config == null ||
        config.isMtService ||
        !(engine.isLocal || config.isLocal)) {
      return false;
    }
    if (_privacyMode == PrivacyMode.offlineOnly &&
        _providerDestination(config).leavesDevice) {
      return false;
    }
    try {
      return await _llm.clientFor(config).warmUp(config.model);
    } on Object {
      return false;
    }
  }

  /// Loads the on-device models for [source] → [target] before the first
  /// translation (`DetailedOfflineTranslator.preload`), so that it doesn't
  /// wait for them. Nothing is downloaded and nothing leaves the device.
  /// Returns false, without throwing, when [engine] is not the on-device
  /// engine, the source is [Language.auto], the pair isn't installed or
  /// the translator cannot preload.
  Future<bool> preloadOffline(
    TranslationEngine engine, {
    required Language source,
    required Language target,
  }) async {
    final offline = _offline;
    if (!engine.isOffline || offline == null || source.isAuto) return false;
    final translator = offline.translator;
    if (translator is! DetailedOfflineTranslator) return false;
    final from = offline.codeFor(source);
    final to = offline.codeFor(target, isTarget: true);
    if (from == null || to == null || from == to) return false;
    try {
      return await translator.preload(source: from, target: to);
    } on Object {
      return false;
    }
  }

  /// The models of an AI provider; machine translation services have none
  /// (an empty list).
  Future<List<LlmModel>> listModels(AiProviderConfig config) async {
    if (config.isMtService) return const [];
    return await _llm.withTemporaryClient(
      config,
      (client) => client.listModels(),
    );
  }

  /// Sends a tiny translation ("Hello" -> French) with [config]; returns the
  /// output; throws the provider error on failure. Machine translation
  /// services use their API; translation-specialised models get their own
  /// prompt template.
  Future<String> testProvider(AiProviderConfig config) {
    if (config.isMtService) return _mt.test(config);
    return _llm.withTemporaryClient(config, (client) async {
      const request = TranslationRequest(
        text: 'Hello, world!',
        source: Language(code: 'en', name: 'English'),
        target: Language(code: 'fr', name: 'French'),
      );
      final profile = config.resolvedPromptProfile;
      final translationOnly = profile.isTranslationOnly;
      final output = await client.chat(
        _llmRequest(
          config,
          translationOnly
              ? MtPrompts.translate(profile, request)
              : TranslationPrompts.translate(request),
          sampling: translationOnly ? MtPrompts.sampling(profile) : null,
        ),
      );
      final text = ResponseParsers.cleanTranslation(
        translationOnly
            ? output
            : ResponseParsers.splitLanguageMarker(output).text,
        source: request.text,
      );
      if (text.trim().isEmpty) {
        throw const LlmApiException('The model returned an empty response.');
      }
      return text;
    });
  }

  /// Closes all cached HTTP clients and empties the caches.
  void dispose() {
    _clearMozhiCaches();
    unawaited(_metadataChanges.close());
    _cache.clear();
    _chunkCache.clear();
    _mozhi.dispose();
    _llm.dispose();
    _mt.dispose();
  }

  /// The configuration of AI [engine]; [ArgumentError] for other kinds and
  /// unknown providers.
  AiProviderConfig _aiProviderFor(TranslationEngine engine) {
    if (!engine.isAi) {
      throw ArgumentError.value(engine.id, 'engine', 'Requires an AI engine');
    }
    final config = _configFor(engine, 'ai:');
    if (config == null || config.isMtService) {
      throw ArgumentError.value(engine.id, 'engine', 'Unknown AI provider');
    }
    return config;
  }

  /// Like [_aiProviderFor], but also rejects translation-specialised models,
  /// which cannot follow the extras' prompts.
  AiProviderConfig _extrasProviderFor(TranslationEngine engine) {
    final config = _aiProviderFor(engine);
    if (config.resolvedPromptProfile.isTranslationOnly) {
      throw ArgumentError.value(
        engine.id,
        'engine',
        'This model only supports plain translation',
      );
    }
    return config;
  }

  /// The configuration of machine translation [engine] (callers dispatch on
  /// [EngineKind.mt]); [ArgumentError] for unknown providers.
  AiProviderConfig _mtProviderFor(TranslationEngine engine) {
    final config = _configFor(engine, 'mt:');
    if (config == null || !config.isMtService) {
      throw ArgumentError.value(
        engine.id,
        'engine',
        'Unknown machine translation service',
      );
    }
    return config;
  }

  AiProviderConfig? _configFor(TranslationEngine engine, String prefix) {
    final id =
        engine.providerId ??
        (engine.id.startsWith(prefix)
            ? engine.id.substring(prefix.length)
            : engine.id);
    return _providers.firstWhereOrNull((p) => p.id == id);
  }

  OfflineEngine _offlineFor(TranslationEngine engine) {
    final offline = _offline;
    if (!engine.isOffline || offline == null) {
      throw ArgumentError.value(
        engine.id,
        'engine',
        'No offline translator is configured',
      );
    }
    return offline;
  }

  static void _checkMozhiLanguages(Language source, Language target) {
    if (source.isCustom || target.isCustom) {
      throw ArgumentError.value(
        (source.isCustom ? source : target).code,
        source.isCustom ? 'source' : 'target',
        'Custom languages require an AI engine',
      );
    }
  }

  /// Anthropic models reject non-default sampling parameters, so no
  /// sampling parameter is ever sent to them. Elsewhere the provider's own
  /// temperature wins over [defaultTemperature] and over the temperature of
  /// [sampling] (a model card's recommendation: `MtPrompts.sampling` for
  /// translation-specialised models), whose top-p, top-k and repetition
  /// penalty are sent as they are (null leaves them to the provider: an
  /// on-device model then uses its catalogue entry's). The provider's
  /// reasoning effort is sent unless [withEffort] is false (quick
  /// best-effort requests).
  static LlmRequest _llmRequest(
    AiProviderConfig config,
    List<LlmMessage> messages, {
    bool jsonOutput = false,
    double? defaultTemperature,
    MtSampling? sampling,
    bool withEffort = true,
  }) {
    final anthropic = config.provider == LlmProvider.anthropic;
    return LlmRequest(
      model: config.model,
      messages: messages,
      temperature: anthropic
          ? null
          : config.temperature ?? defaultTemperature ?? sampling?.temperature,
      topP: anthropic ? null : sampling?.topP,
      topK: anthropic ? null : sampling?.topK,
      repeatPenalty: anthropic ? null : sampling?.repeatPenalty,
      effort: withEffort ? config.effort : null,
      jsonOutput: jsonOutput,
    );
  }

  /// Non-streaming JSON request (for text of the pair [source] > [target],
  /// checked against the privacy settings first); on a [FormatException]
  /// from [parse] asks once more for valid JSON only.
  Future<T> _chatJson<T>(
    TranslationEngine engine,
    List<LlmMessage> Function() messages,
    T Function(String output) parse, {
    required String source,
    required String target,
  }) async {
    final config = _extrasProviderFor(engine);
    _ensureAllowed(engine, source: source, target: target);
    final client = _llm.clientFor(config);
    final request = _llmRequest(config, messages(), jsonOutput: true);
    final output = await client.chat(request);
    try {
      return parse(output);
    } on FormatException {
      final retry = await client.chat(
        request.copyWith(
          messages: [
            ...request.messages,
            if (output.trim().isNotEmpty) LlmMessage.assistant(output),
            const LlmMessage.user(_jsonRetryInstruction),
          ],
        ),
      );
      return parse(retry);
    }
  }
}

/// Texts with their personal data masked for one request (see
/// `TranslationRepository._shieldTexts`).
class _Shield {
  new(this.texts, {this.masked});

  /// The texts as they are sent.
  final List<String> texts;

  /// The tokens of [texts], or null when nothing was masked (the texts are
  /// sent as they are).
  final MaskedText? masked;

  /// Distinct items of personal data masked.
  int get personalCount => masked?.personalCount ?? 0;

  /// [output] (the model's reply to [texts]) with the masked values back.
  String restore(String output) => masked?.restore(output).text ?? output;

  /// [messages] with the note about the tokens
  /// ([TranslationPrompts.maskedPersonalDataNote]) when there are any.
  List<LlmMessage> withNote(List<LlmMessage> messages) => masked == null
      ? messages
      : TranslationPrompts.withMaskedPersonalDataNote(messages);

  /// [deltas] of a streamed reply with the masked values back; a token split
  /// across deltas is held back until it is complete.
  Stream<String> restoreDeltas(Stream<String> deltas) async* {
    final tokens = masked;
    if (tokens == null) {
      yield* deltas;
      return;
    }
    final pending = StringBuffer();
    await for (final delta in deltas) {
      pending.write(delta);
      final text = pending.toString();
      final hold = _partialTokenStart(text);
      pending
        ..clear()
        ..write(text.substring(hold));
      if (hold > 0) yield tokens.restore(text.substring(0, hold)).text;
    }
    if (pending.isNotEmpty) yield tokens.restore(pending.toString()).text;
  }

  /// The start of a token (`TextMasker.bracketToken`, at most
  /// `TextMasker.maxTokenDigits` digits) at the end of a delta. The spaces
  /// after the digits only follow digits (linear time).
  static final _partialToken = RegExp(r'[⟨〈]\s*(?:\d{1,6}\s*)?$');

  /// Where a token that the next delta may complete starts at the end of
  /// [text] (its length when there is none).
  static int _partialTokenStart(String text) =>
      _partialToken.firstMatch(text)?.start ?? text.length;
}

/// Sends one (masked) part of a non-AI translation: [masked] when it has
/// tokens, [original] the part before masking.
typedef _Send = Future<TranslationResult> Function(
  TranslationRequest request, {
  required bool masked,
  Future<void>? abort,
  TranslationRequest? original,
});

/// What the masking of a non-AI translation's parts did (see
/// `TranslationRepository._machineTranslation`).
class _MaskReport {
  /// Distinct items of personal data masked, summed over the parts.
  int personal = 0;

  /// Whether a part lost a token of personal data.
  bool lost = false;

  /// [result] (final) with [TranslationResult.maskedPersonalData] and, when
  /// [lost], [TranslationWarningKind.personalDataLost].
  TranslationResult applyTo(TranslationResult result) {
    if (personal == 0 && !lost) return result;
    return result.copyWith(
      maskedPersonalData: personal,
      warnings: lost
          ? List.unmodifiable([
              ...result.warnings,
              const TranslationWarning(TranslationWarningKind.personalDataLost),
            ])
          : null,
    );
  }
}

/// An [TranslationRepository.allowOnce] approval.
class _OnceGrant {
  new({
    required this.kind,
    required this.engineId,
    required this.destination,
    required this.pair,
    required this.expires,
    required this.remaining,
  });

  final ConsentKind kind;
  final String engineId;
  final DataDestination destination;
  final String pair;
  DateTime expires;

  /// Requests it still lets through.
  int remaining;
}
