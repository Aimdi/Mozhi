import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show BrowserContextMenu;
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/word_lookup/cubit/word_lookup_cubit.dart'
    show WordLookupCubit;
import 'package:mozhi/word_lookup/data/word_segmenter.dart';
import 'package:mozhi/word_lookup/view/word_lookup_sheet.dart'
    show showWordLookupSheet;
import 'package:translation_repository/translation_repository.dart';

/// Most words of a selection in the source field offered for a word card
/// ("Look up"), as in the translation.
const inputLookUpMaxWords = 3;

/// The language of the words of [state]'s input, for their word card: the
/// source language, the detected one with "Detect language" (when the
/// catalogue knows it); null for a custom language or while undetected
/// (nothing to look the word up in).
Language? inputWordLookupLanguage(TranslateState state) {
  final source = state.source;
  if (source.isCustom) return null;
  if (!source.isAuto) return source;
  final detected = state.result?.detectedSource?.trim() ?? '';
  return detected.isEmpty ? null : LanguageCatalog.byCode(detected);
}

/// The language a word of [state]'s input is translated into on its word
/// card: the target language; null for "Detect language" or a custom one.
Language? inputWordLookupInto(TranslateState state) {
  final target = state.target;
  return target.isAuto || target.isCustom ? null : target;
}

/// The selected word or short phrase of [value] (trimmed, with where it
/// is), or null: no selection, or one without a letter or digit, longer
/// than [WordLookupCubit.maxWordLength], of more than [inputLookUpMaxWords]
/// words, or (in scripts written without spaces) of more than twice
/// [WordSegmenter.maxMatchLength] characters.
TextWord? inputSelectedWord(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid ||
      selection.isCollapsed ||
      selection.end > value.text.length) {
    return null;
  }
  final raw = selection.textInside(value.text);
  final word = raw.trim();
  if (word.isEmpty ||
      word.length > WordLookupCubit.maxWordLength ||
      !_letterOrDigit.hasMatch(word)) {
    return null;
  }
  final words = word.split(_space);
  if (words.length > inputLookUpMaxWords) return null;
  if (words.length == 1 &&
      word.characters.any(WordSegmenter.writtenWithoutSpaces) &&
      word.characters.length > 2 * WordSegmenter.maxMatchLength) {
    return null;
  }
  final start = selection.start + raw.length - raw.trimLeft().length;
  return TextWord(start, start + word.length, word);
}

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _space = RegExp(r'\s+');

/// "Look up" for the source field's context menu ([inputLookUpMenuItem]):
/// opens the word card ([showWordLookupSheet]: the offline dictionaries
/// first; an AI model only on the user's tap, under the privacy settings)
/// of the selected word or short phrase of [value] ([inputSelectedWord]),
/// in the language of [state]'s input, with its sentence as context.
/// [context] is the field's (the menu's own is above the screen's
/// providers). Does nothing without a word or a known language.
Future<void> lookUpInputSelection(
  BuildContext context,
  TextEditingValue value,
  TranslateState state,
) async {
  final word = inputSelectedWord(value);
  final language = inputWordLookupLanguage(state);
  if (word == null || language == null) return;
  await showWordLookupSheet(
    context,
    word: word.text,
    language: language,
    into: inputWordLookupInto(state),
    sentence: WordSegmenter.sentenceAround(value.text, word),
  );
}

/// The source field's "Look up" ([lookUpInputSelection]) for the context
/// menu of [field] (its `contextMenuBuilder`, next to the system's items),
/// or null when the selection is no word or short phrase
/// ([inputSelectedWord]) or the input's language is not known
/// ([inputWordLookupLanguage]). [context] is the field's.
ContextMenuButtonItem? inputLookUpMenuItem(
  BuildContext context,
  EditableTextState field,
  TranslateState state,
) {
  final value = field.textEditingValue;
  if (inputSelectedWord(value) == null ||
      inputWordLookupLanguage(state) == null) {
    return null;
  }
  return ContextMenuButtonItem(
    label: context.l10n.dictionaryLookUp,
    onPressed: () {
      field.hideToolbar();
      unawaited(lookUpInputSelection(context, value, state));
    },
  );
}

/// Turns the browser's context menu on ([enabled]) or off.
typedef BrowserContextMenuSwitch = Future<void> Function({
  required bool enabled,
});

// The browser only (tests pass their own switch).
// coverage:ignore-start
Future<void> _switchBrowserContextMenu({required bool enabled}) async {
  try {
    await (enabled
        ? BrowserContextMenu.enableContextMenu()
        : BrowserContextMenu.disableContextMenu());
  } on Object {
    // The browser keeps its menu: the field's selection still works.
  }
}
// coverage:ignore-end

/// In the web app, lets a text field show its own context menu (Cut,
/// Copy, Paste and Select all as Flutter offers them, plus "Look up")
/// instead of the browser's: the browser's menu is turned off from the
/// moment a pointer goes down on the field ([onPointerDown], e.g. its
/// `TapRegion.onTapInside`), and while it has the focus ([focusNode]); it
/// is on again once the field lost the focus, or a pointer went up without
/// focusing it ([onPointerUp]). Does nothing elsewhere (Android shows the
/// field's menu anyway).
///
/// (Flutter decides which menu a field shows when its selection overlay is
/// created, at the first selection after the focus: hence the pointer.)
class WebFieldContextMenu {
  new({
    required this.focusNode,
    this.web = kIsWeb,
    BrowserContextMenuSwitch? switchMenu,
  }) : _switch = switchMenu ?? _switchBrowserContextMenu {
    focusNode.addListener(_onFocusChanged);
    _onFocusChanged();
  }

  final FocusNode focusNode;

  /// Whether this is the web app.
  final bool web;

  final BrowserContextMenuSwitch _switch;

  /// Whether this turned the browser's menu off.
  bool get isOff => _off;
  bool _off = false;
  bool _disposed = false;
  Timer? _settling;

  /// How long after a pointer went up the field may still take the focus.
  static const settle = Duration(milliseconds: 100);

  /// A pointer went down on the field.
  void onPointerDown(PointerDownEvent _) => _turnOff();

  /// A pointer went up: once the gesture is over ([settle]), the browser's
  /// menu is on again unless the field took the focus.
  void onPointerUp(PointerUpEvent _) {
    if (!_off) return;
    _settling?.cancel();
    _settling = Timer(settle, () {
      _settling = null;
      if (!_disposed && !focusNode.hasFocus) _turnOn();
    });
  }

  /// Gives the browser its menu back.
  void dispose() {
    _disposed = true;
    _settling?.cancel();
    focusNode.removeListener(_onFocusChanged);
    _turnOn();
  }

  void _onFocusChanged() {
    if (focusNode.hasFocus) {
      _turnOff();
    } else {
      _turnOn();
    }
  }

  void _turnOff() {
    if (!web || _off || _disposed) return;
    _off = true;
    unawaited(_switch(enabled: false));
  }

  void _turnOn() {
    if (!web || !_off) return;
    _off = false;
    unawaited(_switch(enabled: true));
  }
}
