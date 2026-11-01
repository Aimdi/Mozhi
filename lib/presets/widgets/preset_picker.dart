import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/presets/models/apply_preset.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:mozhi/presets/widgets/preset_labels.dart';
import 'package:translation_repository/translation_repository.dart';

/// Layouts of [PresetPicker].
enum PresetPickerVariant {
  /// A horizontally scrolling row of choice chips.
  chips,

  /// A compact dropdown field.
  dropdown,
}

/// Compact preset selector for the translate options sheet: "Default", the
/// user's presets (the default preset is starred) and "Manage presets".
///
/// Reads the [PresetsCubit] in context. The selection is derived from
/// [value]: "Default" when its settings are the standard ones, otherwise the
/// first preset whose settings equal them ([PresetsState.presetFor]), or
/// none ("Custom" in the dropdown).
///
/// Choosing an entry calls [onChanged] with [value] updated through
/// [applyPresetAndGlossary] (the preset's settings replace the current ones;
/// the glossary and one-off instructions of [value] are kept). "Default"
/// resets the settings to the standard [TranslationOptions].
class PresetPicker extends StatelessWidget {
  const new({
    required this.value,
    required this.onChanged,
    this.onManagePresets,
    this.variant = PresetPickerVariant.chips,
    super.key,
  });

  /// The current options.
  final TranslationOptions value;

  final ValueChanged<TranslationOptions> onChanged;

  /// Shows a "Manage presets" entry when set (e.g. to open the presets page).
  final VoidCallback? onManagePresets;

  final PresetPickerVariant variant;

  static const _standard = Preset(id: '');

  void _select(Preset? preset) => onChanged(
    applyPresetAndGlossary(base: value, preset: preset ?? _standard),
  );

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PresetsCubit, PresetsState>(
      buildWhen: (previous, current) =>
          previous.collection != current.collection,
      builder: (context, stored) {
        // Examples in the UI language (their context sentences).
        final state = context.l10n.localizedPresets(stored);
        final isStandard = _standard.appliesTo(value);
        final selected = isStandard ? null : state.presetFor(value);
        return switch (variant) {
          PresetPickerVariant.chips => _chips(
            context,
            state,
            isStandard: isStandard,
            selected: selected,
          ),
          PresetPickerVariant.dropdown => _dropdown(
            context,
            state,
            isStandard: isStandard,
            selected: selected,
          ),
        };
      },
    );
  }

  Widget _chips(
    BuildContext context,
    PresetsState state, {
    required bool isStandard,
    required Preset? selected,
  }) {
    final l10n = context.l10n;
    return SingleChildScrollView(
      key: const Key('preset_picker_chips'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ChoiceChip(
            key: const Key('preset_picker_default'),
            label: Text(l10n.presetsPickerDefault),
            selected: isStandard,
            onSelected: (_) => _select(null),
          ),
          for (final preset in state.presets) ...[
            const SizedBox(width: 8),
            ChoiceChip(
              key: Key('preset_picker_${preset.id}'),
              avatar: preset.id == state.defaultId && selected != preset
                  ? const Icon(Icons.star_rounded)
                  : null,
              label: Text(l10n.presetName(preset)),
              selected: selected == preset,
              onSelected: (_) => _select(preset),
            ),
          ],
          if (onManagePresets != null) ...[
            const SizedBox(width: 8),
            ActionChip(
              key: const Key('preset_picker_manage'),
              avatar: const Icon(Icons.tune),
              label: Text(l10n.presetsPickerManage),
              onPressed: onManagePresets,
            ),
          ],
        ],
      ),
    );
  }

  static const _defaultValue = '\u0000default';
  static const _customValue = '\u0000custom';
  static const _manageValue = '\u0000manage';

  Widget _dropdown(
    BuildContext context,
    PresetsState state, {
    required bool isStandard,
    required Preset? selected,
  }) {
    final l10n = context.l10n;
    final current = isStandard ? _defaultValue : selected?.id ?? _customValue;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: l10n.presetsPickerLabel,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const Key('preset_picker_dropdown'),
          isExpanded: true,
          value: current,
          items: [
            DropdownMenuItem(
              value: _defaultValue,
              child: Text(l10n.presetsPickerDefault),
            ),
            for (final preset in state.presets)
              DropdownMenuItem(
                value: preset.id,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        l10n.presetName(preset),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (preset.id == state.defaultId) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.star_rounded,
                        size: 18,
                        semanticLabel: l10n.presetsDefaultBadge,
                      ),
                    ],
                  ],
                ),
              ),
            if (current == _customValue)
              DropdownMenuItem(
                value: _customValue,
                enabled: false,
                child: Text(l10n.presetsPickerCustom),
              ),
            if (onManagePresets != null)
              DropdownMenuItem(
                value: _manageValue,
                child: Row(
                  children: [
                    const Icon(Icons.tune, size: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        l10n.presetsPickerManage,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          onChanged: (id) {
            if (id == null || id == current) return;
            if (id == _manageValue) {
              onManagePresets?.call();
            } else if (id == _defaultValue) {
              _select(null);
            } else if (state.byId(id) case final preset?) {
              _select(preset);
            }
          },
        ),
      ),
    );
  }
}
