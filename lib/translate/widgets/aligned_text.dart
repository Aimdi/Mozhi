import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart' show AppLook;
import 'package:mozhi/core/widgets/focus_ring.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:translation_repository/translation_repository.dart';

/// Which side of an [AlignedSpan] a text is.
enum AlignedSide {
  /// The input ([AlignedSpan.sourceStart] / [AlignedSpan.sourceEnd]).
  source,

  /// The translation ([AlignedSpan.targetStart] / [AlignedSpan.targetEnd]).
  target,
}

/// A text whose aligned phrases (phrase alignment between the input and
/// the translation, `TranslateState.alignment`) can be tapped, and hovered
/// with a mouse, to highlight them and the phrase they correspond to on
/// the other side.
///
/// Tapping a phrase focuses its pair (`onFocus(index)`) and keeps it
/// focused; tapping it again clears the focus (`onFocus(null)`). Hovering
/// focuses a phrase while the pointer is over it, then goes back to the
/// tapped one. The [focus]ed phrase is drawn with [focusStyle]; the other
/// aligned phrases are underlined with [phraseStyle].
///
/// Keyboard: the text is one stop in the focus traversal (the app's focus
/// ring, [FocusRing], outlines it while focused). The arrow keys then
/// focus the next or previous phrase (in reading order, so Left and Right
/// follow [textDirection]), Enter or Space focuses the first phrase or
/// clears the focus, and Escape clears it.
///
/// Screen readers read the text in its language ([locale]), each phrase as
/// a link of its own in reading order; whitespace between two phrases is
/// no separate stop. Focusing a pair announces it with the phrase it
/// corresponds to ([other]) in the UI language. (A per-phrase label mixing
/// the UI language and both texts would be read with one voice.)
class AlignedText extends StatefulWidget {
  const new({
    required this.text,
    required this.alignment,
    required this.onFocus,
    this.focus,
    this.side = AlignedSide.target,
    this.other,
    this.style,
    this.textDirection,
    this.locale,
    super.key,
  });

  final String text;

  /// The alignment pairs (offsets into [text] on [side]).
  final List<AlignedSpan> alignment;

  /// Index into [alignment] of the highlighted pair, or null.
  final int? focus;

  /// Called with the pair to highlight (null clears the highlight).
  final ValueChanged<int?> onFocus;

  /// Which side of the pairs [text] is.
  final AlignedSide side;

  /// The text on the other side (for the announcement of the focused
  /// pair); null announces nothing.
  final String? other;
  final TextStyle? style;

  /// Direction of [text].
  final TextDirection? textDirection;

  /// Language of [text], so screen readers use a matching voice.
  final Locale? locale;

  /// Highlight of the focused phrase, on both sides: the tertiary
  /// container colours, whose contrast Material 3 guarantees in light and
  /// dark themes.
  static TextStyle focusStyle(ColorScheme scheme) => TextStyle(
    color: scheme.onTertiaryContainer,
    backgroundColor: scheme.tertiaryContainer,
    decoration: TextDecoration.underline,
    decorationColor: scheme.tertiary,
    decorationThickness: 2,
  );

  /// Marks the other aligned phrases as tappable (a dotted underline).
  static TextStyle phraseStyle(ColorScheme scheme) => TextStyle(
    decoration: TextDecoration.underline,
    decorationStyle: TextDecorationStyle.dotted,
    decorationColor: scheme.outline,
  );

  /// The start and end of [span] in a text on [side].
  static (int, int) bounds(AlignedSpan span, AlignedSide side) =>
      switch (side) {
        AlignedSide.source => (span.sourceStart, span.sourceEnd),
        AlignedSide.target => (span.targetStart, span.targetEnd),
      };

  /// Non-overlapping, non-empty (start, end, index) ranges of [alignment]
  /// in [text] (on [side]), in text order.
  ///
  /// Ranges are clipped to [text], widened so that they never split a
  /// surrogate pair, and dropped when empty, blank or overlapping an
  /// earlier pair.
  static List<(int, int, int)> ranges(
    String text,
    List<AlignedSpan> alignment, {
    AlignedSide side = AlignedSide.target,
  }) {
    final result = <(int, int, int)>[];
    for (final (index, span) in alignment.indexed) {
      var (start, end) = bounds(span, side);
      start = start.clamp(0, text.length);
      end = end.clamp(0, text.length);
      if (end <= start) continue;
      if (start > 0 && _isLowSurrogate(text.codeUnitAt(start))) start--;
      if (end < text.length && _isLowSurrogate(text.codeUnitAt(end))) end++;
      if (text.substring(start, end).trim().isEmpty) continue;
      if (result.any((r) => start < r.$2 && end > r.$1)) continue;
      result.add((start, end, index));
    }
    return result..sort((a, b) => a.$1.compareTo(b.$1));
  }

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  /// The phrase of pair [span] in [text] on [side], or '' when it lies
  /// outside [text].
  static String phrase(String text, AlignedSpan span, AlignedSide side) {
    final (start, end) = bounds(span, side);
    if (start < 0 || end > text.length || end <= start) return '';
    return text.substring(start, end).trim();
  }

  @override
  State<AlignedText> createState() => _AlignedTextState();
}

