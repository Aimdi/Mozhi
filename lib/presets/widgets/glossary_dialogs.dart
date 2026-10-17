import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/presets/models/glossary.dart';
import 'package:mozhi/presets/widgets/language_scope_picker.dart';
import 'package:mozhi/presets/widgets/preset_labels.dart';

/// Name and language pair entered in [GlossaryDetailsDialog].
typedef GlossaryDetails = ({String name, String sourceCode, String targetCode});

/// Asks for a glossary's name and language pair. Prefilled from [glossary]
/// when editing. Completes with the details, or `null` when cancelled.
Future<GlossaryDetails?> showGlossaryDetailsDialog(
  BuildContext context, {
  Glossary? glossary,
}) => showDialog<GlossaryDetails>(
  context: context,
  builder: (_) => GlossaryDetailsDialog(glossary: glossary),
);

class GlossaryDetailsDialog extends StatefulWidget {
  const new({this.glossary, super.key});

  final Glossary? glossary;

  @override
  State<GlossaryDetailsDialog> createState() => _GlossaryDetailsDialogState();
}

class _GlossaryDetailsDialogState extends State<GlossaryDetailsDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.glossary?.name ?? '');
  late String _source = widget.glossary?.sourceCode ?? LanguageScope.any;
  late String _target = widget.glossary?.targetCode ?? LanguageScope.any;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick({required bool source}) async {
    final l10n = context.l10n;
    final code = await showLanguageScopePicker(
      context,
      title: source ? l10n.glossariesChooseSource : l10n.glossariesChooseTarget,
      selected: source ? _source : _target,
    );
    if (code == null || !mounted) return;
    setState(() => source ? _source = code : _target = code);
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(
      context,
    ).pop((name: _name.text.trim(), sourceCode: _source, targetCode: _target));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(
        widget.glossary == null
            ? l10n.glossariesDialogNewTitle
            : l10n.glossariesDialogEditTitle,
      ),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const Key('glossary_details_name'),
                controller: _name,
                enableIMEPersonalizedLearning: imeLearningAllowed(context),
                autofocus: widget.glossary == null,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: l10n.glossariesName,
                  hintText: l10n.glossariesNameHint,
                  border: const OutlineInputBorder(),
                ),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? l10n.glossariesNameRequired
                    : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              _LanguageField(
                key: const Key('glossary_details_source'),
                label: l10n.glossariesSourceLanguage,
                value: l10n.languageScopeName(_source),
                onTap: () => unawaited(_pick(source: true)),
              ),
              const SizedBox(height: 12),
              _LanguageField(
                key: const Key('glossary_details_target'),
                label: l10n.glossariesTargetLanguage,
                value: l10n.languageScopeName(_target),
                onTap: () => unawaited(_pick(source: false)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('glossary_details_submit'),
          onPressed: _submit,
          child: Text(
            widget.glossary == null ? l10n.glossariesCreate : l10n.commonSave,
          ),
        ),
      ],
    );
  }
}

class _LanguageField extends StatelessWidget {
  const new({
    required this.label,
    required this.value,
    required this.onTap,
    super.key,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            suffixIcon: const Icon(Icons.arrow_drop_down),
          ),
          child: Text(value, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

/// Asks for a glossary term; prefilled from [term] when editing. Completes
/// with the trimmed term, or `null` when cancelled.
Future<GlossaryTerm?> showGlossaryTermDialog(
  BuildContext context, {
  GlossaryTerm? term,
}) => showDialog<GlossaryTerm>(
  context: context,
  builder: (_) => GlossaryTermDialog(term: term),
);

class GlossaryTermDialog extends StatefulWidget {
  const new({this.term, super.key});

  final GlossaryTerm? term;

  @override
  State<GlossaryTermDialog> createState() => _GlossaryTermDialogState();
}

class _GlossaryTermDialogState extends State<GlossaryTermDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _source = TextEditingController(text: widget.term?.source ?? '');
  late final _target = TextEditingController(text: widget.term?.target ?? '');
  late final _note = TextEditingController(text: widget.term?.note ?? '');
  late bool _caseSensitive = widget.term?.caseSensitive ?? false;

  @override
  void dispose() {
    _source.dispose();
    _target.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      GlossaryTerm(
        source: _source.text,
        target: _target.text,
        note: _note.text,
        caseSensitive: _caseSensitive,
      ).trimmed(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String? required(String? value) =>
        (value ?? '').trim().isEmpty ? l10n.glossaryEditorRequired : null;
    return AlertDialog(
      title: Text(
        widget.term == null
            ? l10n.glossaryEditorNewTerm
            : l10n.glossaryEditorEditTerm,
      ),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const Key('glossary_term_source'),
                controller: _source,
                enableIMEPersonalizedLearning: imeLearningAllowed(context),
                autofocus: widget.term == null,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.glossaryEditorSource,
                  border: const OutlineInputBorder(),
                ),
                validator: required,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('glossary_term_target'),
                controller: _target,
                enableIMEPersonalizedLearning: imeLearningAllowed(context),
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.glossaryEditorTarget,
                  border: const OutlineInputBorder(),
                ),
                validator: required,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('glossary_term_note'),
                controller: _note,
                enableIMEPersonalizedLearning: imeLearningAllowed(context),
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: l10n.glossaryEditorNote,
                  border: const OutlineInputBorder(),
                ),
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                key: const Key('glossary_term_case'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(l10n.glossaryEditorCaseSensitive),
                subtitle: Text(l10n.glossaryEditorCaseSensitiveDescription),
                value: _caseSensitive,
                onChanged: (value) =>
                    setState(() => _caseSensitive = value ?? false),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('glossary_term_submit'),
          onPressed: _submit,
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
