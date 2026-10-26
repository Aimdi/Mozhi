import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/speech/speech_service.dart';

/// The look of the word being read aloud: the secondary container colours,
/// whose contrast Material 3 guarantees in light and dark themes. A plain
/// background, so the word moves without any motion of its own.
TextStyle spokenWordStyle(ColorScheme scheme) => TextStyle(
  color: scheme.onSecondaryContainer,
  backgroundColor: scheme.secondaryContainer,
);

/// [text] as spans with [spoken] in [highlight] (merged over [style]);
/// [locale] tags every span. A [spoken] range outside [text] is ignored.
TextSpan spokenTextSpan(
  String text,
  TextRange? spoken, {
  required TextStyle highlight,
  TextStyle? style,
  Locale? locale,
}) {
  if (spoken == null ||
      !spoken.isValid ||
      spoken.isCollapsed ||
      spoken.end > text.length) {
    return TextSpan(text: text, style: style, locale: locale);
  }
  return TextSpan(
    style: style,
    locale: locale,
    children: [
      if (spoken.start > 0)
        TextSpan(text: text.substring(0, spoken.start), locale: locale),
      TextSpan(
        text: text.substring(spoken.start, spoken.end),
        style: (style ?? const TextStyle()).merge(highlight),
        locale: locale,
      ),
      if (spoken.end < text.length)
        TextSpan(text: text.substring(spoken.end), locale: locale),
    ],
  );
}

/// Builds [builder] with the part of [text] being read aloud while the
/// [SpeechService] above plays the clip [id] (the id its Listen button
/// gives `SpeechService.toggle`), from `SpeechService.spokenRanges`; null
/// otherwise: nothing is playing, another clip is, the engine reports no
/// progress (Mozhi clips, many online voices), [enabled] is false
/// (`AppSettings.highlightSpokenWord` off), there is no [SpeechService],
/// or the range does not fit [text] (it changed).
///
/// Only the look changes: nothing is announced to screen readers word by
/// word, and the highlight jumps from word to word without animation.
class SpokenRangeBuilder extends StatefulWidget {
  const new({
    required this.id,
    required this.text,
    required this.builder,
    this.enabled = true,
    super.key,
  });

  /// The clip whose reading is shown.
  final String id;

  /// The text given to the [SpeechService] for [id].
  final String text;

  final bool enabled;

  final Widget Function(BuildContext context, TextRange? spoken) builder;

  @override
  State<SpokenRangeBuilder> createState() => _SpokenRangeBuilderState();
}

class _SpokenRangeBuilderState extends State<SpokenRangeBuilder> {
  SpeechService? _speech;
  StreamSubscription<String?>? _speaking;
  StreamSubscription<SpokenRange?>? _ranges;
  SpokenRange? _range;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _listen();
  }

  @override
  void didUpdateWidget(SpokenRangeBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled || widget.id != oldWidget.id) {
      _stop();
      _range = null;
      if (widget.enabled) _listen();
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _listen() {
    final speech = _speech = _maybeSpeech();
    if (speech == null) return;
    try {
      _speaking = speech.speaking.listen(_onSpeaking);
      if (speech.current == widget.id) _watchRanges(speech);
    } on Object {
      // A service that reports nothing (a test double): no highlight.
      _stop();
    }
  }

  SpeechService? _maybeSpeech() {
    try {
      return context.read<SpeechService>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  void _onSpeaking(String? id) {
    final speech = _speech;
    if (speech == null) return;
    if (id == widget.id) {
      _watchRanges(speech);
      return;
    }
    unawaited(_ranges?.cancel());
    _ranges = null;
    _show(null);
  }

  void _watchRanges(SpeechService speech) {
    if (_ranges != null) return;
    try {
      _ranges = speech.spokenRanges.listen((range) {
        _show(speech.current == widget.id ? range : null);
      });
    } on Object {
      // No progress from this service.
    }
  }

  void _show(SpokenRange? range) {
    if (!mounted || range == _range) return;
    setState(() => _range = range);
  }

  void _stop() {
    unawaited(_speaking?.cancel());
    unawaited(_ranges?.cancel());
    _speaking = null;
    _ranges = null;
    _speech = null;
  }

  @override
  Widget build(BuildContext context) {
    final range = _range;
    final fits =
        widget.enabled &&
        range != null &&
        !range.isEmpty &&
        range.start >= 0 &&
        range.end <= widget.text.length;
    return widget.builder(
      context,
      fits ? TextRange(start: range.start, end: range.end) : null,
    );
  }
}
