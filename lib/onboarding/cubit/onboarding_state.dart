import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// The pages of the first-run flow, in order.
enum OnboardingStep { welcome, service, ai, done }

/// Outcome of pinging one Mozhi instance.
enum PingStatus { pending, success, failure, timedOut }

/// Latency check of a single instance (see `OnboardingCubit`).
class InstancePing extends Equatable {
  const new({required this.status, this.latency, this.error});

  const InstancePing.pending() : this(status: PingStatus.pending);

  const InstancePing.success(Duration latency)
    : this(status: PingStatus.success, latency: latency);

  const InstancePing.failure(String error)
    : this(status: PingStatus.failure, error: error);

  const InstancePing.timedOut() : this(status: PingStatus.timedOut);

  final PingStatus status;

  /// Round-trip time, set for [PingStatus.success].
  final Duration? latency;

  /// Message of the error, set for [PingStatus.failure].
  final String? error;

  bool get isSuccess => status == PingStatus.success;

  @override
  List<Object?> get props => [status, latency, error];
}

/// Progress of "find the fastest instance".
enum ServiceStatus { idle, pinging, done }

/// Progress of "use my own instance".
enum OwnInstanceStatus { idle, testing, success, failure }

/// Why "use my own instance" failed.
enum OwnInstanceError { empty, invalidUrl, unreachable, timedOut }

/// Inputs of the AI provider form.
enum ProviderField { apiKey, baseUrl, model }

/// Validation problems of a [ProviderField].
enum ProviderFieldError { required, invalidUrl }

/// Progress of an async provider action (test / model list).
enum ProviderTestStatus { idle, running, success, failure }

class OnboardingState extends Equatable {
  const new({
    this.step = OnboardingStep.welcome,
    this.serviceStatus = ServiceStatus.idle,
    this.pings = const {},
    this.sortBySpeed = true,
    this.selectedUrl,
    this.ownInstanceStatus = OwnInstanceStatus.idle,
    this.ownInstanceError,
    this.ownInstanceMessage,
    this.ownInstanceLatency,
    this.presetId,
    this.apiKey = '',
    this.baseUrl = '',
    this.model = '',
    this.showProviderErrors = false,
    this.testStatus = ProviderTestStatus.idle,
    this.testOutput,
    this.testError,
    this.modelsStatus = ProviderTestStatus.idle,
    this.models = const [],
    this.modelsError,
    this.saved = const {},
  });

  final OnboardingStep step;

  // Translation service

  final ServiceStatus serviceStatus;

  /// Ping results keyed by instance url.
  final Map<String, InstancePing> pings;

  /// Reorder the instances by latency (otherwise only the selected instance
  /// is moved to the front).
  final bool sortBySpeed;

  /// The preferred instance chosen during onboarding (fastest, picked by
  /// the user, or the user's own instance).
  final String? selectedUrl;

  final OwnInstanceStatus ownInstanceStatus;
  final OwnInstanceError? ownInstanceError;

  /// Error message for [OwnInstanceError.unreachable].
  final String? ownInstanceMessage;

  /// Latency of the own instance after a successful test.
  final Duration? ownInstanceLatency;

  // AI provider

  /// The selected [AiProviderPreset.id] (null = none).
  final String? presetId;
  final String apiKey;
  final String baseUrl;
  final String model;

  /// Show validation errors (after a test/save attempt).
  final bool showProviderErrors;
  final ProviderTestStatus testStatus;

  /// Translated test sentence on success.
  final String? testOutput;

  /// Error message on failure; null on failure means the test timed out.
  final String? testError;
  final ProviderTestStatus modelsStatus;

  /// Models reported by the provider (after `loadModels`).
  final List<String> models;
  final String? modelsError;

  /// Providers saved during onboarding, keyed by preset id.
  final Map<String, AiProviderConfig> saved;

  /// Fastest successfully pinged instance (null when none answered).
  String? get fastestUrl {
    String? fastest;
    Duration? best;
    for (final MapEntry(key: url, value: ping) in pings.entries) {
      final latency = ping.latency;
      if (!ping.isSuccess || latency == null) continue;
      if (best == null || latency < best) {
        best = latency;
        fastest = url;
      }
    }
    return fastest;
  }

  /// True when every ping finished and none succeeded.
  bool get noneReachable =>
      serviceStatus == ServiceStatus.done &&
      pings.isNotEmpty &&
      pings.values.every((p) => !p.isSuccess);

  AiProviderPreset? get preset =>
      presetId == null ? null : AiProviderPreset.byId(presetId!);

  /// Whether the form needs the server address (local / custom presets).
  bool get needsBaseUrl {
    final p = preset;
    return p != null && (p.isLocal || p.baseUrl.isEmpty);
  }

