import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:mozhi/core/network/network.dart' show isCleartextAllowed;
import 'package:mozhi/onboarding/cubit/onboarding_state.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/translation_repository.dart';

export 'onboarding_state.dart';

/// User-facing text for a repository/API failure.
String onboardingErrorMessage(Object error) => switch (error) {
  MozhiApiException(:final message) => message,
  LlmApiException(:final message, :final statusCode) =>
    statusCode == null ? message : '$statusCode: $message',
  FormatException(:final message) => message,
  _ => error.toString(),
};

/// [input] as a normalized Mozhi base URL, or null when it is not valid.
Uri? normalizeOwnInstanceUrl(String input) {
  try {
    return MozhiApiClient.normalizeBaseUrl(input);
  } on FormatException {
    return null;
  }
}

/// Drives the first-run flow: step navigation, the privacy mode, finding
/// the fastest Mozhi instance, adding the user's own instance and setting
/// up an optional AI provider. Every choice is applied to [SettingsCubit]
/// right away.
class OnboardingCubit extends Cubit<OnboardingState> {
  /// `pingTimeout` bounds each instance ping, `testTimeout` the provider
  /// test and the model list. `clock` stamps new provider ids (tests).
  /// `describeError` words failures for the user (default:
  /// [onboardingErrorMessage]; the page puts the network policy's reasons
  /// first).
  new({
    required this._repository,
    required this._settings,
    this._pingTimeout = const Duration(seconds: 6),
    this._testTimeout = const Duration(seconds: 90),
    DateTime Function()? clock,
    String Function(Object error)? describeError,
  }) : _clock = clock ?? DateTime.now,
       _describe = describeError ?? onboardingErrorMessage,
       super(const OnboardingState());

  final String Function(Object error) _describe;

  final TranslationRepository _repository;
  final SettingsCubit _settings;
  final Duration _pingTimeout;
  final Duration _testTimeout;
  final DateTime Function() _clock;

  /// Instance order before onboarding first sorted it (restored when
  /// "sort by speed" is turned off).
  List<String>? _originalOrder;

  /// Whether the user picked an instance (it then wins over the fastest).
  bool _userChoseInstance = false;
  int _pingRun = 0;
  int _ownRun = 0;
  int _providerRun = 0;

  // Navigation

  void next() {
    final index = state.step.index;
    if (index < OnboardingStep.values.length - 1) {
      goTo(OnboardingStep.values[index + 1]);
    }
  }

  void back() {
    final index = state.step.index;
    if (index > 0) goTo(OnboardingStep.values[index - 1]);
  }

  void goTo(OnboardingStep step) {
    if (step != state.step) emit(state.copyWith(step: step));
  }

  /// Marks onboarding as complete in the settings.
  void finish() => _settings.completeOnboarding();

  // Privacy

  /// How willing the app is to send text over the network (saved at once).
  void setPrivacyMode(PrivacyMode mode) {
    if (_settings.state.privacyMode != mode) _settings.setPrivacyMode(mode);
  }

  // Translation service

  /// Pings every configured instance concurrently (each bounded by the ping
  /// timeout), reporting results as they arrive. When all finished, the
  /// fastest instance (unless the user picked one) becomes preferred and,
  /// with [OnboardingState.sortBySpeed], the list is sorted by latency.
  Future<void> findFastestInstance() async {
    if (state.serviceStatus == ServiceStatus.pinging) return;
    final instances = _settings.state.instances;
    _originalOrder ??= [for (final instance in instances) instance.url];
    final run = ++_pingRun;
    emit(
      state.copyWith(
        serviceStatus: ServiceStatus.pinging,
        pings: {
          for (final instance in instances)
            instance.url: const InstancePing.pending(),
        },
      ),
    );
    await Future.wait([for (final i in instances) _ping(i, run)]);
    if (isClosed || run != _pingRun) return;
    if (!_userChoseInstance) {
      final fastest = state.fastestUrl;
      if (fastest != null) emit(state.copyWith(selectedUrl: () => fastest));
    }
    emit(state.copyWith(serviceStatus: ServiceStatus.done));
    _applyOrder();
  }

  Future<void> _ping(MozhiInstance instance, int run) async {
    InstancePing result;
    try {
      final latency = await _repository
          .pingInstance(instance)
          .timeout(_pingTimeout);
      result = InstancePing.success(latency);
    } on TimeoutException {
      result = const InstancePing.timedOut();
    } on Object catch (error) {
      result = InstancePing.failure(_describe(error));
    }
    if (isClosed || run != _pingRun) return;
    emit(state.copyWith(pings: {...state.pings, instance.url: result}));
  }

