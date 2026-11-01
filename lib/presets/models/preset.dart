import 'package:equatable/equatable.dart';
import 'package:mozhi/presets/models/tombstone.dart';
import 'package:translation_repository/translation_repository.dart';

/// The built-in example presets that are seeded on first launch.
///
/// Their stored [Preset.name] stays empty until the user renames them, so the
/// UI can show a localised name. Likewise the [options] keep the English
/// context sentence while the user leaves it as it is: the UI shows and
/// applies it in the UI language instead (`PresetLabels.localizedPreset`).
enum BuiltInPreset {
  /// "Email to colleague (formal)".
  emailFormal,

  /// "Chat with friends (casual)".
  chatCasual,

  /// "Simple (A2 reading level)".
  simpleA2;

  /// The translation settings of the example.
  TranslationOptions get options => switch (this) {
    emailFormal => const TranslationOptions(
      formality: Formality.more,
      context: 'An email to a colleague at work.',
    ),
    chatCasual => const TranslationOptions(
      formality: Formality.less,
      context: 'A casual chat message to friends.',
    ),
    simpleA2 => const TranslationOptions(readingLevel: ReadingLevel.a2),
  };
}

/// A named set of [TranslationOptions] (style, formality, reading level,
/// genders, context and formatting), like Kagi Translate's presets.
///
/// The glossary and the one-off instructions of [options] are not part of a
/// preset: they are dropped when serialising and ignored by [appliesTo] and
/// `applyPresetAndGlossary`.
///
/// [updatedAt] says when the preset was last created or changed, for
/// backups and sync (the newer copy of a preset wins); it is not part of
/// `==`.
class Preset extends Equatable {
  const new({
    required this.id,
    this.name = '',
    this.options = const TranslationOptions(),
    this.builtIn,
    this.updatedAt,
  });

  /// A built-in example with a stable id (`builtin-<name>`).
  factory example(BuiltInPreset builtIn) => Preset(
    id: 'builtin-${builtIn.name}',
    options: builtIn.options,
    builtIn: builtIn,
  );

  /// Tolerant parser: unknown fields are ignored and invalid option values
  /// fall back to their defaults; an invalid `updatedAt` is ignored (presets
  /// stored before they had one have none). Throws [FormatException]
  /// without an id.
  factory fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('Preset without an id');
    }
    final name = json['name'];
    final options = json['options'];
    return Preset(
      id: id,
      name: name is String ? name : '',
      options: options is Map
          ? settingsOf(
              TranslationOptions.fromJson(Map<String, dynamic>.from(options)),
            )
          : const TranslationOptions(),
      builtIn: BuiltInPreset.values.asNameMap()[json['builtIn']],
      updatedAt: parseChangeTime(json['updatedAt']),
    );
  }

  final String id;

  /// User-given name. Empty for untouched built-in examples (see
  /// [BuiltInPreset]).
  final String name;

  final TranslationOptions options;

  /// Which example this preset started as, if any.
  final BuiltInPreset? builtIn;

  /// When the preset was last created or changed (renamed, its settings
  /// edited, put back after a delete); null for presets stored before
  /// presets had change times, and for the untouched built-in examples.
  /// Backups and sync keep the newer copy of a preset by [modifiedAt].
  ///
  /// Bookkeeping only: presets that differ only here are equal (`==`).
  final DateTime? updatedAt;

  /// [updatedAt], else the epoch (1970): a preset without a change time
  /// loses to any copy or deletion that has one.
  DateTime get modifiedAt => updatedAt ?? unknownChangeTime;

  /// [options] without the parts a preset does not carry (glossary and
  /// one-off instructions).
  static TranslationOptions settingsOf(TranslationOptions options) =>
      options.glossary.isEmpty && options.instructions.isEmpty
      ? options
      : options.copyWith(glossary: const {}, instructions: '');

  /// Whether [value] has exactly this preset's settings (its glossary and
  /// instructions are ignored).
  bool appliesTo(TranslationOptions value) =>
      settingsOf(value) == settingsOf(options);

  Preset copyWith({
    String? id,
    String? name,
    TranslationOptions? options,
    DateTime? updatedAt,
  }) => Preset(
    id: id ?? this.id,
    name: name ?? this.name,
    options: options ?? this.options,
    builtIn: builtIn,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// This preset without its [updatedAt] (for exports shared with others).
  Preset withoutChangeTime() => updatedAt == null
      ? this
      : Preset(id: id, name: name, options: options, builtIn: builtIn);

  /// `updatedAt` (UTC) is written only when there is one.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (builtIn != null) 'builtIn': builtIn!.name,
    'options': settingsOf(options).toJson()..remove('glossary'),
    if (updatedAt case final updatedAt?)
      'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  @override
  List<Object?> get props => [
    id,
    name,
    settingsOf(options),
    builtIn,
    // Not updatedAt: see there.
  ];
}

