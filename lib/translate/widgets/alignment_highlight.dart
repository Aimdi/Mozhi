import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/widgets/aligned_text.dart';

/// A [TextEditingController] that paints a phrase alignment into its text:
/// the [phrases] (source phrases of `TranslateState.alignment`) get a dotted
/// underline ([AlignedText.phraseStyle], as in the translation) and
/// [highlight] (the source phrase of the focused pair) [focusStyle].
///
/// The focus style has no background colour: text backgrounds are painted
/// with the text, above the caret and the selection highlight (on Android,
/// Windows, Linux and the web), and the caret usually is inside the focused
/// phrase.
///
/// Only the painted spans change: editing, selection and the IME composing
/// region work as usual. While a composing region is active nothing is
/// painted (the composing underline wins), and any edit of the text clears
/// the alignment.
class HighlightTextEditingController extends TextEditingController {
  new({super.text});

  /// The focused phrase in an editable text: a thick solid underline and
  /// text in the tertiary colour (at least 4.5:1 on Material 3 surfaces in
  /// light and dark themes), without a background.
  static TextStyle focusStyle(ColorScheme scheme) => TextStyle(
    color: scheme.tertiary,
    decoration: TextDecoration.underline,
    decorationColor: scheme.tertiary,
    decorationThickness: 3,
  );

  List<TextRange> _phrases = const [];
  TextRange? _highlight;

  /// The marked ranges of [text] (UTF-16 offsets).
  List<TextRange> get phrases => _phrases;

  /// The highlighted range of [text] (UTF-16 offsets), or null.
  TextRange? get highlight => _highlight;

  /// Marks [phrases] and highlights [highlight] in the current text. Empty
  /// ranges and ranges outside the text are ignored.
  void showAlignment({
    List<TextRange> phrases = const [],
    TextRange? highlight,
  }) {
    final valid = phrases.where(_fits).toList(growable: false);
    final focus = highlight != null && _fits(highlight) ? highlight : null;
    if (focus == _highlight && listEquals(valid, _phrases)) return;
    _phrases = valid;
    _highlight = focus;
    notifyListeners();
  }

  /// Removes the alignment.
  void clearAlignment() => showAlignment();

  bool _fits(TextRange range) =>
      range.isValid &&
      range.isNormalized &&
      !range.isCollapsed &&
      range.end <= text.length;

  @override
  set value(TextEditingValue newValue) {
    // The alignment belongs to the text it was set for.
    if (newValue.text != value.text) {
      _phrases = const [];
      _highlight = null;
    }
    super.value = newValue;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    required bool withComposing,
    TextStyle? style,
  }) {
    final highlight = _highlight;
    final composing =
        withComposing &&
        value.isComposingRangeValid &&
        !value.composing.isCollapsed;
    if ((highlight == null && _phrases.isEmpty) || composing) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final focusStyle = HighlightTextEditingController.focusStyle(scheme);
    final phraseStyle = AlignedText.phraseStyle(scheme);
    final ranges = [..._phrases, ?highlight];
    final cuts = {
      0,
      text.length,
      for (final range in ranges) ...[range.start, range.end],
    }.where((offset) => offset <= text.length).toList()..sort();
    bool covers(TextRange range, int start, int end) =>
        range.start <= start && end <= range.end;
    return TextSpan(
      style: style,
      children: [
        for (var i = 0; i + 1 < cuts.length; i++)
          if (cuts[i] < cuts[i + 1])
            TextSpan(
              text: text.substring(cuts[i], cuts[i + 1]),
              style:
                  highlight != null && covers(highlight, cuts[i], cuts[i + 1])
                  ? focusStyle
                  : _phrases.any((r) => covers(r, cuts[i], cuts[i + 1]))
                  ? phraseStyle
                  : null,
            ),
      ],
    );
  }
}
