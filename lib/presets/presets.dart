/// Kagi-style translation presets and glossaries.
///
/// * Presets: named `TranslationOptions` settings with a default preset
///   (`PresetsCubit`, `PresetsRepository`, key `presets.v1`).
/// * Glossaries: term lists per language pair (`GlossaryCubit`,
///   `GlossaryRepository`, key `glossaries.v1`) merged by
///   `GlossaryCubit.activeGlossary`.
/// * `applyPresetAndGlossary` combines both with the current options.
/// * UI: `PresetsPage`, `GlossariesPage`, `GlossaryEditorPage`,
///   `PresetPicker` and `PresetsProviders`.
library;

export 'cubit/glossary_cubit.dart';
export 'cubit/presets_cubit.dart';
export 'data/glossary_repository.dart';
export 'data/glossary_table.dart';
export 'data/id_generator.dart';
export 'data/presets_repository.dart';
export 'models/apply_preset.dart';
export 'models/glossary.dart';
export 'models/preset.dart';
export 'view/glossaries_page.dart';
export 'view/glossary_editor_page.dart';
export 'view/presets_page.dart';
export 'view/presets_providers.dart';
export 'widgets/preset_editor_sheet.dart'
    show PresetEditorSheet, showPresetEditor;
export 'widgets/preset_labels.dart';
export 'widgets/preset_picker.dart';