/// All presets in display order plus the id of the default one.
///
/// [orderUpdatedAt] and [defaultUpdatedAt] say when the order and the
/// default last changed, for backups and sync (the copy changed last
/// decides them); they are not part of `==`.
class PresetCollection extends Equatable {
  const new({
    this.presets = const [],
    this.defaultId,
    this.orderUpdatedAt,
    this.defaultUpdatedAt,
  });

  /// The built-in examples ([BuiltInPreset]) used on first launch.
  factory examples() => PresetCollection(
    presets: [
      for (final builtIn in BuiltInPreset.values) Preset.example(builtIn),
    ],
  );

  /// Parses [toJson] output (any `version`), or a bare list of presets.
  ///
  /// Invalid presets and duplicate ids are skipped and a [defaultId] that
  /// names no preset is dropped; invalid change times are ignored. Returns
  /// `null` when [json] has neither shape.
  static PresetCollection? tryParse(Object? json) {
    final List<dynamic> list;
    Object? defaultId;
    DateTime? orderUpdatedAt;
    DateTime? defaultUpdatedAt;
    if (json is List) {
      list = json;
    } else if (json is Map && json['presets'] is List) {
      list = json['presets'] as List;
      defaultId = json['defaultId'];
      orderUpdatedAt = parseChangeTime(json['orderUpdatedAt']);
      defaultUpdatedAt = parseChangeTime(json['defaultUpdatedAt']);
    } else {
      return null;
    }
    final ids = <String>{};
    final presets = <Preset>[];
    for (final element in list) {
      if (element is! Map) continue;
      try {
        final preset = Preset.fromJson(Map<String, dynamic>.from(element));
        if (ids.add(preset.id)) presets.add(preset);
      } on FormatException {
        continue;
      }
    }
    return PresetCollection(
      presets: List.unmodifiable(presets),
      defaultId: defaultId is String && ids.contains(defaultId)
          ? defaultId
          : null,
      orderUpdatedAt: orderUpdatedAt,
      defaultUpdatedAt: defaultUpdatedAt,
    );
  }

  /// Storage format version written by [toJson].
  static const version = 1;

  final List<Preset> presets;

  /// Id of the preset that is applied by default, if any.
  final String? defaultId;

  /// When the presets were last reordered (null: not since presets had
  /// change times). Merging two copies keeps the order of the copy
  /// reordered last.
  ///
  /// Bookkeeping only, like [defaultUpdatedAt]: not part of `==`.
  final DateTime? orderUpdatedAt;

  /// When the default preset was last chosen or cleared (null: not since
  /// presets had change times). Merging two copies keeps the default of
  /// the copy where it changed last.
  final DateTime? defaultUpdatedAt;

  Preset? get defaultPreset => byId(defaultId);

  Preset? byId(String? id) {
    if (id == null) return null;
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// The change times are written (UTC) only when there are any.
  Map<String, dynamic> toJson() => {
    'version': version,
    if (defaultPreset != null) 'defaultId': defaultId,
    if (orderUpdatedAt case final orderUpdatedAt?)
      'orderUpdatedAt': orderUpdatedAt.toUtc().toIso8601String(),
    if (defaultUpdatedAt case final defaultUpdatedAt?)
      'defaultUpdatedAt': defaultUpdatedAt.toUtc().toIso8601String(),
    'presets': [for (final preset in presets) preset.toJson()],
  };

  @override
  List<Object?> get props => [
    presets,
    defaultId,
    // Not the change times: see orderUpdatedAt.
  ];
}
