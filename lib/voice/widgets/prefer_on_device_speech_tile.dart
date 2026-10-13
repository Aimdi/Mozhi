import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/voice/speech_input_service.dart';

/// Settings switch for "Prefer on-device speech recognition", stored by
/// [SpeechInputService.setPreferOnDevice].
///
/// Renders nothing where on-device recognition cannot be requested
/// (Windows, web, Linux). The default constructor reads the service with
/// `context.read<SpeechInputService>()`; [PreferOnDeviceSpeechTile.standalone]
/// takes it explicitly.
class PreferOnDeviceSpeechTile extends StatefulWidget {
  const new({super.key}) : service = null;

  const new standalone({required SpeechInputService this.service, super.key});

  final SpeechInputService? service;

  @override
  State<PreferOnDeviceSpeechTile> createState() =>
      _PreferOnDeviceSpeechTileState();
}

class _PreferOnDeviceSpeechTileState extends State<PreferOnDeviceSpeechTile> {
  late final SpeechInputService _service =
      widget.service ?? context.read<SpeechInputService>();

  @override
  void initState() {
    super.initState();
    unawaited(_service.loadSettings());
  }

  Future<void> _set({required bool value}) async {
    try {
      await _service.setPreferOnDevice(value: value);
    } on Object {
      // The switch already shows the new value; it is kept for this session.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_service.isOnDeviceSupported) return const SizedBox.shrink();
    final l10n = context.l10n;
    return ValueListenableBuilder<bool>(
      valueListenable: _service.preferOnDevice,
      builder: (context, value, _) => SwitchListTile(
        secondary: const Icon(Icons.mic_none_outlined),
        title: Text(l10n.voicePreferOnDeviceTitle),
        subtitle: Text(l10n.voicePreferOnDeviceSubtitle),
        value: value,
        onChanged: (value) => unawaited(_set(value: value)),
      ),
    );
  }
}