  void setSortBySpeed({required bool enabled}) {
    if (enabled == state.sortBySpeed) return;
    emit(state.copyWith(sortBySpeed: enabled));
    if (state.serviceStatus == ServiceStatus.done) _applyOrder();
  }

  /// Makes [url] the preferred instance.
  void selectInstance(String url) {
    _userChoseInstance = true;
    emit(state.copyWith(selectedUrl: () => url));
    _settings.preferInstance(url);
  }

  /// Sorts the instances by latency (or restores their original order) and
  /// moves the selected instance to the front.
  void _applyOrder() {
    final current = [for (final i in _settings.state.instances) i.url];
    if (state.sortBySpeed) {
      _reorder(_rankByLatency(current));
    } else if (_originalOrder case final original?) {
      _reorder([
        ...original.where(current.contains),
        ...current.where((url) => !original.contains(url)),
      ]);
    }
    final selected = state.selectedUrl;
    if (selected != null) _settings.preferInstance(selected);
  }

  /// Answering instances by ascending latency, then the others in their
  /// current order.
  List<String> _rankByLatency(List<String> urls) {
    Duration? latency(String url) {
      final ping = state.pings[url];
      return ping != null && ping.isSuccess ? ping.latency : null;
    }

    final answered = urls.where((url) => latency(url) != null).toList()
      ..sort((a, b) => latency(a)!.compareTo(latency(b)!));
    return [...answered, ...urls.where((url) => latency(url) == null)];
  }

  void _reorder(List<String> desired) {
    for (var target = 0; target < desired.length; target++) {
      final index = _settings.state.instances.indexWhere(
        (i) => i.url == desired[target],
      );
      if (index > target) _settings.moveInstance(index, target);
    }
  }

  /// Resets the result of "use my own instance" (e.g. while typing).
  void ownInstanceChanged() {
    if (state.ownInstanceStatus == OwnInstanceStatus.idle) return;
    _ownRun++;
    emit(
      state.copyWith(
        ownInstanceStatus: OwnInstanceStatus.idle,
        ownInstanceError: () => null,
        ownInstanceMessage: () => null,
        ownInstanceLatency: () => null,
      ),
    );
  }

  /// Validates [input] with `MozhiApiClient.normalizeBaseUrl`, pings it and
  /// on success adds it (unless already configured) and prefers it.
  ///
  /// A plain `http://` address outside this device and the local network
  /// is refused with [OwnInstanceError.insecure] ([isCleartextAllowed]): the
  /// app never sends text unencrypted to a public server.
  Future<void> addOwnInstance(String input) async {
    _ownRun++;
    if (input.trim().isEmpty) {
      _ownFailed(OwnInstanceError.empty);
      return;
    }
    final uri = normalizeOwnInstanceUrl(input);
    if (uri == null) {
      _ownFailed(OwnInstanceError.invalidUrl);
      return;
    }
    final url = uri.toString();
    if (!isCleartextAllowed(uri)) {
      _ownFailed(OwnInstanceError.insecure);
      return;
    }
    final run = _ownRun;
    emit(
      state.copyWith(
        ownInstanceStatus: OwnInstanceStatus.testing,
        ownInstanceError: () => null,
        ownInstanceMessage: () => null,
        ownInstanceLatency: () => null,
      ),
    );
    final existing = _settings.state.instances
        .where((i) => i.url == url)
        .firstOrNull;
    final instance = existing ?? MozhiInstance(url: url);
    try {
      final latency = await _repository
          .pingInstance(instance)
          .timeout(_pingTimeout);
      if (isClosed || run != _ownRun) return;
      if (existing == null) _settings.addInstance(instance);
      _userChoseInstance = true;
      emit(
        state.copyWith(
          ownInstanceStatus: OwnInstanceStatus.success,
          ownInstanceLatency: () => latency,
          selectedUrl: () => url,
          pings: {...state.pings, url: InstancePing.success(latency)},
        ),
      );
      _settings.preferInstance(url);
    } on TimeoutException {
      if (isClosed || run != _ownRun) return;
      _ownFailed(OwnInstanceError.timedOut);
    } on Object catch (error) {
      if (isClosed || run != _ownRun) return;
      _ownFailed(OwnInstanceError.unreachable, _describe(error));
    }
  }

