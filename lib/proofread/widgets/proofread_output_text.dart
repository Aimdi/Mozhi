import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/models/proofread_rephrasing.dart';
import 'package:mozhi/proofread/widgets/proofread_diff_colors.dart';

/// The result text: [segments] (see [ProofreadRephrasings.overlay]) as one
/// paragraph whose sentences can be tapped for alternative phrasings
/// ([onSentenceTap]).
///
/// With [showChanges] the diff is shown: removed text struck through,
/// inserted text highlighted, rephrased sentences on the tertiary
/// container with a dotted underline; a tap on a change that belongs to
/// an edit opens it ([onEditTap]), a tap anywhere else in a sentence (or a
/// long press anywhere in it, also on a change) opens the sentence's
/// alternatives. Without [showChanges] the plain text is shown, selectable
/// (a long press selects), and a tap on a sentence opens its
/// alternatives.
///
/// Screen readers get each sentence as a link and, on the paragraph, one
/// custom action per sentence ("Rephrase: …"), the long press's
/// counterpart.
class ProofreadOutputText extends StatefulWidget {
  const new({
    required this.segments,
    this.showChanges = true,
    this.onEditTap,
    this.onSentenceTap,
    this.style,
    super.key,
  });

  final List<OutputSegment> segments;
  final bool showChanges;
  final ValueChanged<int>? onEditTap;

  /// Called with the index of the sentence (see [OutputSegment.sentence]).
  final ValueChanged<int>? onSentenceTap;
  final TextStyle? style;

  /// Longest sentence preview in a screen-reader action label.
  static const maxActionPreview = 48;

  @override
  State<ProofreadOutputText> createState() => _ProofreadOutputTextState();
}

class _ProofreadOutputTextState extends State<ProofreadOutputText> {
  final _recognizers = <TapGestureRecognizer>[];
  final GlobalKey _textKey = GlobalKey();

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  TapGestureRecognizer _recognizer(VoidCallback onTap) {
    final recognizer = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(recognizer);
    return recognizer;
  }

  /// The segments shown: without removals in the plain text.
  List<OutputSegment> get _shown => widget.showChanges
      ? widget.segments
      : [
          for (final segment in widget.segments)
            if (segment.type != OutputSegmentType.removed) segment,
        ];

  GestureRecognizer? _recognizerFor(OutputSegment segment) {
    final onEditTap = widget.onEditTap;
    final edit = segment.editIndex;
    if (widget.showChanges &&
        onEditTap != null &&
        edit != null &&
        segment.type != OutputSegmentType.unchanged) {
      return _recognizer(() => onEditTap(edit));
    }
    final onSentenceTap = widget.onSentenceTap;
    final sentence = segment.sentence;
    if (onSentenceTap == null || sentence == null) return null;
    return _recognizer(() => onSentenceTap(sentence));
  }

  /// The text of each sentence as shown (without removals), by index.
  Map<int, String> _sentenceTexts() {
    final texts = <int, StringBuffer>{};
    for (final segment in widget.segments) {
      final sentence = segment.sentence;
      if (sentence == null || segment.type == OutputSegmentType.removed) {
        continue;
      }
      (texts[sentence] ??= StringBuffer()).write(segment.text);
    }
    return {
      for (final MapEntry(:key, :value) in texts.entries) key: value.toString(),
    };
  }

  static String _preview(String text) {
    final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final runes = line.runes.toList();
    if (runes.length <= ProofreadOutputText.maxActionPreview) return line;
    final cut = String.fromCharCodes(
      runes.take(ProofreadOutputText.maxActionPreview),
    );
    return '${cut.trimRight()}…';
  }

  /// Opens the alternatives of the sentence under a long press.
  void _onLongPress(LongPressStartDetails details) {
    final onSentenceTap = widget.onSentenceTap;
    final paragraph = _textKey.currentContext?.findRenderObject();
    if (onSentenceTap == null || paragraph is! RenderParagraph) return;
    final offset = paragraph
        .getPositionForOffset(paragraph.globalToLocal(details.globalPosition))
        .offset;
    int? sentence;
    var position = 0;
    for (final segment in _shown) {
      sentence = segment.sentence ?? sentence;
      position += segment.text.length;
      if (position > offset) break;
    }
    if (sentence != null) onSentenceTap(sentence);
  }

  TextStyle? _styleFor(ProofreadDiffColors colors, OutputSegment segment) {
    if (!widget.showChanges) return null;
    return switch (segment.type) {
      OutputSegmentType.unchanged => null,
      OutputSegmentType.removed => colors.removedStyle,
      OutputSegmentType.inserted => colors.insertedStyle,
      OutputSegmentType.rephrased => colors.rephrasedStyle,
    };
  }

  String? _semanticsFor(BuildContext context, OutputSegment segment) {
    if (!widget.showChanges) return null;
    final l10n = context.l10n;
    return switch (segment.type) {
      OutputSegmentType.unchanged => null,
      OutputSegmentType.removed => l10n.proofreadRemovedSemantics(segment.text),
      OutputSegmentType.inserted => l10n.proofreadInsertedSemantics(
        segment.text,
      ),
      OutputSegmentType.rephrased => l10n.proofreadRephrasedSemantics(
        segment.text,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final colors = ProofreadDiffColors.of(context);
    final span = TextSpan(
      style: widget.style,
      children: [
        for (final segment in _shown)
          TextSpan(
            text: segment.text,
            style: _styleFor(colors, segment),
            semanticsLabel: _semanticsFor(context, segment),
            recognizer: _recognizerFor(segment),
          ),
      ],
    );
    final text = widget.showChanges
        ? GestureDetector(
            onLongPressStart: widget.onSentenceTap == null
                ? null
                : _onLongPress,
            child: Text.rich(span, key: _textKey),
          )
        : SelectableText.rich(span);
    final onSentenceTap = widget.onSentenceTap;
    if (onSentenceTap == null) return text;
    final l10n = context.l10n;
    final sentences = _sentenceTexts();
    return Semantics(
      container: true,
      customSemanticsActions: {
        for (final MapEntry(:key, :value) in sentences.entries)
          CustomSemanticsAction(
            label: l10n.proofreadRephraseAction(_preview(value)),
          ): () =>
              onSentenceTap(key),
      },
      child: text,
    );
  }
}