  /// Whether the form shows an API key field (cloud presets).
  bool get showsApiKey {
    final p = preset;
    return p != null && (p.requiresApiKey || !p.isLocal);
  }

  /// [baseUrl] trimmed, without trailing slashes, with `http://` (local
  /// hosts) or `https://` added when the scheme is missing.
  String get normalizedBaseUrl {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isEmpty || url.contains('://')) return url;
    final host = Uri.tryParse('http://$url')?.host ?? '';
    return '${AiProviderConfig.isLocalHost(host) ? 'http' : 'https'}://$url';
  }

  /// Validation of the provider form (empty when valid or no preset).
  Map<ProviderField, ProviderFieldError> get providerErrors {
    final p = preset;
    if (p == null) return const {};
    final uri = Uri.tryParse(normalizedBaseUrl);
    return {
      if (p.requiresApiKey && apiKey.trim().isEmpty)
        ProviderField.apiKey: ProviderFieldError.required,
      if (baseUrl.trim().isEmpty)
        ProviderField.baseUrl: ProviderFieldError.required
      else if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty)
        ProviderField.baseUrl: ProviderFieldError.invalidUrl,
      if (model.trim().isEmpty)
        ProviderField.model: ProviderFieldError.required,
    };
  }

  /// The error to show under [field], if any.
  ProviderFieldError? errorFor(ProviderField field) =>
      showProviderErrors ? providerErrors[field] : null;

  /// The provider described by the form, or null without a preset.
  AiProviderConfig? draftConfig(String id) {
    final p = preset;
    if (p == null) return null;
    final key = apiKey.trim();
    return p.toConfig(
      id: id,
      model: model.trim(),
      apiKey: key.isEmpty ? null : key,
      baseUrl: normalizedBaseUrl,
    );
  }

  /// The provider saved for the current preset, if it still matches the
  /// form (no unsaved edits).
  AiProviderConfig? get savedDraft {
    final id = presetId;
    final saved = id == null ? null : this.saved[id];
    if (saved == null) return null;
    return draftConfig(saved.id) == saved ? saved : null;
  }

  OnboardingState copyWith({
    OnboardingStep? step,
    ServiceStatus? serviceStatus,
    Map<String, InstancePing>? pings,
    bool? sortBySpeed,
    String? Function()? selectedUrl,
    OwnInstanceStatus? ownInstanceStatus,
    OwnInstanceError? Function()? ownInstanceError,
    String? Function()? ownInstanceMessage,
    Duration? Function()? ownInstanceLatency,
    String? Function()? presetId,
    String? apiKey,
    String? baseUrl,
    String? model,
    bool? showProviderErrors,
    ProviderTestStatus? testStatus,
    String? Function()? testOutput,
    String? Function()? testError,
    ProviderTestStatus? modelsStatus,
    List<String>? models,
    String? Function()? modelsError,
    Map<String, AiProviderConfig>? saved,
  }) {
    return OnboardingState(
      step: step ?? this.step,
      serviceStatus: serviceStatus ?? this.serviceStatus,
      pings: pings ?? this.pings,
      sortBySpeed: sortBySpeed ?? this.sortBySpeed,
      selectedUrl: selectedUrl != null ? selectedUrl() : this.selectedUrl,
      ownInstanceStatus: ownInstanceStatus ?? this.ownInstanceStatus,
      ownInstanceError: ownInstanceError != null
          ? ownInstanceError()
          : this.ownInstanceError,
      ownInstanceMessage: ownInstanceMessage != null
          ? ownInstanceMessage()
          : this.ownInstanceMessage,
      ownInstanceLatency: ownInstanceLatency != null
          ? ownInstanceLatency()
          : this.ownInstanceLatency,
      presetId: presetId != null ? presetId() : this.presetId,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      showProviderErrors: showProviderErrors ?? this.showProviderErrors,
      testStatus: testStatus ?? this.testStatus,
      testOutput: testOutput != null ? testOutput() : this.testOutput,
      testError: testError != null ? testError() : this.testError,
      modelsStatus: modelsStatus ?? this.modelsStatus,
      models: models ?? this.models,
      modelsError: modelsError != null ? modelsError() : this.modelsError,
      saved: saved ?? this.saved,
    );
  }

  @override
  List<Object?> get props => [
    step,
    serviceStatus,
    pings,
    sortBySpeed,
    selectedUrl,
    ownInstanceStatus,
    ownInstanceError,
    ownInstanceMessage,
    ownInstanceLatency,
    presetId,
    apiKey,
    baseUrl,
    model,
    showProviderErrors,
    testStatus,
    testOutput,
    testError,
    modelsStatus,
    models,
    modelsError,
    saved,
  ];
}