  void _ownFailed(OwnInstanceError error, [String? message]) => emit(
    state.copyWith(
      ownInstanceStatus: OwnInstanceStatus.failure,
      ownInstanceError: () => error,
      ownInstanceMessage: () => message,
      ownInstanceLatency: () => null,
    ),
  );

  // AI provider

  /// Selects the preset [id] and resets the form to its defaults (keeping
  /// what was saved for it before).
  void selectPreset(String id) {
    final preset = AiProviderPreset.byId(id);
    if (preset == null || id == state.presetId) return;
    _providerRun++;
    final saved = state.saved[id];
    emit(
      state.copyWith(
        presetId: () => id,
        apiKey: saved?.apiKey ?? '',
        baseUrl: saved?.baseUrl ?? preset.baseUrl,
        model: saved?.model ?? preset.defaultModel,
        showProviderErrors: false,
        testStatus: ProviderTestStatus.idle,
        testOutput: () => null,
        testError: () => null,
        modelsStatus: ProviderTestStatus.idle,
        models: const [],
        modelsError: () => null,
      ),
    );
  }

  /// Updates the provider form; invalidates a previous test result.
  void updateProviderDraft({String? apiKey, String? baseUrl, String? model}) {
    final next = state.copyWith(apiKey: apiKey, baseUrl: baseUrl, model: model);
    if (next == state) return;
    final connectionChanged =
        next.apiKey != state.apiKey || next.baseUrl != state.baseUrl;
    _providerRun++;
    emit(
      next.copyWith(
        testStatus: ProviderTestStatus.idle,
        testOutput: () => null,
        testError: () => null,
        modelsStatus: connectionChanged ? ProviderTestStatus.idle : null,
        modelsError: connectionChanged ? () => null : null,
      ),
    );
  }

  /// Fetches the provider's models (needs a valid key/address, not a model).
  Future<void> loadModels() async {
    final errors = {...state.providerErrors}..remove(ProviderField.model);
    final config = state.draftConfig(_draftId);
    if (config == null) return;
    if (errors.isNotEmpty) {
      emit(state.copyWith(showProviderErrors: true));
      return;
    }
    final run = _providerRun;
    emit(
      state.copyWith(
        modelsStatus: ProviderTestStatus.running,
        modelsError: () => null,
      ),
    );
    try {
      final models = await _repository.listModels(config).timeout(_testTimeout);
      if (isClosed || run != _providerRun) return;
      emit(
        state.copyWith(
          modelsStatus: ProviderTestStatus.success,
          models: List.unmodifiable({for (final m in models) m.id}),
        ),
      );
    } on Object catch (error) {
      if (isClosed || run != _providerRun) return;
      emit(
        state.copyWith(
          modelsStatus: ProviderTestStatus.failure,
          modelsError: () =>
              error is TimeoutException ? null : _describe(error),
        ),
      );
    }
  }

  /// Validates the form and translates a test sentence with it.
  Future<void> testProvider() async {
    final config = state.draftConfig(_draftId);
    if (config == null) return;
    if (state.providerErrors.isNotEmpty) {
      emit(state.copyWith(showProviderErrors: true));
      return;
    }
    final run = _providerRun;
    emit(
      state.copyWith(
        testStatus: ProviderTestStatus.running,
        testOutput: () => null,
        testError: () => null,
      ),
    );
    try {
      final output = await _repository
          .testProvider(config)
          .timeout(_testTimeout);
      if (isClosed || run != _providerRun) return;
      emit(
        state.copyWith(
          testStatus: ProviderTestStatus.success,
          testOutput: () => output,
        ),
      );
    } on Object catch (error) {
      if (isClosed || run != _providerRun) return;
      emit(
        state.copyWith(
          testStatus: ProviderTestStatus.failure,
          testError: () => error is TimeoutException ? null : _describe(error),
        ),
      );
    }
  }

  /// Validates the form and saves it via `SettingsCubit.saveProvider`.
  /// Saving the same preset again replaces the provider saved before.
  void saveProvider() {
    final presetId = state.presetId;
    if (presetId == null) return;
    if (state.providerErrors.isNotEmpty) {
      emit(state.copyWith(showProviderErrors: true));
      return;
    }
    final id =
        state.saved[presetId]?.id ?? 'p${_clock().microsecondsSinceEpoch}';
    final config = state.draftConfig(id)!;
    _settings.saveProvider(config);
    emit(state.copyWith(saved: {...state.saved, presetId: config}));
  }

  String get _draftId => state.saved[state.presetId]?.id ?? 'onboarding';
}
