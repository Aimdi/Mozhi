import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:llm_api/llm_api.dart';
import 'package:mozhi/on_device_ai/data/on_device_llm_client.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/on_device_ai/data/on_device_runtime.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/platform/native_memory.dart';
import 'package:translation_repository/translation_repository.dart';

/// What the on-device AI is doing ([OnDeviceAi.status]).
@immutable
sealed class OnDeviceAiStatus {
  const new();

  /// The model the status is about (null when idle).
  String? get modelId => null;

  /// Whether a model is loading (the first request after a while waits a
  /// few seconds for it).
  bool get isLoading => this is OnDeviceAiLoading;

  /// Whether a model is writing a reply.
  bool get isGenerating => this is OnDeviceAiGenerating;

  /// Whether a long job waits between its parts for the phone to cool
  /// down or battery saver to end ([OnDeviceAiPaused]).
  bool get isPaused => this is OnDeviceAiPaused;
}

/// Nothing runs (a model may still be loaded, until it is unloaded).
final class OnDeviceAiIdle extends OnDeviceAiStatus {
  const new();

  @override
  bool operator ==(Object other) => other is OnDeviceAiIdle;

  @override
  int get hashCode => (OnDeviceAiIdle).hashCode;

  @override
  String toString() => 'OnDeviceAiIdle()';
}

/// Model [modelId] is being loaded into memory.
final class OnDeviceAiLoading extends OnDeviceAiStatus {
  const new(this.modelId);

  @override
  final String modelId;

  @override
  bool operator ==(Object other) =>
      other is OnDeviceAiLoading && other.modelId == modelId;

  @override
  int get hashCode => Object.hash(OnDeviceAiLoading, modelId);

  @override
  String toString() => 'OnDeviceAiLoading($modelId)';
}

/// Model [modelId] is writing a reply.
final class OnDeviceAiGenerating extends OnDeviceAiStatus {
  const new(this.modelId);

  @override
  final String modelId;

  @override
  bool operator ==(Object other) =>
      other is OnDeviceAiGenerating && other.modelId == modelId;

  @override
  int get hashCode => Object.hash(OnDeviceAiGenerating, modelId);

  @override
  String toString() => 'OnDeviceAiGenerating($modelId)';
}

/// A long job (a document, a web page or a long text, part by part) waits
/// before its next part for model [modelId] while the phone is hot or
/// battery saver is on ([strain]); [OnDeviceAi.continueAnyway] lets it
/// go on, cancelling the request stops it.
final class OnDeviceAiPaused extends OnDeviceAiStatus {
  const new(this.modelId, this.strain);

  @override
  final String modelId;

  /// Why it waits.
  final DeviceStrain strain;

  @override
  bool operator ==(Object other) =>
      other is OnDeviceAiPaused &&
      other.modelId == modelId &&
      other.strain == strain;

  @override
  int get hashCode => Object.hash(OnDeviceAiPaused, modelId, strain);

  @override
  String toString() => 'OnDeviceAiPaused($modelId, ${strain.name})';
}

/// Model [modelId] could not be loaded or failed while writing ([error]:
/// what the request failed with, an `LlmApiException`).
final class OnDeviceAiError extends OnDeviceAiStatus {
  const new(this.modelId, this.error);

  @override
  final String modelId;

  final Object error;

  @override
  bool operator ==(Object other) =>
      other is OnDeviceAiError &&
      other.modelId == modelId &&
      other.error == error;

  @override
  int get hashCode => Object.hash(OnDeviceAiError, modelId, error);

  @override
  String toString() => 'OnDeviceAiError($modelId)';
}

/// On-device AI: the installed models (selected in the On-device AI
/// settings, [models]) as AI providers that every AI feature can use with
/// no network ([providers], [client]).
///
/// The providers are never stored in the settings: the app adds them to
/// the ones it pushes to the `TranslationRepository`
/// ([withOnDeviceProviders]) and gives the repository their clients
/// ([onDeviceClientFactory]). Their destination is the device
/// (`OnDeviceDestination`): no consent, they work in Offline only, and
/// nothing they get leaves the device.
///
/// One model is in memory at a time and one request runs at a time (they
/// queue). The parts of a long job wait while the phone is hot or battery
/// saver is on ([OnDeviceAiPaused], see [OnDeviceRuntime]). A model loads
/// with the first request that needs it ([status]
/// is [OnDeviceAiLoading] meanwhile, then [OnDeviceAiGenerating]) and is
/// unloaded `idleUnloadAfter` after the last request, when the app goes to
/// the background and on memory pressure (`memoryBudget`); a running
/// request finishes first.
class OnDeviceAi {
  /// [engineBuild] tells which build of the engine library runs on this
  /// processor ([LlamaEngineBuild], for support; null: not known).
  new({
    required this.models,
    required LlamaEngine engine,
    NativeMemoryBudget? memoryBudget,
    Duration idleUnloadAfter = defaultIdleUnloadAfter,
    this._engineBuild,
    DeviceConditions? deviceConditions,
  }) : runtime = OnDeviceRuntime(
         engine: engine,
         catalog: models.catalog,
         pathOf: models.pathOf,
         idleUnloadAfter: idleUnloadAfter,
         deviceConditions: deviceConditions,
       ) {
    _providers = _selectedProviders();
    _changes = models.changes.listen((_) => _onModelsChanged());
    memoryBudget
      ?..onBackground(unload)
      ..onMemoryPressure(unload);
  }

