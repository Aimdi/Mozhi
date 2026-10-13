import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/speech/speech_service.dart';

/// Read-aloud toggle backed by [SpeechService]; shows a stop icon while the
/// clip with [id] plays.
class ListenButton extends StatefulWidget {
  const new({
    required this.id,
    required this.text,
    required this.languageCode,
    super.key,
  });

  /// Button id passed to [SpeechService.toggle] (`source` / `target`).
  final String id;
  final String text;

  /// Null disables the button (e.g. undetected or custom language).
  final String? languageCode;

  @override
  State<ListenButton> createState() => _ListenButtonState();
}

class _ListenButtonState extends State<ListenButton> {
  late final SpeechService _speech = context.read<SpeechService>();
  late final Stream<String?> _speaking = _speech.speaking;

  Future<void> _toggle() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final message = context.l10n.translateSpeechError;
    try {
      await _speech.toggle(
        id: widget.id,
        text: widget.text,
        languageCode: widget.languageCode!,
      );
    } on Object {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled =
        widget.text.trim().isNotEmpty && widget.languageCode != null;
    return StreamBuilder<String?>(
      stream: _speaking,
      initialData: _speech.current,
      builder: (context, snapshot) {
        final playing = snapshot.data == widget.id;
        return IconButton(
          tooltip: playing ? l10n.commonStop : l10n.commonListen,
          isSelected: playing,
          icon: const Icon(Icons.volume_up_outlined),
          selectedIcon: const Icon(Icons.stop_circle_outlined),
          onPressed: enabled ? () => unawaited(_toggle()) : null,
        );
      },
    );
  }
}
