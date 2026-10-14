import 'package:equatable/equatable.dart';
import 'package:mozhi/speech/device_voice.dart';
import 'package:mozhi/speech/speech_language.dart';

export 'device_voice.dart';

/// Read-aloud preferences: the speech rate and a device voice per
/// language.
///
/// Persisted as JSON by `SpeechService` in its own store entry
/// (`SpeechService.settingsKey`), next to `SpeechService.preferDeviceKey`,
/// so the speech engine owns its settings and needs no `AppSettings`
/// round trip.
class SpeechSettings extends Equatable {
  const new({this.rate = defaultRate, this.voices = const {}});

  /// Tolerant counterpart of [toJson]: a missing or invalid rate reads as
  /// [defaultRate] (out-of-range rates are clamped), invalid voices and
  /// keys that are not speakable language codes are skipped. Never throws.
  factory fromJson(Map<String, dynamic> json) {
    final rate = json['rate'];
    final voices = json['voices'];
    return SpeechSettings(
      rate: rate is num ? normalizeRate(rate.toDouble()) : defaultRate,
      voices: Map.unmodifiable({
        if (voices is Map)
          for (final MapEntry(:key, :value) in voices.entries)
            if (key is String)
              ?speechLanguageTag(key): ?DeviceVoice.tryParse(value),
      }),
    );
  }

  /// Version of the JSON layout written by [toJson].
  static const schemaVersion = 1;

  /// Normal speed.
  static const defaultRate = 1.0;

  /// Slowest selectable rate.
  static const minRate = 0.5;

  /// Fastest selectable rate.
  static const maxRate = 1.5;

  /// Granularity of the rate (the settings slider moves in these steps).
  static const rateStep = 0.1;

  /// Speed factor of slow playback ("listen slowly", slow replay),
  /// relative to [rate]: 0.6x at the default rate.
  static const slowFactor = 0.6;

  /// [rate] clamped to [minRate]..[maxRate] and rounded to [rateStep];
  /// [defaultRate] for NaN or infinity.
  static double normalizeRate(double rate) {
    if (!rate.isFinite) return defaultRate;
    // Dividing by the step count (not multiplying by the step) keeps the
    // result the closest double to the decimal value (0.7, not 0.7000…1).
    const steps = 10; // 1 / rateStep
    return (rate.clamp(minRate, maxRate) * steps).round() / steps;
  }

  /// Playback speed multiplier (1.0 = normal), applied to the Mozhi audio
  /// and the device engine.
  final double rate;

  /// The device voice chosen per language, keyed by the device language
  /// tag ([speechLanguageTag], e.g. `fr`, `pt-BR`, `he`). Languages without
  /// an entry use the engine's default voice.
  final Map<String, DeviceVoice> voices;

  /// The playback speed for normal or [slow] playback.
  double speed({bool slow = false}) => slow ? rate * slowFactor : rate;

  /// The voice chosen for [languageCode] (a translation-engine code such as
  /// `iw` or a device tag such as `he`), or null for the default voice.
  DeviceVoice? voiceFor(String languageCode) {
    final tag = speechLanguageTag(languageCode);
    return tag == null ? null : voices[tag];
  }

  /// A copy with [voice] chosen for [languageCode] (null: back to the
  /// default voice). Unchanged when [languageCode] cannot be spoken.
  SpeechSettings withVoice(String languageCode, DeviceVoice? voice) {
    final tag = speechLanguageTag(languageCode);
    if (tag == null) return this;
    return copyWith(
      voices: Map.unmodifiable({
        for (final entry in voices.entries)
          if (entry.key != tag) entry.key: entry.value,
        tag: ?voice,
      }),
    );
  }

  /// Returns a copy with the given fields replaced; [rate] is normalised
  /// ([normalizeRate]).
  SpeechSettings copyWith({double? rate, Map<String, DeviceVoice>? voices}) {
    return SpeechSettings(
      rate: rate == null ? this.rate : normalizeRate(rate),
      voices: voices ?? this.voices,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': schemaVersion,
    'rate': rate,
    'voices': {
      for (final MapEntry(:key, :value) in voices.entries) key: value.toJson(),
    },
  };

  @override
  List<Object?> get props => [rate, voices];
}
