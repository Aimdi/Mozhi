import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:bloc/bloc.dart';
import 'package:mozhi/core/network/network.dart'
    show isCleartextAllowed, mozhiEngineOf;
import 'package:mozhi/onboarding/cubit/onboarding_state.dart';
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/platform/free_space.dart';
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

/// Applies the default languages picked during onboarding (see
/// `SettingsCubit.setLanguages`).
typedef OnboardingLanguageSetter = void Function({
  Language? source,
  Language? target,
});

/// Drives the first-run flow: step navigation, the privacy mode, the
/// default languages, finding the fastest Mozhi instance and adding the
/// user's own instance. Every choice is applied to [SettingsCubit] right
/// away.
///
/// The languages step's offline downloads are checked by the user
/// ([chooseDownload]) or, on Android when the phone has room
/// ([loadFreeSpace]), for them; they start only when the user taps Next
/// (the step starts them, never this cubit).
///
/// Instances are only contacted when the user asks
/// ([findFastestInstance], [addOwnInstance]), never by themselves: each
/// one is a volunteer's server.
///
/// On a device that can't translate on its own (`onDevice` false, the
/// web) the flow skips the privacy step ([OnboardingState.steps]):
/// "Offline first" would ask before every language pair with nothing on
/// the device to fall back on. Arriving at the online service step then
/// selects [PrivacyMode.online] (still "Offline first", the default,
/// unless the user changed it); the step says where the text goes and
/// keeps the choice as a switch ([setAskBeforeSending]).
class OnboardingCubit extends Cubit<OnboardingState> {
  /// `pingTimeout` bounds each instance ping. `describeError` words
  /// failures for the user (default: [onboardingErrorMessage]; the page puts
  /// the network policy's reasons first). `setLanguages` applies the
  /// default languages (default: `SettingsCubit.setLanguages`; the page
  /// goes through the translator so that it shows them right away).
  /// `onDevice` says whether the device translates on its own (default:
  /// `TranslationRepository.hasOfflineEngine`). `deviceLanguages` are the
  /// phone's languages (default: the platform's locales,
  /// [OnboardingState.deviceLanguages]); `preselectDownloads` whether the
  /// languages step checks the pair's downloads when the phone has room
  /// (default: on Android) and `freeSpace` tells that room ([loadFreeSpace];
  /// default: `FreeSpace.instance`).
  new({
    required this._repository,
    required this._settings,
    this._pingTimeout = const Duration(seconds: 6),
    String Function(Object error)? describeError,
    OnboardingLanguageSetter? setLanguages,
    bool? onDevice,
    List<String> Function()? deviceLanguages,
    bool? preselectDownloads,
    Future<int?> Function()? freeSpace,
  }) : _describe = describeError ?? onboardingErrorMessage,
       _setLanguages = setLanguages ?? _settings.setLanguages,
       _freeSpace = freeSpace ?? FreeSpace.instance.availableBytes,
       super(
         OnboardingState(
           onDevice: onDevice ?? _hasOfflineEngine(_repository),
           deviceLanguages: List.unmodifiable(
             (deviceLanguages ?? _platformLanguages)(),
           ),
           preselectDownloads: preselectDownloads ?? runsOnAndroid,
         ),
       );

  static List<String> _platformLanguages() => [
    for (final locale in PlatformDispatcher.instance.locales)
      locale.toLanguageTag(),
  ];

  /// Whether [repository] has an on-device engine (true when it can't
  /// tell, e.g. a test double).
  static bool _hasOfflineEngine(TranslationRepository repository) {
    try {
      return repository.hasOfflineEngine;
    } on Object {
      return true;
    }
  }

  final String Function(Object error) _describe;
  final OnboardingLanguageSetter _setLanguages;
  final Future<int?> Function() _freeSpace;

  final TranslationRepository _repository;
  final SettingsCubit _settings;
  final Duration _pingTimeout;

  /// Instance order before onboarding first sorted it (restored when
  /// "sort by speed" is turned off).
  List<String>? _originalOrder;

  /// Whether the user picked an instance (it then wins over the fastest).
  bool _userChoseInstance = false;

  /// Whether the privacy mode was set for a device without an on-device
  /// engine (once) or chosen on the service step.
  bool _privacyChosen = false;
  int _pingRun = 0;
  int _ownRun = 0;

  // Navigation

  void next() {
    final steps = state.steps;
    final index = steps.indexOf(state.step);
    if (index < steps.length - 1) goTo(steps[index + 1]);
  }

  void back() {
    final steps = state.steps;
    final index = steps.indexOf(state.step);
    if (index > 0) goTo(steps[index - 1]);
  }

  /// Shows [step] (a step the flow skips is ignored).
  void goTo(OnboardingStep step) {
    if (step == state.step || !state.steps.contains(step)) return;
    emit(state.copyWith(step: step));
    if (step == OnboardingStep.service && !state.onDevice) {
      _preselectOnline();
    }
  }

  /// Without an on-device engine: selects [PrivacyMode.online] once,
  /// while the mode is still the default "Offline first".
  void _preselectOnline() {
    if (_privacyChosen) return;
    _privacyChosen = true;
    if (_settings.state.privacyMode == PrivacyMode.offlineFirst) {
      _settings.setPrivacyMode(PrivacyMode.online);
    }
  }

  /// Marks onboarding as complete in the settings.
  void finish() => _settings.completeOnboarding();

  // Privacy