class _AlignedTextState extends State<AlignedText> {
  final _recognizers = <TapGestureRecognizer>[];
  final _focusNode = FocusNode(debugLabel: 'AlignedText');

  /// The phrase ranges of the last build ([AlignedText.ranges]).
  List<(int, int, int)> _ranges = const [];

  /// The pair focused by a tap, or from outside (kept when the mouse
  /// leaves a phrase).
  int? _pinned;

  /// The pair under the mouse pointer.
  int? _hovered;

  @override
  void initState() {
    super.initState();
    _pinned = widget.focus;
  }

  @override
  void didUpdateWidget(AlignedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Focused elsewhere (a tap on the other side) or cleared (a new
    // result): that is the pair to go back to after hovering.
    if (_hovered == null) _pinned = widget.focus;
  }

  @override
  void dispose() {
    _disposeRecognizers();
    _focusNode.dispose();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _tap(int index) {
    _pinned = _pinned == index ? null : index;
    if (widget.focus != _pinned) widget.onFocus(_pinned);
  }

  void _pin(int? index) {
    _pinned = index;
    if (widget.focus != index) widget.onFocus(index);
  }

  /// Focuses the phrase [delta] phrases after (or before) the focused one,
  /// in reading order; the first (or last) one when none is focused.
  void _step(int delta) {
    final ranges = _ranges;
    final current = ranges.indexWhere((range) => range.$3 == widget.focus);
    final next = current < 0
        ? (delta > 0 ? 0 : ranges.length - 1)
        : (current + delta).clamp(0, ranges.length - 1);
    _pin(ranges[next].$3);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_ranges.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final rtl =
        (widget.textDirection ?? Directionality.of(context)) ==
        TextDirection.rtl;
    final delta = switch (key) {
      LogicalKeyboardKey.arrowDown => 1,
      LogicalKeyboardKey.arrowUp => -1,
      LogicalKeyboardKey.arrowRight => rtl ? -1 : 1,
      LogicalKeyboardKey.arrowLeft => rtl ? 1 : -1,
      _ => null,
    };
    if (delta != null) {
      _step(delta);
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape) {
      if (widget.focus == null) return KeyEventResult.ignored;
      _pin(null);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _pin(widget.focus == null ? _ranges.first.$3 : null);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _enter(int index) {
    _hovered = index;
    if (widget.focus != index) widget.onFocus(index);
  }

  void _exit(int index) {
    if (_hovered != index) return;
    _hovered = null;
    // Rebuilt spans are left and entered again at once (new span objects
    // under the pointer): only restore the focus when no phrase was
    // entered by then.
    scheduleMicrotask(() {
      if (!mounted || _hovered != null) return;
      if (widget.focus != _pinned) widget.onFocus(_pinned);
    });
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final focusStyle = AlignedText.focusStyle(scheme);
    final phraseStyle = AlignedText.phraseStyle(scheme);
    final text = widget.text;
    final other = widget.other;
    final otherSide = widget.side == AlignedSide.target
        ? AlignedSide.source
        : AlignedSide.target;
    String? otherPhrase(AlignedSpan span) {
      if (other == null) return null;
      final phrase = AlignedText.phrase(other, span, otherSide);
      return phrase.isEmpty ? null : phrase;
    }

    // Text between phrases. Whitespace alone (between two phrases) gets an
    // empty label, so screen readers do not stop on it.
    TextSpan gap(String part) =>
        TextSpan(text: part, semanticsLabel: part.trim().isEmpty ? '' : null);

    final ranges = _ranges = AlignedText.ranges(
      text,
      widget.alignment,
      side: widget.side,
    );
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final (start, end, index) in ranges) {
      if (start > cursor) spans.add(gap(text.substring(cursor, start)));
      final recognizer = TapGestureRecognizer()..onTap = () => _tap(index);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: index == widget.focus ? focusStyle : phraseStyle,
          recognizer: recognizer,
          onEnter: (_) => _enter(index),
          onExit: (_) => _exit(index),
        ),
      );
      cursor = end;
    }
    if (cursor < text.length) spans.add(gap(text.substring(cursor)));

    final focus = widget.focus;
    String? announcement;
    if (focus != null && focus >= 0 && focus < widget.alignment.length) {
      final span = widget.alignment[focus];
      final phrase = AlignedText.phrase(text, span, widget.side);
      final counterpart = otherPhrase(span);
      if (phrase.isNotEmpty && counterpart != null) {
        announcement = widget.side == AlignedSide.target
            ? l10n.translateAlignmentFocused(phrase, counterpart)
            : l10n.translateAlignmentFocused(counterpart, phrase);
      }
    }
    return StatusAnnouncer(
      message: announcement,
      // The app's keyboard focus ring (it is not an ink well).
      child: FocusRing(
        key: const Key('translate_aligned_text_focus'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(
            Radius.circular(AppLook.of(context).controlRadius(4)),
          ),
        ),
        child: Focus(
          focusNode: _focusNode,
          canRequestFocus: ranges.isNotEmpty,
          // Screen readers move through the phrases (links) instead.
          includeSemantics: false,
          onKeyEvent: _onKey,
          child: Text.rich(
            key: const Key('translate_aligned_text'),
            TextSpan(children: spans, locale: widget.locale),
            style: widget.style,
            textDirection: widget.textDirection,
          ),
        ),
      ),
    );
  }
}
