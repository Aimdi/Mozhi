import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';

/// In the translation's place while on-device AI loads its model (the
/// first request after a pause: [OnDeviceAiLoading] from [ai], default
/// the app's [OnDeviceAi]): "Loading the on-device model…", that the first
/// translation after a pause takes a few seconds, and Cancel
/// (`TranslateCubit.stopTranslation`). Shows nothing otherwise; the text
/// then streams in as usual. A progress ring, or with reduced motion a
/// still memory chip; a polite live region.
class OnDeviceAiLoadingNotice extends StatefulWidget {
  const new({this.ai, super.key});

  final OnDeviceAi? ai;

  @override
  State<OnDeviceAiLoadingNotice> createState() =>
      _OnDeviceAiLoadingNoticeState();
}

class _OnDeviceAiLoadingNoticeState extends State<OnDeviceAiLoadingNotice> {
  StreamSubscription<OnDeviceAiStatus>? _status;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_status != null) return;
    final ai = widget.ai ?? _maybeOnDeviceAi(context);
    if (ai == null) return;
    _loading = ai.currentStatus.isLoading;
    _status = ai.status.listen((status) {
      if (mounted && status.isLoading != _loading) {
        setState(() => _loading = status.isLoading);
      }
    });
  }

  /// The app's on-device AI, provided where it can run (Android).
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
    if (!_loading) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Padding(
      key: const Key('translate_on_device_ai_loading'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 20,
            child: still
                ? Icon(Icons.memory, size: 20, color: theme.colorScheme.primary)
                : const CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              liveRegion: true,
              container: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.translateOnDeviceAiLoading,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    l10n.translateOnDeviceAiLoadingHint,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const Key('translate_on_device_ai_loading_cancel'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: context.read<TranslateCubit>().stopTranslation,
            child: Text(l10n.commonCancel),
          ),
        ],
      ),
    );
  }
}
