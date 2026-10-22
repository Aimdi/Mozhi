import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';

/// Where the translation of a [TranscriptEntry] is.
enum TranscriptTranslationStatus {
  /// Waiting for its turn or being translated (the text may grow).
  translating,

  /// Translated.
  done,

  /// Not translated: [TranscriptEntry.translationError] says why (a
  /// `ConsentRequiredException` when the user's say is needed first).
  failed,
}

/// One paragraph of a transcript: a phrase of the recording ([start] and
/// [end] count from the start of the transcript, pauses left out) and,
/// when the user turned translation on, its translation.
@immutable
final class TranscriptEntry extends Equatable {
  const new({
    required this.id,
    required this.start,
    required this.end,
    this.text = '',
    this.language,
    this.status = PhraseStatus.transcribed,
    this.translation = '',
    this.translationStatus,
    this.translationError,
    this.engineId,
    this.engineName,
  });

  /// Unique in the transcript, in order.
  final int id;
  final Duration start;
  final Duration end;

  /// What was heard (empty for skipped and failed phrases).
  final String text;

  /// The app (BCP-47) code of the language it was heard in, when known.
  final String? language;

  /// Whether it was transcribed, skipped (transcription fell behind) or
  /// failed.
  final PhraseStatus status;

  final String translation;

  /// Null while it is not translated (translation off).
  final TranscriptTranslationStatus? translationStatus;
  final Object? translationError;

  /// The engine of [translation].
  final String? engineId;
  final String? engineName;

  /// Whether it has words (and can be translated).
  bool get hasText => status == PhraseStatus.transcribed && text.isNotEmpty;

  bool get isTranslated =>
      translationStatus == TranscriptTranslationStatus.done;

  TranscriptEntry copyWith({
    String? translation,
    ValueGetter<TranscriptTranslationStatus?>? translationStatus,
    ValueGetter<Object?>? translationError,
    ValueGetter<String?>? engineId,
    ValueGetter<String?>? engineName,
  }) => TranscriptEntry(
    id: id,
    start: start,
    end: end,
    text: text,
    language: language,
    status: status,
    translation: translation ?? this.translation,
    translationStatus: translationStatus != null
        ? translationStatus()
        : this.translationStatus,
    translationError: translationError != null
        ? translationError()
        : this.translationError,
    engineId: engineId != null ? engineId() : this.engineId,
    engineName: engineName != null ? engineName() : this.engineName,
  );

  @override
  List<Object?> get props => [
    id,
    start,
    end,
    text,
    language,
    status,
    translation,
    translationStatus,
    translationError,
    engineId,
    engineName,
  ];
}