  /// How long a model stays loaded after the last request.
  static const defaultIdleUnloadAfter = Duration(minutes: 2);

  /// The prefix of the provider ids of on-device models
  /// (`device-<model id>`; engine ids `ai:device-<model id>`). The app
  /// never gives a provider it stores such an id.
  static const providerIdPrefix = 'device-';

  /// The installed models and which ones are selected.
  final OnDeviceModels models;

  /// The engine, its queue and its status.
  final OnDeviceRuntime runtime;

  final LlamaEngineBuild Function()? _engineBuild;

  /// Which build of the engine library runs on this processor (shown on
  /// the On-device AI page for support); null when not known.
  LlamaEngineBuild? get engineBuild {
    try {
      return _engineBuild?.call();
    } on Object {
      return null;
    }
  }

  late List<AiProviderConfig> _providers;
  late final StreamSubscription<void> _changes;
  final _providersController =
      StreamController<List<AiProviderConfig>>.broadcast();
  bool _disposed = false;

  /// The AI providers of the selected, installed models: the translation
  /// model's (Hy-MT2) first, then the assistant model's (refine,
  /// alternatives, insights, dictionary, explain, proofread, meaning
  /// check). Updates with [models]' changes ([providersChanges]).
  List<AiProviderConfig> get providers => _providers;

  /// [providers] whenever they change.
  Stream<List<AiProviderConfig>> get providersChanges =>
      _providersController.stream;

  /// What the on-device AI is doing, as it changes ([currentStatus] is the
  /// latest).
  Stream<OnDeviceAiStatus> get status => runtime.status;

  /// The latest [status].
  OnDeviceAiStatus get currentStatus => runtime.currentStatus;

  /// The in-process client for an on-device endpoint
  /// (`AiProviderConfig.toEndpoint` of one of [providers]: provider
  /// [LlmProvider.onDevice]); [ArgumentError] for any other.
  LlmClient client(LlmEndpoint endpoint) {
    if (endpoint.provider != LlmProvider.onDevice) {
      throw ArgumentError.value(
        endpoint.provider,
        'endpoint',
        'Not an on-device endpoint',
      );
    }
    return OnDeviceLlmClient(endpoint, runtime: runtime);
  }

  /// Lets a long job that waits while the phone is hot or battery saver is
  /// on ([OnDeviceAiPaused]) go on with its next parts, until it ends
  /// (`OnDeviceRuntime.continueAnyway`).
  void continueAnyway() => runtime.continueAnyway();

  /// Frees the loaded model's memory now, or after the running request.
  Future<void> unload() async {
    if (_disposed) return;
    await runtime.unload();
  }

  /// Unloads the model, stops the engine and closes [models].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _changes.cancel();
    await _providersController.close();
    await runtime.dispose();
    await models.dispose();
  }

  /// The provider of on-device [model].
  static AiProviderConfig providerFor(LlamaCatalogModel model) =>
      AiProviderConfig(
        id: '$providerIdPrefix${model.id}',
        // The engine picker and badges say "On this device" (localised).
        name: model.displayName,
        provider: LlmProvider.onDevice,
        baseUrl: '',
        model: model.id,
        promptProfile:
            PromptProfile.tryParse(model.promptProfile) ?? PromptProfile.auto,
      );

  List<AiProviderConfig> _selectedProviders() => [
    for (final id in [models.translationModel, models.assistantModel])
      if (id != null)
        if (models.catalog.model(id) case final model?) providerFor(model),
  ];

  void _onModelsChanged() {
    if (_disposed) return;
    final providers = _selectedProviders();
    // A model that is no longer selected (or deleted) leaves memory.
    final loaded = runtime.loadedModelId;
    if (loaded != null && providers.every((p) => p.model != loaded)) {
      unawaited(unload());
    }
    if (listEquals(providers, _providers)) return;
    _providers = List.unmodifiable(providers);
    _providersController.add(_providers);
  }
}

/// [configured] (the providers of the settings) followed by the providers
/// of [onDeviceAi]: what the app pushes to the `TranslationRepository`. A
/// configured provider whose id is an on-device one
/// ([OnDeviceAi.providerIdPrefix], which the app never gives a provider
/// it stores: an imported or crafted one) is left out, so that an
/// `ai:device-…` engine always runs on the device.
List<AiProviderConfig> withOnDeviceProviders(
  List<AiProviderConfig> configured,
  OnDeviceAi? onDeviceAi,
) {
  bool stored(AiProviderConfig provider) =>
      !provider.id.startsWith(OnDeviceAi.providerIdPrefix);
  final onDevice = onDeviceAi?.providers ?? const <AiProviderConfig>[];
  // Usually nothing to add or leave out: the list as it is.
  if (onDevice.isEmpty && configured.every(stored)) return configured;
  return [...configured.where(stored), ...onDevice];
}

/// The `TranslationRepository`'s client factory: [OnDeviceAi.client] for
/// on-device endpoints (when [onDeviceAi] exists), [network] (the
/// `NetworkSession`'s) for every other.
LlmClient Function(LlmEndpoint endpoint) onDeviceClientFactory(
  OnDeviceAi? onDeviceAi,
  LlmClient Function(LlmEndpoint endpoint) network,
) =>
    (endpoint) => switch (onDeviceAi) {
      final onDevice? when endpoint.provider == LlmProvider.onDevice =>
        onDevice.client(endpoint),
      _ => network(endpoint),
    };
