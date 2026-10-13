import 'package:equatable/equatable.dart';
import 'package:translation_repository/translation_repository.dart';

/// The built-in example presets that are seeded on first launch.
///
/// Their stored [Preset.name] stays empty until the user renames them, so the
/// UI can show a localised name. The [options] contain an English context
/// sentence: it is prompt data for the AI model, like the other prompts.
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
class Preset extends Equatable {
  const Preset({
    required this.id,
    this.name = '',
    this.options = const TranslationOptions(),
    this.builtIn,
  });

  /// A built-in example with a stable id (`builtin-<name>`).
  factory Preset.example(BuiltInPreset builtIn) => Preset(
    id: 'builtin-${builtIn.name}',
    options: builtIn.options,
    builtIn: builtIn,
  );

  /// Tolerant parser: unknown fields are ignored and invalid option values
  /// fall back to their defaults. Throws [FormatException] without an id.
  factory Preset.fromJson(Map<String, dynamic> json) {
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
    );
  }

  final String id;

  /// User-given name. Empty for untouched built-in examples (see
  /// [BuiltInPreset]).
  final String name;

  final TranslationOptions options;

  /// Which example this preset started as, if any.
  final BuiltInPreset? builtIn;

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

  Preset copyWith({String? id, String? name, TranslationOptions? options}) =>
      Preset(
        id: id ?? this.id,
        name: name ?? this.name,
        options: options ?? this.options,
        builtIn: builtIn,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (builtIn != null) 'builtIn': builtIn!.name,
    'options': settingsOf(options).toJson()..remove('glossary'),
  };

  @override
  List<Object?> get props => [id, name, settingsOf(options), builtIn];
}

/// All presets in display order plus the id of the default one.
class PresetCollection extends Equatable {
  const PresetCollection({this.presets = const [], this.defaultId});

  /// The built-in examples ([BuiltInPreset]) used on first launch.
  factory PresetCollection.examples() => PresetCollection(
    presets: [
      for (final builtIn in BuiltInPreset.values) Preset.example(builtIn),
    ],
  );

  /// Parses [toJson] output (any `version`), or a bare list of presets.
  ///
  /// Invalid presets and duplicate ids are skipped and a [defaultId] that
  /// names no preset is dropped. Returns `null` when [json] has neither
  /// shape.
  static PresetCollection? tryParse(Object? json) {
    final List<dynamic> list;
    Object? defaultId;
    if (json is List) {
      list = json;
    } else if (json is Map && json['presets'] is List) {
      list = json['presets'] as List;
      defaultId = json['defaultId'];
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
    );
  }

  /// Storage format version written by [toJson].
  static const version = 1;

  final List<Preset> presets;

  /// Id of the preset that is applied by default, if any.
  final String? defaultId;

  Preset? get defaultPreset => byId(defaultId);

  Preset? byId(String? id) {
    if (id == null) return null;
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    if (defaultPreset != null) 'defaultId': defaultId,
    'presets': [for (final preset in presets) preset.toJson()],
  };

  @override
  List<Object?> get props => [presets, defaultId];
}
