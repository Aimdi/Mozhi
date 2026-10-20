import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/widgets/image_language_bar.dart';
import 'package:mozhi/image_translate/widgets/image_translate_links.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:share_plus/share_plus.dart';

/// Recognised text (editable for on-device recognition), the translation,
/// notes from vision models and the copy/share/"Open in translator"
/// actions. Text read poorly for "Detect language"
/// ([ImageTranslateState.hasLowRecognitionConfidence]) gets a "Wrong
/// language? Choose the language of the text" hint.
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
        if (state.hasLowRecognitionConfidence) const _LowConfidenceHint(),
        if (result.sourceText.isNotEmpty)
          _SourceTextCard(
            text: result.sourceText,
            editable: state.canEditSourceText,
            busy: state.isWorking,
          ),
        if (showTranslation) ...[
          if (result.sourceText.isNotEmpty) const Hairline(),
          _TextCard(
            key: const Key('image_translate_translation'),
            label: l10n.imageTranslateTranslationLabel,
            text: result.translatedText,
            streaming: !result.isComplete && state.isWorking,
            emphasized: true,
          ),
        ],
        if (result.notes.isNotEmpty) ...[
          const Hairline(),
          _TextCard(
            key: const Key('image_translate_notes'),
            label: l10n.imageTranslateNotesLabel,
            text: result.notes,
          ),
        ],
        if (result.destination case final destination?
            when result.isComplete && !state.isWorking)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: DestinationChip(
              key: const Key('image_translate_destination'),
              destination: destination,
              engineId: state.method?.engine?.id ?? state.translateEngine?.id,
            ),
          ),
        if (hasActions && !state.isWorking) ...[
          const Hairline(),
          _ResultActions(state: state, result: result),
          const Hairline(),
        ],
      ],
    );
  }
}

/// "Wrong language? Choose the language of the text": on-device
/// recognition read with the installed languages and was unsure.
class _LowConfidenceHint extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return Padding(
      key: const Key('image_translate_low_confidence'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(Icons.help_outline, size: 20, color: palette.secondaryText),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              l10n.imageTranslateLowConfidence,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette.secondaryText,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            flex: 2,
            child: TextButton(
              key: const Key('image_translate_low_confidence_choose'),
              style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: () =>
                  unawaited(pickImageLanguage(context, source: true)),
              child: Text(l10n.imageTranslateChooseSourceLanguage),
            ),
          ),
        ],
      ),
    );
  }
}

/// A flat result section: a bold label over the text (no card).
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
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Label(label),
          const SizedBox(height: 8),
          if (streaming) ...[
            LinearProgressIndicator(
              borderRadius: BorderRadius.circular(2),
              backgroundColor: palette.hairline,
            ),
            const SizedBox(height: 8),
          ],
          SelectableText(
            text,
            style: emphasized
                ? theme.textTheme.titleLarge?.copyWith(height: 1.35)
                : theme.textTheme.bodyMedium?.copyWith(
                    color: palette.secondaryText,
                  ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const new(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(fontWeight: FontWeight.w800),
    ),
  );
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
    final palette = AppPalette.of(context);
    return Padding(
      key: const Key('image_translate_source_text'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Label(l10n.imageTranslateSourceTextLabel),
          const SizedBox(height: 8),
          if (widget.editable) ...[
            TextField(
              key: const Key('image_translate_source_field'),
              controller: _controller,
              enableIMEPersonalizedLearning: imeLearningAllowed(context),
              minLines: 2,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                helperText: l10n.imageTranslateEditHint,
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.icon(
                key: const Key('image_translate_retranslate_button'),
                onPressed: widget.busy
                    ? null
                    : () => unawaited(
                        context.read<ImageTranslateCubit>().translateText(
                          _controller.text,
                        ),
                      ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  shape: const StadiumBorder(),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
                icon: const Icon(Icons.translate),
                label: Text(l10n.imageTranslateRetranslate),
              ),
            ),
          ] else
            SelectableText(
              widget.text,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: palette.secondaryText,
              ),
            ),
        ],
      ),
    );
  }
}

/// X-style action row: quiet icons (copy turns green with a check) and an
/// "Open in translator" pill.
class _ResultActions extends StatefulWidget {
  const new({required this.state, required this.result});

  final ImageTranslateState state;
  final ImageTranslation result;

  @override
  State<_ResultActions> createState() => _ResultActionsState();
}

class _ResultActionsState extends State<_ResultActions> {
  static const _copiedDuration = Duration(seconds: 2);

  bool _copied = false;
  Timer? _copiedTimer;

  ImageTranslation get result => widget.result;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy(String text) async {
    await copyImageTranslation(context, text);
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(_copiedDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

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
    final state = widget.state;
    final translate = context.read<TranslateCubit>();
    if (state.source != translate.state.source) {
      translate.setSource(state.source);
    }
    if (state.target != translate.state.target) {
      translate.setTarget(state.target);
    }
    translate.setInputAndTranslate(result.sourceText);
    context.go(ImageTranslateLinks.translator);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = AppPalette.of(context);
    final text = result.translatedText;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (text.isNotEmpty)
            XActionButton(
              key: const Key('image_translate_copy_button'),
              tooltip: l10n.commonCopy,
              icon: Icons.copy_outlined,
              activeIcon: Icons.check,
              active: _copied,
              activeColor: palette.success,
              onPressed: () => unawaited(_copy(text)),
            ),
          if (text.isNotEmpty || result.hasImage)
            Builder(
              builder: (buttonContext) => XActionButton(
                key: const Key('image_translate_share_button'),
                tooltip: l10n.commonShare,
                icon: Icons.share_outlined,
                onPressed: () => unawaited(_share(buttonContext)),
              ),
            ),
          if (result.sourceText.isNotEmpty)
            OutlinedButton.icon(
              key: const Key('image_translate_open_button'),
              onPressed: () => _openInTranslator(context),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                tapTargetSize: MaterialTapTargetSize.padded,
                shape: const StadiumBorder(),
                side: BorderSide(color: palette.hairline),
                textStyle: const TextStyle(fontWeight: FontWeight.w700),
              ),
              icon: const Icon(Icons.open_in_new),
              label: Text(l10n.imageTranslateOpenInTranslator),
            ),
        ],
      ),
    );
  }
}
