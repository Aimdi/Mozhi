import 'package:equatable/equatable.dart';
import 'package:mozhi/core/on_device_ai_engine.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

/// Where the text of a history entry went, as a filter: the device, the
/// user's own server, a public server run by someone else, or a cloud
/// service.
enum HistoryDestination { onDevice, selfHosted, publicServer, cloud }

/// Classifies an entry's engine id (see [historyDestinationOf]).
typedef HistoryDestinationOf = HistoryDestination? Function(String engineId);

/// The [HistoryDestination] of engine [engineId], derived from its id like
/// `TranslationRepository.destinationOf` (entries do not store where their
/// text went):
///
/// - `offline:*` and on-device AI models (`ai:device-<model>`,
///   [isOnDeviceAiEngineId]: the app only ever runs such an engine on this
///   device, and its providers are never in [providers]):
///   [HistoryDestination.onDevice];
/// - `mozhi:*`: the preferred (first) of [instances]:
///   [HistoryDestination.selfHosted] on this machine, a private network,
///   Tor or I2P, else (also without instances)
///   [HistoryDestination.publicServer];
/// - `ai:<id>` / `mt:<id>`: the provider `<id>` in [providers]: a local AI
///   model or LibreTranslate server is self-hosted, another LibreTranslate
///   server public, DeepL and other AI providers (and providers that no
///   longer exist) [HistoryDestination.cloud].
///
/// Null for any other id.
HistoryDestination? historyDestinationOf(
  String engineId, {
  List<AiProviderConfig> providers = const [],
  List<MozhiInstance> instances = const [],
}) {
  bool isPrivate(String url) =>
      DataDestination.isPrivateHost(DataDestination.hostOf(url));

  if (engineId.startsWith('offline:') ||
      engineId == 'offline' ||
      isOnDeviceAiEngineId(engineId)) {
    return HistoryDestination.onDevice;
  }
  if (engineId.startsWith('mozhi:')) {
    final url = instances.firstOrNull?.url;
    return url != null && isPrivate(url)
        ? HistoryDestination.selfHosted
        : HistoryDestination.publicServer;
  }
  final id = TranslationRepository.providerIdOf(engineId);
  if (id == null) return null;
  final provider = providers.where((p) => p.id == id).firstOrNull;
  if (provider == null) return HistoryDestination.cloud;
  final base = provider.baseUrl.trim();
  return switch (provider.service) {
    MtService.deepl => HistoryDestination.cloud,
    MtService.libreTranslate when base.isNotEmpty && isPrivate(base) =>
      HistoryDestination.selfHosted,
    MtService.libreTranslate => HistoryDestination.publicServer,
    MtService.llm when isPrivate(base) => HistoryDestination.selfHosted,
    MtService.llm => HistoryDestination.cloud,
  };
}

/// The language pair of history entries, as a filter. Languages compare
/// by code: "French (detected) → English" and "French → English" are the
/// same pair.
class HistoryPair extends Equatable {
  const new({required this.source, required this.target});

  /// The pair of [entry]: its detected language when the source was
  /// detected automatically.
  factory of(HistoryEntry entry) {
    final detected = entry.detectedSource;
    final source =
        entry.source.isAuto && detected != null && detected.isNotEmpty
        ? LanguageCatalog.byCode(detected) ??
              Language(code: detected, name: LanguageCatalog.nameOf(detected))
        : entry.source;
    return HistoryPair(source: source, target: entry.target);
  }

  final Language source;
  final Language target;

  bool matches(HistoryEntry entry) => HistoryPair.of(entry) == this;

  @override
  List<Object?> get props => [source, target];
}
