import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/cubit/presets_cubit.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:mozhi/presets/widgets/preset_labels.dart';
import 'package:mozhi/presets/widgets/preset_options_form.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens [PresetEditorSheet] to edit [preset], or to create a new preset
/// (prefilled with [initialOptions]) when [preset] is `null`. Saves through
/// the [PresetsCubit] in [context] and completes with the saved preset, or
/// `null` when dismissed.
Future<Preset?> showPresetEditor(
  BuildContext context, {
  Preset? preset,
  TranslationOptions initialOptions = const TranslationOptions(),
}) {
  final cubit = context.read<PresetsCubit>();
  return showModalBottomSheet<Preset>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => BlocProvider.value(
      value: cubit,
      child: PresetEditorSheet(preset: preset, initialOptions: initialOptions),
    ),
  );
}

/// Name, every option control and "use as default" for one preset.
class PresetEditorSheet extends StatefulWidget {
  const new({
    this.preset,
    this.initialOptions = const TranslationOptions(),
    super.key,
  });

  /// The preset to edit; `null` creates a new one.
  final Preset? preset;

  /// Options of a new preset.
  final TranslationOptions initialOptions;

  @override
  State<PresetEditorSheet> createState() => _PresetEditorSheetState();
}

class _PresetEditorSheetState extends State<PresetEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final PresetsCubit _cubit = context.read<PresetsCubit>();
  late final TextEditingController _name = TextEditingController(
    text: widget.preset == null ? '' : context.l10n.presetName(widget.preset!),
  );
  late TranslationOptions _options = Preset.settingsOf(
    widget.preset?.options ?? widget.initialOptions,
  );
  late bool _isDefault =
      widget.preset != null && _cubit.state.defaultId == widget.preset!.id;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final l10n = context.l10n;
    final existing = widget.preset;
    final Preset saved;
    if (existing == null) {
      saved = await _cubit.add(
        name: _name.text,
        options: _options,
        makeDefault: _isDefault,
      );
    } else {
      // Keep built-in examples localised while their name is unchanged.
      final name = _name.text.trim();
      final unchanged =
          existing.name.trim().isEmpty && name == l10n.presetName(existing);
      saved = existing.copyWith(name: unchanged ? '' : name, options: _options);
      await _cubit.update(saved);
      final wasDefault = _cubit.state.defaultId == existing.id;
      if (_isDefault != wasDefault) {
        await _cubit.setDefault(_isDefault ? existing.id : null);
      }
    }
    if (mounted) Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        minChildSize: 0.4,
        builder: (context, controller) => Form(
          key: _formKey,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        widget.preset == null
                            ? l10n.presetsEditorNewTitle
                            : l10n.presetsEditorEditTitle,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      key: const Key('preset_editor_name'),
                      controller: _name,
                      enableIMEPersonalizedLearning: imeLearningAllowed(
                        context,
                      ),
                      autofocus: widget.preset == null,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: l10n.presetsEditorName,
                        hintText: l10n.presetsEditorNameHint,
                      ),
                      validator: (value) => (value ?? '').trim().isEmpty
                          ? l10n.presetsEditorNameRequired
                          : null,
                    ),
                    PresetOptionsForm(
                      value: _options,
                      onChanged: (options) =>
                          setState(() => _options = options),
                    ),
                    SwitchListTile(
                      key: const Key('preset_editor_default'),
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.star_outline_rounded),
                      title: Text(l10n.presetsEditorDefault),
                      subtitle: Text(l10n.presetsEditorDefaultDescription),
                      value: _isDefault,
                      onChanged: (value) => setState(() => _isDefault = value),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: Text(l10n.commonCancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const Key('preset_editor_save'),
                        onPressed: _saving ? null : _save,
                        child: Text(l10n.commonSave),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
