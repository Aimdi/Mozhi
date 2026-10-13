import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/output_card.dart' show copyToClipboard;
import 'package:share_plus/share_plus.dart';

/// Recognised text (editable for on-device recognition), the translation,
/// notes from vision models and the copy/share/"Open in translator"
/// actions.
class ImageTranslateResultSection extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ImageTranslateCubit>().state;
    final result = state.result;
    if (result == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final showTranslation =
        result.translatedText.isNotEmpty ||
        (!result.isComplete && state.isWorking);
    final hasActions =
        result.translatedText.isNotEmpty ||
        result.hasImage ||
        result.sourceText.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (result.sourceText.isNotEmpty)
          _SourceTextCard(
            text: result.sourceText,
            editable: state.canEditSourceText,
            busy: state.isWorking,
          ),
        if (showTranslation) ...[
          const SizedBox(height: 12),
          _TextCard(
            key: const Key('image_translate_translation'),
            label: l10n.imageTranslateTranslationLabel,
            text: result.translatedText,
            streaming: !result.isComplete && state.isWorking,
            emphasized: true,
          ),
        ],
        if (result.notes.isNotEmpty) ...[
          const SizedBox(height: 12),
          _TextCard(
            key: const Key('image_translate_notes'),
            label: l10n.imageTranslateNotesLabel,
            text: result.notes,
          ),
        ],
        if (hasActions && !state.isWorking) ...[
          const SizedBox(height: 8),
          _ResultActions(state: state, result: result),
        ],
      ],
    );
  }
}

class _TextCard extends StatelessWidget {
  const new({
    required this.label,
    required this.text,
    this.streaming = false,
    this.emphasized = false,
    super.key,
  });

  final String label;
  final String text;
  final bool streaming;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: emphasized
          ? theme.colorScheme.secondaryContainer
          : theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            if (streaming) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
            ],
            SelectableText(
              text,
              style: emphasized
                  ? theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    )
                  : theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceTextCard extends StatefulWidget {
  const new({required this.text, required this.editable, required this.busy});

  final String text;
  final bool editable;
  final bool busy;

  @override
  State<_SourceTextCard> createState() => _SourceTextCardState();
}

class _SourceTextCardState extends State<_SourceTextCard> {
  late final _controller = TextEditingController(text: widget.text);

  @override
  void didUpdateWidget(_SourceTextCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text && widget.text != _controller.text) {
      _controller.text = widget.text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Card(
      key: const Key('image_translate_source_text'),
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.imageTranslateSourceTextLabel,
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            if (widget.editable) ...[
              TextField(
                key: const Key('image_translate_source_field'),
                controller: _controller,
                minLines: 2,
                maxLines: 8,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  helperText: l10n.imageTranslateEditHint,
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.tonalIcon(
                  key: const Key('image_translate_retranslate_button'),
                  onPressed: widget.busy
                      ? null
                      : () => unawaited(
                          context.read<ImageTranslateCubit>().translateText(
                            _controller.text,
                          ),
                        ),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  icon: const Icon(Icons.translate),
                  label: Text(l10n.imageTranslateRetranslate),
                ),
              ),
            ] else
              SelectableText(widget.text, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _ResultActions extends StatelessWidget {
  const new({required this.state, required this.result});

  final ImageTranslateState state;
  final ImageTranslation result;

  Future<void> _share(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final image = result.translatedImage;
    final text = result.translatedText;
    await SharePlus.instance.share(
      ShareParams(
        text: text.isEmpty ? null : text,
        files: image == null
            ? null
            : [
                XFile.fromData(
                  image,
                  mimeType: 'image/png',
                  name: 'translation.png',
                ),
              ],
        sharePositionOrigin: origin,
      ),
    );
  }

  void _openInTranslator(BuildContext context) {
    final translate = context.read<TranslateCubit>();
    if (state.source != translate.state.source) {
      translate.setSource(state.source);
    }
    if (state.target != translate.state.target) {
      translate.setTarget(state.target);
    }
    translate.setInputAndTranslate(result.sourceText);
    context.go(AppRoutes.translate);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final text = result.translatedText;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (text.isNotEmpty)
          IconButton(
            key: const Key('image_translate_copy_button'),
            tooltip: l10n.commonCopy,
            icon: const Icon(Icons.copy_outlined),
            onPressed: () => unawaited(copyToClipboard(context, text)),
          ),
        if (text.isNotEmpty || result.hasImage)
          Builder(
            builder: (buttonContext) => IconButton(
              key: const Key('image_translate_share_button'),
              tooltip: l10n.commonShare,
              icon: const Icon(Icons.share_outlined),
              onPressed: () => unawaited(_share(buttonContext)),
            ),
          ),
        if (result.sourceText.isNotEmpty)
          TextButton.icon(
            key: const Key('image_translate_open_button'),
            onPressed: () => _openInTranslator(context),
            style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
            icon: const Icon(Icons.open_in_new),
            label: Text(l10n.imageTranslateOpenInTranslator),
          ),
      ],
    );
  }
}