  /// How willing the app is to send text over the network (saved at once).
  void setPrivacyMode(PrivacyMode mode) {
    _privacyChosen = true;
    if (_settings.state.privacyMode != mode) _settings.setPrivacyMode(mode);
  }

  /// The service step's switch on a device without an on-device engine:
  /// ask once for each language pair before text goes to a server
  /// ([PrivacyMode.offlineFirst]), or not ([PrivacyMode.online]).
  void setAskBeforeSending({required bool ask}) =>
      setPrivacyMode(ask ? PrivacyMode.offlineFirst : PrivacyMode.online);

  // Languages

  /// Makes [language] the default source language ([Language.auto]: detect
  /// it). Custom languages are ignored. A language (not "Detect language")
  /// is remembered as [OnboardingState.pickedSource].
  void setSourceLanguage(Language language) {
    if (language.isCustom || language == _settings.state.source) return;
    if (!language.isAuto && language != state.pickedSource) {
      emit(state.copyWith(pickedSource: language));
    }
    _setLanguages(source: language);
  }

  /// Makes [language] the default target language. Auto and custom
  /// languages are ignored.
  void setTargetLanguage(Language language) {
    if (language.isAuto ||
        language.isCustom ||
        language == _settings.state.target) {
      return;
    }
    _setLanguages(target: language);
  }

  /// Reads the free storage ([OnboardingState.freeBytes]) when downloads
  /// may be checked for the user ([OnboardingState.preselectDownloads]);
  /// asks the device only (nothing is sent). Unknown stays null.
  Future<void> loadFreeSpace() async {
    if (!state.preselectDownloads) return;
    int? bytes;
    try {
      bytes = await _freeSpace();
    } on Object {
      bytes = null;
    }
    if (isClosed || bytes == null) return;
    emit(state.copyWith(freeBytes: () => bytes));
  }

  /// The user checked ([download]) or unchecked the offline download of
  /// [code] on the languages step; checked ones start when they tap Next.
  void chooseDownload(String code, {required bool download}) {
    if (state.downloadChoices[code] == download) return;
    emit(
      state.copyWith(
        downloadChoices: {...state.downloadChoices, code: download},
      ),
    );
  }

  // Translation service

  /// The Mozhi engine instances are tested with while the app's engine is
  /// [engineId]: its Mozhi engine (`mozhi:deepl` -> `deepl`), else
  /// [defaultPingEngine], the app's default
  /// ([TranslationRepository.pingInstance]).
  static String pingEngineOf(String? engineId) =>
      mozhiEngineOf(engineId) ?? defaultPingEngine;

  /// [pingEngineOf] when no Mozhi engine is chosen.
  static const defaultPingEngine = 'google';

  String get _pingEngine => pingEngineOf(_settings.state.engineId);

  /// Tests every configured instance concurrently (each bounded by the ping
  /// timeout) by translating a fixed word with [pingEngineOf] (never any of
  /// the user's text), reporting results as they arrive: a server that
  /// answers but doesn't translate is [PingStatus.noTranslation], not
  /// fast. When all finished, the fastest instance (unless the user picked
  /// one) becomes preferred and, with [OnboardingState.sortBySpeed], the
  /// list is sorted by latency.
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
    final engine = _pingEngine;
    await Future.wait([for (final i in instances) _ping(i, engine, run)]);
    if (isClosed || run != _pingRun) return;
    if (!_userChoseInstance) {
      final fastest = state.fastestUrl;
      if (fastest != null) emit(state.copyWith(selectedUrl: () => fastest));
    }
    emit(state.copyWith(serviceStatus: ServiceStatus.done));
    _applyOrder();
  }

  Future<void> _ping(MozhiInstance instance, String engine, int run) async {
    InstancePing result;
    try {
      final latency = await _repository
          .pingInstance(instance, engine: engine)
          .timeout(_pingTimeout);
      result = InstancePing.success(latency);
    } on TimeoutException {
      result = const InstancePing.timedOut();
    } on InstanceDoesNotTranslateException catch (error) {
      result = InstancePing.noTranslation(_describe(error));
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

  /// Validates [input] with `MozhiApiClient.normalizeBaseUrl`, tests it
  /// like [findFastestInstance] and on success adds it (unless already
  /// configured) and prefers it. A server that doesn't offer the tested
  /// engine ([pingEngineOf]) at all is added too (the app then uses an
  /// engine it offers); one whose engine fails is refused with
  /// [OwnInstanceError.noTranslation].
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
      final latency = await _pingOwn(instance);
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
    } on InstanceDoesNotTranslateException catch (error) {
      if (isClosed || run != _ownRun) return;
      _ownFailed(OwnInstanceError.noTranslation, _describe(error));
    } on Object catch (error) {
      if (isClosed || run != _ownRun) return;
      _ownFailed(OwnInstanceError.unreachable, _describe(error));
    }
  }

  /// The latency of [instance] translating the test word with
  /// [pingEngineOf]; that of its answer when it is a Mozhi server without
  /// that engine (`InstanceDoesNotTranslateException.engineUnavailable`).
  Future<Duration> _pingOwn(MozhiInstance instance) async {
    final stopwatch = Stopwatch()..start();
    try {
      return await _repository
          .pingInstance(instance, engine: _pingEngine)
          .timeout(_pingTimeout);
    } on InstanceDoesNotTranslateException catch (error) {
      if (error.engineUnavailable) return stopwatch.elapsed;
      rethrow;
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
}
