import 'package:equatable/equatable.dart';

/// The pages of the first-run flow, in order: after the welcome, at most
/// three screens: the privacy mode, the default languages (with their
/// offline downloads) and the online service. A device that can't
/// translate on its own (the web) skips the privacy mode (see
/// [OnboardingState.steps]).
///
/// AI providers are not part of the flow: the last step links to them in
/// the settings.
enum OnboardingStep { welcome, privacy, languages, service }

/// Outcome of pinging one Mozhi instance.
enum PingStatus { pending, success, failure, timedOut }

/// Latency check of a single instance (see `OnboardingCubit`).
class InstancePing extends Equatable {
  const new({required this.status, this.latency, this.error});

  const new pending() : this(status: PingStatus.pending);

  const new success(Duration latency)
    : this(status: PingStatus.success, latency: latency);

  const new failure(String error)
    : this(status: PingStatus.failure, error: error);

  const new timedOut() : this(status: PingStatus.timedOut);

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

/// Why "use my own instance" failed ([insecure]: plain http outside the
/// local network that the user has not confirmed).
enum OwnInstanceError { empty, invalidUrl, unreachable, timedOut, insecure }

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
  ];
}
