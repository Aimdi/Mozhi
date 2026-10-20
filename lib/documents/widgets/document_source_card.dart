import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/tab_hero.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/documents/core/core.dart';
import 'package:mozhi/documents/cubit/document_translate_cubit.dart';
import 'package:mozhi/documents/widgets/document_labels.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Picks the input: a file (with its details) or pasted text, its format,
/// and shows load errors.
class DocumentSourceCard extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<DocumentTranslateCubit>();
    final state = context.watch<DocumentTranslateCubit>().state;
    final busy = state.isTranslating || state.status == DocumentStatus.loading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        SegmentedButton<DocumentInputMode>(
          key: const Key('documents_mode'),
          segments: [
            ButtonSegment(
              value: DocumentInputMode.file,
              icon: const Icon(Icons.upload_file_outlined),
              label: Text(l10n.documentsModeFile),
            ),
            ButtonSegment(
              value: DocumentInputMode.text,
              icon: const Icon(Icons.notes),
              label: Text(l10n.documentsModeText),
            ),
          ],
          selected: {state.mode},
          onSelectionChanged: busy
              ? null
              : (selection) => cubit.setMode(selection.single),
        ),
        if (state.mode == DocumentInputMode.file)
          const _FileInput()
        else
          const _TextInput(),
        if (state.error case final error?)
          _ErrorBanner(
            message: documentErrorLabel(
              context,
              error,
              maxBytes: cubit.maxBytes,
            ),
            warning: error == DocumentError.nothingToTranslate,
          ),
        if (state.hasDocument) const DocumentInfoChips(),
      ],
    );
  }
}

class _FileInput extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<DocumentTranslateCubit>();
    final state = context.watch<DocumentTranslateCubit>().state;
    final loading = state.status == DocumentStatus.loading;
    final name = state.fileName;

    if (name == null) {
      // The empty state of the tabs: an accent icon, a bold headline, a
      // quiet hint and one pill button.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: TabHero(
          icon: Icons.description_outlined,
          title: l10n.documentsHeroTitle,
          body: l10n.documentsPickHint(
            documentSizeLabel(context, cubit.maxBytes),
          ),
          child: FilledButton.icon(
            key: const Key('documents_pick_file'),
            onPressed: loading ? null : () => unawaited(cubit.pickFile()),
            icon: loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.folder_open_outlined),
            label: Text(l10n.documentsPickButton),
          ),
        ),
      );
    }

    // The name and Replace share a line while they fit; otherwise (a long
    // name, large text) Replace moves below the name.
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            ExcludeSemantics(
              child: CircleAvatar(
                radius: 20,
                backgroundColor: theme.colorScheme.primary.withValues(
                  alpha: 0.12,
                ),
                foregroundColor: theme.colorScheme.primary,
                child: Icon(documentFormatIcon(state.format), size: 20),
              ),
            ),
            Flexible(
              child: Text(
                name,
                key: const Key('documents_file_name'),
                style: theme.textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        OutlinedButton(
          key: const Key('documents_replace_file'),
          onPressed: state.isTranslating || loading
              ? null
              : () => unawaited(cubit.pickFile()),
          child: Text(l10n.documentsReplaceFile),
        ),
      ],
    );
  }
}

class _TextInput extends StatefulWidget {
  const new();

  @override
  State<_TextInput> createState() => _TextInputState();
}

class _TextInputState extends State<_TextInput> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: context.read<DocumentTranslateCubit>().state.text,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<DocumentTranslateCubit>();
    return BlocListener<DocumentTranslateCubit, DocumentTranslateState>(
      listenWhen: (previous, current) =>
          current.mode == DocumentInputMode.text &&
          current.text != _controller.text,
      listener: (context, state) => _controller.value = TextEditingValue(
        text: state.text,
        selection: TextSelection.collapsed(offset: state.text.length),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          TextField(
            key: const Key('documents_text_field'),
            controller: _controller,
            enableIMEPersonalizedLearning: imeLearningAllowed(context),
            readOnly: context.select<DocumentTranslateCubit, bool>(
              (cubit) => cubit.state.isTranslating,
            ),
            minLines: 6,
            maxLines: 12,
            keyboardType: TextInputType.multiline,
            onChanged: cubit.setText,
            decoration: InputDecoration(
              labelText: l10n.documentsTextLabel,
              hintText: l10n.documentsTextHint,
              alignLabelWithHint: true,
            ),
          ),
          Row(
            children: [
              TextButton.icon(
                key: const Key('documents_paste'),
                onPressed: () => unawaited(cubit.pasteText()),
                icon: const Icon(Icons.content_paste),
                label: Text(l10n.documentsPaste),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A flat, hairline-outlined notice: an error (error colour) or a
/// warning (accent).
class _ErrorBanner extends StatelessWidget {
  const new({required this.message, this.warning = false});

  final String message;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = warning ? scheme.primary : scheme.error;
    return DecoratedBox(
      key: const Key('documents_error'),
      decoration: BoxDecoration(
        border: Border.all(
          color: warning
              ? AppPalette.of(context).hairline
              : scheme.error.withValues(alpha: 0.5),
        ),
        borderRadius: AppRadius.cardBorderRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          spacing: 12,
          children: [
            Icon(
              warning ? Icons.info_outline : Icons.error_outline,
              color: accent,
            ),
            Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

/// Format (selectable), size, segment and request counts, and a time
/// estimate.
class DocumentInfoChips extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<DocumentTranslateCubit>();
    final state = context.watch<DocumentTranslateCubit>().state;
    final format = state.format;
    final busy = state.isTranslating;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (format != null)
          MenuAnchor(
            builder: (context, controller, _) => InputChip(
              key: const Key('documents_format'),
              avatar: Icon(documentFormatIcon(format)),
              label: Text(documentFormatLabel(l10n, format)),
              tooltip: l10n.documentsFormatLabel,
              deleteIcon: const Icon(Icons.arrow_drop_down),
              onDeleted: busy ? null : controller.open,
              onPressed: busy ? null : controller.open,
              isEnabled: !busy,
            ),
            menuChildren: [
              for (final option in DocumentFormat.values)
                MenuItemButton(
                  key: Key('documents_format_${option.name}'),
                  leadingIcon: Icon(documentFormatIcon(option)),
                  trailingIcon: option == format
                      ? const Icon(Icons.check)
                      : null,
                  onPressed: () => cubit.setFormat(option),
                  child: Text(documentFormatLabel(l10n, option)),
                ),
            ],
          ),
        _InfoChip(
          icon: Icons.straighten,
          label: documentSizeLabel(context, state.sizeBytes),
        ),
        _InfoChip(
          icon: Icons.segment,
          label: l10n.documentsSegmentCount(state.segmentCount),
        ),
        if (state.chunkCount > 0) ...[
          _InfoChip(
            icon: Icons.send_outlined,
            label: l10n.documentsChunkCount(state.chunkCount),
          ),
          _InfoChip(
            icon: Icons.schedule,
            label: documentEstimateLabel(l10n, state.estimate),
          ),
        ],
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  const new({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}
