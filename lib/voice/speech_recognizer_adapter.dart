import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Status changes reported by a [SpeechRecognizerAdapter].
enum SpeechRecognizerStatus {
  /// The microphone is open and the recognizer is listening.
  listening,

  /// The microphone closed (stop, cancel, pause or listen timeout). A final
  /// result may still follow.
  notListening,

  /// All results of the session have been delivered.
  done,
}

/// An error reported by the platform recognizer.
///
/// [message] is the raw plugin code (`error_permission`, `error_no_match`,
/// `not-allowed`, ...); [permanent] is the plugin's own flag, which is not
/// reliable across platforms (Android marks every error as permanent).
@immutable
class SpeechRecognizerError extends Equatable {
  const new(this.message, {required this.permanent});

  final String message;
  final bool permanent;

  @override
  List<Object?> get props => [message, permanent];
}

/// A recognition locale offered by the device (`en-US`, `en_GB`, ...).
@immutable
class SpeechRecognizerLocale extends Equatable {
  const new(this.id, this.name);

  /// Identifier to pass back to [SpeechListenRequest.localeId].
  final String id;

  /// Display name, localised by the platform.
  final String name;

  @override
  List<Object?> get props => [id, name];
}

/// Options for a single listen session.
@immutable
class SpeechListenRequest extends Equatable {
  const new({
    this.localeId,
    this.onDevice = false,
    this.partialResults = true,
    this.listenMode = ListenMode.dictation,
    this.pauseFor = const Duration(seconds: 3),
    this.listenFor = const Duration(seconds: 60),
    this.autoPunctuation = true,
  });

  /// Recognizer locale id; null uses the system default.
  final String? localeId;

  /// Recognise on the device only (the session fails when unsupported).
  final bool onDevice;
  final bool partialResults;
  final ListenMode listenMode;

  /// Silence after which the session stops on its own.
  final Duration pauseFor;

  /// Maximum session length.
  final Duration listenFor;

  /// Adds punctuation where the platform supports it (iOS/macOS).
  final bool autoPunctuation;

  @override
  List<Object?> get props => [
    localeId,
    onDevice,
    partialResults,
    listenMode,
    pauseFor,
    listenFor,
    autoPunctuation,
  ];
}

/// Receives recognised words; [isFinal] marks the last result of a session.
typedef SpeechResultListener = void Function(
  String text, {
  required bool isFinal,
});

/// Thin seam over the platform speech recogniser so `SpeechInputService`
/// can be tested without platform channels.
abstract interface class SpeechRecognizerAdapter {
  /// Prepares the recogniser (may prompt for microphone / speech
  /// permission). Returns whether speech recognition is available.
  /// [onError] and [onStatus] receive events for every later session.
  Future<bool> initialize({
    required void Function(SpeechRecognizerError error) onError,
    required void Function(SpeechRecognizerStatus status) onStatus,
  });

  /// Whether microphone permission is granted, without prompting.
  Future<bool> hasPermission();

  /// Locales supported by the recogniser. Requires [initialize].
  Future<List<SpeechRecognizerLocale>> locales();

  /// The locale used when no locale id is passed, if known.
  Future<String?> systemLocaleId();

  /// Starts a listen session. Throws when the session cannot start.
  Future<void> listen({
    required SpeechListenRequest request,
    required SpeechResultListener onResult,
    required void Function(double level) onSoundLevel,
  });

  /// Stops listening; a final result follows.
  Future<void> stop();

  /// Stops listening and discards the session's results.
  Future<void> cancel();
}

/// [SpeechRecognizerAdapter] backed by `speech_to_text`.
///
/// The plugin singleton is only touched on first use, so constructing the
/// adapter never calls into platform code.
class SpeechToTextAdapter implements SpeechRecognizerAdapter {
  new({SpeechToText Function()? create}) : _create = create ?? SpeechToText.new;

  final SpeechToText Function() _create;
  SpeechToText? _instance;

  SpeechToText get _speech => _instance ??= _create();

  @override
  Future<bool> initialize({
    required void Function(SpeechRecognizerError error) onError,
    required void Function(SpeechRecognizerStatus status) onStatus,
  }) {
    return _speech.initialize(
      onError: (error) => onError(
        SpeechRecognizerError(error.errorMsg, permanent: error.permanent),
      ),
      onStatus: (status) {
        final mapped = switch (status) {
          SpeechToText.listeningStatus => SpeechRecognizerStatus.listening,
          SpeechToText.notListeningStatus =>
            SpeechRecognizerStatus.notListening,
          SpeechToText.doneStatus => SpeechRecognizerStatus.done,
          _ => null,
        };
        if (mapped != null) onStatus(mapped);
      },
      options: [SpeechToText.androidNoBluetooth],
    );
  }

  @override
  Future<bool> hasPermission() => _speech.hasPermission;

  @override
  Future<List<SpeechRecognizerLocale>> locales() async => [
    for (final locale in await _speech.locales())
      SpeechRecognizerLocale(locale.localeId, locale.name),
  ];

  @override
  Future<String?> systemLocaleId() async =>
      (await _speech.systemLocale())?.localeId;

  @override
  Future<void> listen({
    required SpeechListenRequest request,
    required SpeechResultListener onResult,
    required void Function(double level) onSoundLevel,
  }) async {
    await _speech.listen(
      onResult: (result) =>
          onResult(result.recognizedWords, isFinal: result.finalResult),
      onSoundLevelChange: onSoundLevel,
      listenOptions: SpeechListenOptions(
        localeId: request.localeId,
        onDevice: request.onDevice,
        partialResults: request.partialResults,
        listenMode: request.listenMode,
        pauseFor: request.pauseFor,
        listenFor: request.listenFor,
        autoPunctuation: request.autoPunctuation,
        cancelOnError: true,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}
