import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/transcribe/models/transcript_entry.dart';
import 'package:mozhi/voice/cubit/voice_settings_state.dart'
    show VoiceModelError;
import 'package:mozhi/voice/speech_input_state.dart' show SpeechInputFailure;
import 'package:translation_repository/translation_repository.dart';

/// What can transcribe here (see `TranscribeCubit.load`).
enum TranscribeMode {
  /// Not known yet.
  unknown,

  /// On-device Whisper: speech stays on the device.
  whisper,

  /// The browser's speech recognition, which recognises continuously; it
  /// may send the audio to the browser's maker.
  system,

  /// Whisper runs here, but no speech model is installed.
  needsModel,

  /// Offline only is on and nothing that stays on the device can
  /// recognise speech here (the web app).
  offlineOnly,

  /// No speech recognition that can listen for long (no Whisper, and a
  /// system recogniser that stops after every pause).
  unavailable;

  bool get canListen => this == whisper || this == system;
}

/// Where a transcript is.
enum TranscribeStatus {
  /// Checking what can transcribe.
  loading,

  /// Not listening: nothing yet, or stopped.
  idle,

  /// The microphone opens (it may ask for the permission).
  starting,

  /// Listening.
  listening,

  /// Paused: the microphone is closed; resuming goes on with the same
  /// transcript.
  paused,
}

/// Why Transcribe paused on its own.
enum TranscribePauseReason {
  /// The user paused.
  user,

  /// The app went to the background (it can only listen on screen).
  background,
}

/// What became of "Save to History".
enum TranscribeHistoryOutcome {
  /// Saved as one entry.
  saved,

  /// History is paused: saved as a favourite (an explicit save).
  savedAsFavorite,

  /// It could not be saved.
  failed,
}

class TranscribeState extends Equatable {
  const new({
    required this.source,
    required this.target,
    this.mode = TranscribeMode.unknown,
    this.status = TranscribeStatus.loading,
    this.translate = false,
    this.entries = const [],
    this.partial = '',
    this.level = 0,
    this.heardSpeech = false,
    this.pending = 0,
    this.pauseReason,
    this.failure,
    this.failures = 0,
    this.voiceDetectionMissing = false,
    this.voiceDetectionProgress,
    this.voiceDetectionError,
    this.historyOutcome,
    this.historySaves = 0,
  });

  final TranscribeMode mode;
  final TranscribeStatus status;

  /// The language spoken ("Detect language" lets Whisper detect it per
  /// phrase).
  final Language source;

  /// The language of the translations.
  final Language target;

  /// Whether the user turned translation on (off on every new screen:
  /// nothing is translated until they do).
  final bool translate;

  /// One per phrase, oldest first.
  final List<TranscriptEntry> entries;

  /// Words of the phrase in progress (system recognisers).
  final String partial;

  /// Input loudness `0..1` while listening.
  final double level;

  /// Whether speech was heard in this recording.
  final bool heardSpeech;

  /// Phrases waiting for the engine.
  final int pending;

  /// Why the transcript is [TranscribeStatus.paused].
  final TranscribePauseReason? pauseReason;

  /// The last listening failure; [failures] counts them (each is shown
  /// once).
  final SpeechInputFailure? failure;
  final int failures;

  /// Whisper cuts phrases by loudness: the voice activity model is not
  /// installed (offer it).
  final bool voiceDetectionMissing;

  /// Fraction of its running download.
  final double? voiceDetectionProgress;

  /// Why its download failed.
  final VoiceModelError? voiceDetectionError;

  /// The last "Save to History"; [historySaves] counts them.
  final TranscribeHistoryOutcome? historyOutcome;
  final int historySaves;

  bool get isListening => status == TranscribeStatus.listening;

  /// The microphone is open or opening.
  bool get isRecording =>
      status == TranscribeStatus.listening ||
      status == TranscribeStatus.starting;

  /// Whether there is something to copy, export or save.
  bool get hasTranscript => entries.any((entry) => entry.hasText);

  /// Entries whose translation needs the user's consent.
  List<TranscriptEntry> get awaitingConsent => [
    for (final entry in entries)
      if (entry.translationStatus == TranscriptTranslationStatus.failed &&
          entry.translationError is ConsentRequiredException)
        entry,
  ];

  TranscribeState copyWith({
    TranscribeMode? mode,
    TranscribeStatus? status,
    Language? source,
    Language? target,
    bool? translate,
    List<TranscriptEntry>? entries,
    String? partial,
    double? level,
    bool? heardSpeech,
    int? pending,
    ValueGetter<TranscribePauseReason?>? pauseReason,
    ValueGetter<SpeechInputFailure?>? failure,
    int? failures,
    bool? voiceDetectionMissing,
    ValueGetter<double?>? voiceDetectionProgress,
    ValueGetter<VoiceModelError?>? voiceDetectionError,
    ValueGetter<TranscribeHistoryOutcome?>? historyOutcome,
    int? historySaves,
  }) => TranscribeState(
    mode: mode ?? this.mode,
    status: status ?? this.status,
    source: source ?? this.source,
    target: target ?? this.target,
    translate: translate ?? this.translate,
    entries: entries ?? this.entries,
    partial: partial ?? this.partial,
    level: level ?? this.level,
    heardSpeech: heardSpeech ?? this.heardSpeech,
    pending: pending ?? this.pending,
    pauseReason: pauseReason != null ? pauseReason() : this.pauseReason,
    failure: failure != null ? failure() : this.failure,
    failures: failures ?? this.failures,
    voiceDetectionMissing: voiceDetectionMissing ?? this.voiceDetectionMissing,
    voiceDetectionProgress: voiceDetectionProgress != null
        ? voiceDetectionProgress()
        : this.voiceDetectionProgress,
    voiceDetectionError: voiceDetectionError != null
        ? voiceDetectionError()
        : this.voiceDetectionError,
    historyOutcome: historyOutcome != null
        ? historyOutcome()
        : this.historyOutcome,
    historySaves: historySaves ?? this.historySaves,
  );

  @override
  List<Object?> get props => [
    mode,
    status,
    source,
    target,
    translate,
    entries,
    partial,
    level,
    heardSpeech,
    pending,
    pauseReason,
    failure,
    failures,
    voiceDetectionMissing,
    voiceDetectionProgress,
    voiceDetectionError,
    historyOutcome,
    historySaves,
  ];
}
