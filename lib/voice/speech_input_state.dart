import 'package:equatable/equatable.dart';

/// Why a voice input session failed, derived from the raw recogniser code.
enum SpeechInputFailure {
  /// Microphone or speech recognition permission denied.
  permissionDenied,

  /// The recogniser cannot handle the requested language (or the on-device
  /// model for it is not installed).
  languageUnavailable,

  /// No speech recogniser on this device / browser, or it is disabled.
  recognizerUnavailable,

  /// The microphone could not be opened.
  audio,

  /// Nothing was recognised (silence or unintelligible speech).
  noMatch,

  /// Network or server problem (cloud recognition).
  network,

  /// The recogniser is busy with another request.
  busy,

  /// The offline speech model (Whisper) is needed but not installed: it
  /// was chosen in the settings, or the privacy mode is Offline only.
  offlineModelMissing,

  /// The privacy mode is Offline only and no recogniser that is certain to
  /// stay on this device can run here (the browser, an unsupported CPU).
  offlineUnavailable,

  /// Anything else.
  unknown;

  /// Whether the failure blocks voice input until the user changes
  /// something (permissions, language, device settings).
  bool get isPermanent => switch (this) {
    permissionDenied || languageUnavailable || recognizerUnavailable => true,
    audio || offlineModelMissing || offlineUnavailable => true,
    noMatch || network || busy || unknown => false,
  };
}

/// State of the app-wide speech recogniser exposed by
/// `SpeechInputService.states`.
///
/// The `owner` of a session identifies the widget/caller that started it (the
/// `owner` passed to `SpeechInputService.listen`), so several voice buttons
/// can share one service and only the one that is listening reacts.
sealed class SpeechInputState extends Equatable {
  const new();

  bool get isListening => false;

  /// Whether this state belongs to a session started by [candidate].
  bool isOwnedBy(Object? candidate) => false;
}

/// Speech recognition is not supported or could not be initialised.
///
/// Hide voice input on unsupported platforms (`failure` null); otherwise
/// show it as off and explain [failure] when it is tapped (the next
/// `SpeechInputService.listen` tries again, e.g. asks for the permission).
final class SpeechInputUnavailable extends SpeechInputState {
  const new({this.failure});

  /// Why initialisation failed, when known (e.g.
  /// [SpeechInputFailure.permissionDenied]); null on unsupported platforms.
  final SpeechInputFailure? failure;

  @override
  List<Object?> get props => [failure];
}

/// Ready (or not initialised yet); not listening.
final class SpeechInputIdle extends SpeechInputState {
  const new();

  @override
  List<Object?> get props => [];
}

/// Listening to the microphone.
final class SpeechInputListening extends SpeechInputState {
  const new({
    this.level = 0,
    this.partialText = '',
    this.owner,
    this.detectsLanguage = false,
  });

  /// Input loudness normalised to `0..1` (0 when the platform does not
  /// report sound levels, e.g. on the web).
  final double level;

  /// Words recognised so far in this session.
  final String partialText;
  final Object? owner;

  /// Whether the recogniser detects the spoken language in this session
  /// (`SpeechInputService.listen` with `detectLanguage`): the final
  /// [SpeechInputResult.language] then says which one was heard.
  final bool detectsLanguage;

  @override
  bool get isListening => true;

  @override
  bool isOwnedBy(Object? candidate) => identical(owner, candidate);

  SpeechInputListening copyWith({double? level, String? partialText}) =>
      SpeechInputListening(
        level: level ?? this.level,
        partialText: partialText ?? this.partialText,
        owner: owner,
        detectsLanguage: detectsLanguage,
      );

  @override
  List<Object?> get props => [level, partialText, owner, detectsLanguage];
}

/// The microphone closed and the recording is being transcribed (offline
/// engines recognise after recording); the final result follows on
/// `SpeechInputService.results`.
final class SpeechInputTranscribing extends SpeechInputState {
  const new({this.owner});

  final Object? owner;

  @override
  bool isOwnedBy(Object? candidate) => identical(owner, candidate);

  @override
  List<Object?> get props => [owner];
}

/// The last session failed. Voice input can be retried (unless the state
/// is followed by [SpeechInputUnavailable]).
final class SpeechInputError extends SpeechInputState {
  const new(
    this.message, {
    required this.permanent,
    this.failure = SpeechInputFailure.unknown,
    this.owner,
  });

  /// Raw recogniser code; not meant for display.
  final String message;

  /// Whether the user has to change something before retrying (see
  /// [SpeechInputFailure.isPermanent]).
  final bool permanent;
  final SpeechInputFailure failure;
  final Object? owner;

  @override
  bool isOwnedBy(Object? candidate) => identical(owner, candidate);

  @override
  List<Object?> get props => [message, permanent, failure, owner];
}

/// Recognised text from a listen session (`SpeechInputService.results`).
///
/// Partial results grow as the user speaks; [text] always holds the whole
/// utterance so far, not just the new words.
final class SpeechInputResult extends Equatable {
  const new(this.text, {required this.isFinal, this.owner, this.language});

  final String text;
  final bool isFinal;

  /// The `owner` passed to `SpeechInputService.listen`.
  final Object? owner;

  /// The app (BCP-47) code of the language a final result was heard in,
  /// when the recogniser reports it (e.g. the one Whisper detected; see
  /// `LanguageDetectingSpeechRecognizer`); null otherwise.
  final String? language;

  @override
  List<Object?> get props => [text, isFinal, owner, language];
}
