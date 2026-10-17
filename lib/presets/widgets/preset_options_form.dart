import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/widgets/preset_labels.dart';
import 'package:translation_repository/translation_repository.dart';

/// Controls for every preset setting: style, formality, reading level,
/// speaker / addressee gender, context and preserve formatting.
///
/// Stateless apart from the context text field; every change reports the
/// complete new options through [onChanged].
class PresetOptionsForm extends StatefulWidget {
  const new({required this.value, required this.onChanged, super.key});

  final TranslationOptions value;
  final ValueChanged<TranslationOptions> onChanged;

  @override
  State<PresetOptionsForm> createState() => _PresetOptionsFormState();
}

class _PresetOptionsFormState extends State<PresetOptionsForm> {
  late final TextEditingController _context = TextEditingController(
    text: widget.value.context,
  );

  @override
  void didUpdateWidget(PresetOptionsForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value.context != _context.text) {
      _context.text = widget.value.context;
    }
  }

  @override
  void dispose() {
    _context.dispose();
    super.dispose();
  }

  void _set(TranslationOptions options) => widget.onChanged(options);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final options = widget.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Label(l10n.translateOptionsStyle),
        SegmentedButton<TranslationStyle>(
          key: const Key('preset_form_style'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: TranslationStyle.natural,
              label: Text(l10n.translateStyleNatural),
            ),
            ButtonSegment(
              value: TranslationStyle.literal,
              label: Text(l10n.translateStyleLiteral),
            ),
          ],
          selected: {options.style},
          onSelectionChanged: (selection) =>
              _set(options.copyWith(style: selection.first)),
        ),
        _Label(l10n.translateOptionsFormality),
        _Choices<Formality>(
          keyPrefix: 'preset_form_formality',
          values: Formality.values,
          selected: options.formality,
          label: l10n.formalityLabel,
          onSelected: (value) => _set(options.copyWith(formality: value)),
        ),
        _Label(l10n.translateOptionsReadingLevel),
        DropdownButtonFormField<ReadingLevel>(
          key: const Key('preset_form_reading_level'),
          initialValue: options.readingLevel,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: [
            for (final level in ReadingLevel.values)
              DropdownMenuItem(
                value: level,
                child: Text(
                  l10n.readingLevelLabel(level),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) _set(options.copyWith(readingLevel: value));
          },
        ),
        _Label(l10n.translateOptionsSpeakerGender),
        _Choices<Gender>(
          keyPrefix: 'preset_form_speaker',
          values: Gender.values,
          selected: options.speakerGender,
          label: l10n.genderLabel,
          onSelected: (value) => _set(options.copyWith(speakerGender: value)),
        ),
        _Label(l10n.translateOptionsAddresseeGender),
        _Choices<Gender>(
          keyPrefix: 'preset_form_addressee',
          values: Gender.values,
          selected: options.addresseeGender,
          label: l10n.genderLabel,
          onSelected: (value) => _set(options.copyWith(addresseeGender: value)),
        ),
        _Label(l10n.translateOptionsContext),
        TextField(
          key: const Key('preset_form_context'),
          controller: _context,
          enableIMEPersonalizedLearning: imeLearningAllowed(context),
          minLines: 1,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (value) => _set(options.copyWith(context: value)),
          decoration: InputDecoration(
            hintText: l10n.translateOptionsContextHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('preset_form_formatting'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.translateOptionsPreserveFormatting),
          subtitle: Text(l10n.translateOptionsPreserveFormattingDescription),
          value: options.preserveFormatting,
          onChanged: (value) =>
              _set(options.copyWith(preserveFormatting: value)),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const new(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(
          text,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _Choices<T extends Enum> extends StatelessWidget {
  const new({
    required this.keyPrefix,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final String keyPrefix;
  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final value in values)
          ChoiceChip(
            key: Key('${keyPrefix}_${value.name}'),
            label: Text(label(value)),
            selected: value == selected,
            onSelected: (_) => onSelected(value),
          ),
      ],
    );
  }
}
