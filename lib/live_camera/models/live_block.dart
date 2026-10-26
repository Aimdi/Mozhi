import 'dart:ui' show Rect;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mozhi/image_translate/models/text_layout.dart';

/// A paragraph the live camera keeps seeing, tracked across frames so that
/// its box holds still and it is translated once: [paragraph] (its text,
/// box in pixels of the upright frame, colours) and the [translation] of
/// [translatedFrom].
@immutable
class LiveBlock extends Equatable {
  const LiveBlock({
    required this.id,
    required this.paragraph,
    this.translation,
    this.translatedFrom,
    this.seen = 1,
    this.missed = 0,
  });

  /// Stable while the block is tracked.
  final int id;
  final TextParagraph paragraph;

  /// The translation shown: of [translatedFrom], which may be an older
  /// reading of [text] while the new one is translated.
  final String? translation;
  final String? translatedFrom;

  /// In how many frames it was found.
  final int seen;

  /// In how many frames in a row it was not found (it is kept for a few,
  /// so that a frame that misses it does not make it flicker).
  final int missed;

  String get text => paragraph.text;
  Rect get box => paragraph.box;

  /// Whether a translation is shown.
  bool get hasTranslation => translation != null;

  /// Whether [text] still has to be translated.
  bool get needsTranslation => translatedFrom != text;

  LiveBlock copyWith({
    TextParagraph? paragraph,
    String? Function()? translation,
    String? Function()? translatedFrom,
    int? seen,
    int? missed,
  }) => LiveBlock(
    id: id,
    paragraph: paragraph ?? this.paragraph,
    translation: translation != null ? translation() : this.translation,
    translatedFrom: translatedFrom != null
        ? translatedFrom()
        : this.translatedFrom,
    seen: seen ?? this.seen,
    missed: missed ?? this.missed,
  );

  /// This block showing [translation] of its current [text].
  LiveBlock translated(String translation) =>
      copyWith(translation: () => translation, translatedFrom: () => text);

  @override
  List<Object?> get props => [
    id,
    paragraph,
    translation,
    translatedFrom,
    seen,
    missed,
  ];
}
