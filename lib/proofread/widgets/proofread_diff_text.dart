import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';
import 'package:mozhi/proofread/widgets/proofread_diff_colors.dart';

/// Renders [segments] as one paragraph: removed text struck through on the
/// error container, inserted text on a green container. Changed segments
/// that belong to an edit are tappable ([onEditTap]).
class ProofreadDiffText extends StatefulWidget {
  const new({
    required this.segments,
    this.onEditTap,
    this.style,
    super.key,
  });

  final List<DiffSegment> segments;
  final ValueChanged<int>? onEditTap;
  final TextStyle? style;

  @override
  State<ProofreadDiffText> createState() => _ProofreadDiffTextState();
}

class _ProofreadDiffTextState extends State<ProofreadDiffText> {
  final _recognizers = <TapGestureRecognizer>[];

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

  TapGestureRecognizer? _recognizerFor(DiffSegment segment) {
    final onEditTap = widget.onEditTap;
    final index = segment.editIndex;
    if (onEditTap == null || index == null) return null;
    final recognizer = TapGestureRecognizer()..onTap = () => onEditTap(index);
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final colors = ProofreadDiffColors.of(context);
    return Text.rich(
      TextSpan(
        style: widget.style,
        children: [
          for (final segment in widget.segments)
            TextSpan(
              text: segment.text,
              style: colors.styleFor(segment.type),
              semanticsLabel: ProofreadDiffColors.semanticsFor(
                context,
                segment,
              ),
              recognizer: segment.type == DiffType.unchanged
                  ? null
                  : _recognizerFor(segment),
            ),
        ],
      ),
    );
  }
}
