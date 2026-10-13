import 'dart:async';

import 'package:mozhi/voice/voice.dart';

/// Scriptable [SpeechRecognizerAdapter] for tests.
class FakeSpeechRecognizer implements SpeechRecognizerAdapter {
  bool initResult = true;
  Exception? initError;
  bool permission = true;
  Exception? permissionError;

  /// Errors reported through `onError` while [initialize] runs.
  List<SpeechRecognizerError> initErrors = [];

  /// Holds [initialize] until completed.
  Completer<void>? initGate;

  List<SpeechRecognizerLocale> localeList = const [
    SpeechRecognizerLocale('en_US', 'English (United States)'),
    SpeechRecognizerLocale('en_GB', 'English (United Kingdom)'),
    SpeechRecognizerLocale('fr_FR', 'French (France)'),
    SpeechRecognizerLocale('pt_BR', 'Portuguese (Brazil)'),
  ];
  Exception? localesError;
  String? systemLocale = 'en_US';
  Exception? listenError;

  /// Holds [listen] until completed.
  Completer<void>? listenGate;
  Exception? stopError;

  int initCalls = 0;
  int localeCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  final List<SpeechListenRequest> requests = [];

  late void Function(SpeechRecognizerError error) _onError;
  late void Function(SpeechRecognizerStatus status) _onStatus;
  late SpeechRecognizerResultListener _onResult;
  late void Function(double level) _onSoundLevel;

  SpeechListenRequest get lastRequest => requests.last;

  void emitResult(String text, {bool isFinal = false}) =>
      _onResult(text, isFinal: isFinal);

  void emitLevel(double level) => _onSoundLevel(level);

  void emitStatus(SpeechRecognizerStatus status) => _onStatus(status);

  void emitError(String message, {bool permanent = true}) =>
      _onError(SpeechRecognizerError(message, permanent: permanent));

  @override
  Future<bool> initialize({
    required void Function(SpeechRecognizerError error) onError,
    required void Function(SpeechRecognizerStatus status) onStatus,
  }) async {
    initCalls++;
    _onError = onError;
    _onStatus = onStatus;
    if (initGate case final gate?) await gate.future;
    initErrors.forEach(onError);
    if (initError case final error?) throw error;
    return initResult;
  }

  @override
  Future<bool> hasPermission() async {
    if (permissionError case final error?) throw error;
    return permission;
  }

  @override
  Future<List<SpeechRecognizerLocale>> locales() async {
    localeCalls++;
    if (localesError case final error?) throw error;
    return localeList;
  }

  @override
  Future<String?> systemLocaleId() async => systemLocale;

  @override
  Future<void> listen({
    required SpeechListenRequest request,
    required SpeechRecognizerResultListener onResult,
    required void Function(double level) onSoundLevel,
  }) async {
    requests.add(request);
    if (listenGate case final gate?) await gate.future;
    if (listenError case final error?) throw error;
    _onResult = onResult;
    _onSoundLevel = onSoundLevel;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (stopError case final error?) throw error;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (stopError case final error?) throw error;
  }
}
