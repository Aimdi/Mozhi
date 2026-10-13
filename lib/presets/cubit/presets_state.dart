import 'package:equatable/equatable.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:translation_repository/translation_repository.dart';

enum PresetsStatus { initial, loading, ready, failure }

class PresetsState extends Equatable {
  const PresetsState({
    this.status = PresetsStatus.initial,
    this.presets = const [],
    this.defaultId,
  });

  final PresetsStatus status;

  /// All presets in display order.
  final List<Preset> presets;

  /// Id of the default preset, if any.
  final String? defaultId;

  /// The default preset, if one is set.
  Preset? get defaultPreset => collection.defaultPreset;

  PresetCollection get collection =>
      PresetCollection(presets: presets, defaultId: defaultId);

  Preset? byId(String? id) => collection.byId(id);

  /// The first preset whose settings equal [options] (see
  /// [Preset.appliesTo]), preferring the default preset.
  Preset? presetFor(TranslationOptions options) {
    final preferred = defaultPreset;
    if (preferred != null && preferred.appliesTo(options)) return preferred;
    for (final preset in presets) {
      if (preset.appliesTo(options)) return preset;
    }
    return null;
  }

  PresetsState copyWith({
    PresetsStatus? status,
    List<Preset>? presets,
    String? Function()? defaultId,
  }) => PresetsState(
    status: status ?? this.status,
    presets: presets ?? this.presets,
    defaultId: defaultId == null ? this.defaultId : defaultId(),
  );

  @override
  List<Object?> get props => [status, presets, defaultId];
}
