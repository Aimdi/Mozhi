import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:material_ui/material_ui.dart';

/// Tells a tap on a word of a [SelectableText] apart from the gestures
/// that select its text, so a tap can look the word up while selecting,
/// copying and the long press keep working.
///
/// Give the text [focusNode], [onSelectionChanged] and, as its `onTap`,
/// a call to [onTap] with a context above it. A tap reports the offset it
/// placed the caret at ([onWordTap]) after [delay] (the double-tap
/// timeout), unless by then the user selected text: a double tap or a
/// long press selects a word, a drag a range. A tap that only clears a
/// selection reports nothing. Focus leaving the text forgets the
/// selection (the text clears it).
class WordTapTracker {
  new({required this.onWordTap, this.delay = kDoubleTapTimeout}) {
    focusNode.addListener(_onFocusChanged);
  }

  /// Called with the offset of a tap on the text.
  final ValueChanged<int> onWordTap;

  /// How long a tap waits for a second one.
  final Duration delay;

  /// The text's focus node.
  final FocusNode focusNode = FocusNode(debugLabel: 'WordTapTracker');

  TextSelection? _selection;

  /// The latest selection change was a tap that cleared a selection.
  bool _dismissed = false;

  Timer? _pending;

  /// Whether text is selected (not just a caret).
  bool get hasSelection {
    final selection = _selection;
    return selection != null && selection.isValid && !selection.isCollapsed;
  }

  /// Whether a tap waits for [delay] before it is reported.
  bool get isPending => _pending != null;

  /// The text's selection changed.
  void onSelectionChanged(
    TextSelection selection,
    SelectionChangedCause? cause,
  ) {
    final hadSelection = hasSelection;
    _selection = selection;
    _dismissed =
        cause == SelectionChangedCause.tap &&
        selection.isCollapsed &&
        hadSelection;
    if (hasSelection) cancel();
  }

  /// The text was tapped ([context] is above its [EditableText]).
  void onTap(BuildContext context) {
    cancel();
    final dismissed = _dismissed;
    _dismissed = false;
    final selection =
        _editableTextBelow(context)?.textEditingValue.selection ?? _selection;
    if (dismissed ||
        selection == null ||
        !selection.isValid ||
        !selection.isCollapsed) {
      return;
    }
    final offset = selection.baseOffset;
    _pending = Timer(delay, () {
      _pending = null;
      if (!hasSelection) onWordTap(offset);
    });
  }

  /// Drops a tap waiting to be reported.
  void cancel() {
    _pending?.cancel();
    _pending = null;
  }

  void dispose() {
    cancel();
    focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
  }

  void _onFocusChanged() {
    if (focusNode.hasFocus) return;
    _selection = null;
    _dismissed = false;
  }

  static EditableTextState? _editableTextBelow(BuildContext context) {
    EditableTextState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        found = element.state as EditableTextState;
        return;
      }
      element.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    return found;
  }
}
