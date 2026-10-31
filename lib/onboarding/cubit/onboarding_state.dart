import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart'
    show Language;

/// The pages of the first-run flow, in order: after the welcome, at most
/// three screens: the privacy mode, the default languages (with their
/// offline downloads) and the online service. A device that can't
/// translate on its own (the web) skips the privacy mode (see
/// [OnboardingState.steps]).
///
/// AI providers are not part of the flow: the last step links to them in
/// the settings.
enum OnboardingStep { welcome, privacy, languages, service }

/// Outcome of pinging one Mozhi instance: translating a test word
/// (`TranslationRepository.pingInstance`). [noTranslation]: the server
/// answered but its engine did not translate (an HTTP 5xx error, or no
/// translation); [failure]: it could not be reached or refused.
enum PingStatus { pending, success, failure, timedOut, noTranslation }

/// Speed test of a single instance (see `OnboardingCubit`).
class InstancePing extends Equatable {
  const new({required this.status, this.latency, this.error});

  const new pending() : this(status: PingStatus.pending);

  const new success(Duration latency)
    : this(status: PingStatus.success, latency: latency);

  const new failure(String error)
    : this(status: PingStatus.failure, error: error);

  const new timedOut() : this(status: PingStatus.timedOut);

  const new noTranslation(String error)
    : this(status: PingStatus.noTranslation, error: error);

  final PingStatus status;

  /// Round-trip time, set for [PingStatus.success].
  final Duration? latency;

  /// Message of the error, set for [PingStatus.failure] and
  /// [PingStatus.noTranslation].
  final String? error;

  bool get isSuccess => status == PingStatus.success;

  @override
  List<Object?> get props => [status, latency, error];
}

/// Progress of "find the fastest instance".
enum ServiceStatus { idle, pinging, done }

/// Progress of "use my own instance".
enum OwnInstanceStatus { idle, testing, success, failure }

/// Why "use my own instance" failed ([insecure]: plain http outside the
/// local network that the user has not confirmed; [noTranslation]: the
/// server answered but did not translate the test word).
enum OwnInstanceError {
  empty,
  invalidUrl,
  unreachable,
  timedOut,
  insecure,
  noTranslation,
}

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
    this.onDevice = true,
    this.deviceLanguages = const [],
    this.preselectDownloads = false,
    this.freeBytes,
    this.downloadChoices = const {},
    this.pickedSource,
  });

  final OnboardingStep step;

  /// Whether the device translates on its own (an on-device engine). Without
  /// one (the web) the flow has no privacy step: its choice is a switch on
  /// the online service step.
  final bool onDevice;

  /// The steps of the flow, in order: every [OnboardingStep], without
  /// [OnboardingStep.privacy] when not [onDevice].
  List<OnboardingStep> get steps => onDevice
      ? OnboardingStep.values
      : const [
          OnboardingStep.welcome,
          OnboardingStep.languages,
          OnboardingStep.service,
        ];

  // Languages

  /// The phone's languages (BCP 47 tags, most preferred first): the
  /// languages step suggests a source language from them.
  final List<String> deviceLanguages;

  /// Whether the languages step checks the downloads of the picked pair
  /// for the user (on Android, when [freeBytes] says the phone has room).
  final bool preselectDownloads;

  /// The free storage for downloads, when known.
  final int? freeBytes;

  /// The user's own answers for the offline downloads of the languages
  /// step, by language code (true: download it when they tap Next).
  final Map<String, bool> downloadChoices;

  /// The source language the user last picked on the languages step (never
  /// "Detect language"), kept when they go back to detecting: it is
  /// suggested again when none of [deviceLanguages] differs from the
  /// target.
  final Language? pickedSource;

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

  /// Error message for [OwnInstanceError.unreachable] and
  /// [OwnInstanceError.noTranslation].
  final String? ownInstanceMessage;

  /// Latency of the own instance after a successful test.
  final Duration? ownInstanceLatency;

  /// Whether [step] is the last page of the flow.
  bool get isLastStep => step == steps.last;

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

  /// [noneReachable], and at least one server answered without
  /// translating ([PingStatus.noTranslation]): the connection works.
  bool get noneTranslates =>
      noneReachable &&
      pings.values.any((p) => p.status == PingStatus.noTranslation);

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
    bool? onDevice,
    int? Function()? freeBytes,
    Map<String, bool>? downloadChoices,
    Language? pickedSource,
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
      onDevice: onDevice ?? this.onDevice,
      deviceLanguages: deviceLanguages,
      preselectDownloads: preselectDownloads,
      freeBytes: freeBytes != null ? freeBytes() : this.freeBytes,
      downloadChoices: downloadChoices ?? this.downloadChoices,
      pickedSource: pickedSource ?? this.pickedSource,
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
    onDevice,
    deviceLanguages,
    preselectDownloads,
    freeBytes,
    downloadChoices,
    pickedSource,
  ];
}
