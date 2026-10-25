import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/platform/device_conditions.dart';

/// While a long on-device AI job (a long text, a document or a web page,
/// part by part) waits between its parts because the phone is hot or
/// battery saver is on ([OnDeviceAiPaused] from [ai], default the app's
/// [OnDeviceAi]): "Paused while the phone cools down" (or "... while
/// battery saver is on"), that the rest follows once it is ready,
/// "Continue anyway" ([OnDeviceAi.continueAnyway]) and, with [onCancel],
/// Cancel. Shows nothing otherwise; a polite live region.
class OnDeviceAiPausedNotice extends StatefulWidget {
  const new({this.ai, this.onCancel, super.key});

  final OnDeviceAi? ai;

  /// What Cancel does (no Cancel without it).
  final VoidCallback? onCancel;

  @override
  State<OnDeviceAiPausedNotice> createState() => _OnDeviceAiPausedNoticeState();
}

class _OnDeviceAiPausedNoticeState extends State<OnDeviceAiPausedNotice> {
  StreamSubscription<OnDeviceAiStatus>? _status;
  OnDeviceAi? _ai;
  DeviceStrain? _strain;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_status != null) return;
    final ai = _ai = widget.ai ?? _maybeOnDeviceAi(context);
    if (ai == null) return;
    _strain = _strainOf(ai.currentStatus);
    _status = ai.status.listen((status) {
      final strain = _strainOf(status);
      if (mounted && strain != _strain) setState(() => _strain = strain);
    });
  }

  static DeviceStrain? _strainOf(OnDeviceAiStatus status) => switch (status) {
    OnDeviceAiPaused(:final strain) => strain,
    _ => null,
  };

  static OnDeviceAi? _maybeOnDeviceAi(BuildContext context) {
    try {
      return context.read<OnDeviceAi>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  void dispose() {
    unawaited(_status?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strain = _strain;
    final ai = _ai;
    if (strain == null || ai == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final (icon, title) = switch (strain) {
      DeviceStrain.heat => (
        Icons.thermostat_outlined,
        l10n.onDeviceAiPausedHeat,
      ),
      DeviceStrain.batterySaver => (
        Icons.battery_saver_outlined,
        l10n.onDeviceAiPausedBatterySaver,
      ),
    };
    final onCancel = widget.onCancel;
    return Padding(
      key: const Key('on_device_ai_paused'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ExcludeSemantics(
              child: Icon(icon, size: 20, color: theme.colorScheme.primary),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  liveRegion: true,
                  container: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.bodyMedium),
                      Text(
                        l10n.onDeviceAiPausedHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      key: const Key('on_device_ai_continue_anyway'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: ai.continueAnyway,
                      child: Text(l10n.onDeviceAiContinueAnyway),
                    ),
                    if (onCancel != null)
                      TextButton(
                        key: const Key('on_device_ai_paused_cancel'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: onCancel,
                        child: Text(l10n.commonCancel),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
