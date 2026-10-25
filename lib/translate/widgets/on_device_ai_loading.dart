import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/on_device_ai_engine.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart'
    show TranslationEngine;

/// In the translation's place while on-device AI loads its model (the
/// first request after a pause: [OnDeviceAiLoading] from [ai], default
/// the app's [OnDeviceAi]): "Loading the on-device model…", that the first
/// translation after a pause takes a few seconds, and Cancel
/// (`TranslateCubit.stopTranslation`). Shows nothing otherwise; the text
/// then streams in as usual. A progress ring, or with reduced motion a
/// still memory chip; a polite live region.
///
/// [OnDeviceAiLoadingNotice.extra] is the same notice for an AI extra
/// (refine suggestions, alternatives, insights, explanations, dictionary,
/// proofreading, meaning check) waiting for the model: a hint about the
/// first request after a pause, and Cancel only with an [onCancel].
class OnDeviceAiLoadingNotice extends StatefulWidget {
  const new({this.ai, this.onCancel, super.key}) : _extra = false, _hint = null;

  /// The notice of an AI extra (see the class docs). `hint` replaces the
  /// default "The first request after a pause takes a few seconds."
  const new extra({this.ai, this.onCancel, this._hint, super.key})
    : _extra = true;

  final OnDeviceAi? ai;

  /// What Cancel does: by default the main translation's notice stops the
  /// translation and an extra's has no Cancel.
  final VoidCallback? onCancel;

  final bool _extra;
  final String? _hint;

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
    final ai = widget.ai ?? maybeOnDeviceAi(context);
    if (ai == null) return;
    _loading = ai.currentStatus.isLoading;
    _status = ai.status.listen((status) {
      if (mounted && status.isLoading != _loading) {
        setState(() => _loading = status.isLoading);
      }
    });
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
    final extra = widget._extra;
    final onCancel =
        widget.onCancel ??
        (extra ? null : context.read<TranslateCubit>().stopTranslation);
    return Padding(
      key: Key(
        extra ? 'on_device_ai_extra_loading' : 'translate_on_device_ai_loading',
      ),
      padding: EdgeInsets.only(bottom: extra ? 8 : 12),
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
                    widget._hint ??
                        (extra
                            ? l10n.onDeviceAiLoadingHint
                            : l10n.translateOnDeviceAiLoadingHint),
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ),
          if (onCancel != null) ...[
            const SizedBox(width: 8),
            TextButton(
              key: Key(
                extra
                    ? 'on_device_ai_extra_loading_cancel'
                    : 'translate_on_device_ai_loading_cancel',
              ),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onCancel,
              child: Text(l10n.commonCancel),
            ),
          ],
        ],
      ),
    );
  }
}

/// The app's on-device AI, provided where it can run (Android); null
/// elsewhere (the web, tests without it).
OnDeviceAi? maybeOnDeviceAi(BuildContext context) {
  try {
    return context.read<OnDeviceAi>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// The waiting state of an AI extra: [child] (its progress indicator) and,
/// when the extra runs on on-device AI ([engine] is an on-device AI
/// engine, [isOnDeviceAiEngine]) and the model is loading, the
/// [OnDeviceAiLoadingNotice.extra] above it. Just [child] otherwise.
class OnDeviceAiExtraLoading extends StatelessWidget {
  const new({
    required this.engine,
    required this.child,
    this.ai,
    this.onCancel,
    super.key,
  });

  /// The engine the extra uses (e.g. `TranslateState.assistEngine`).
  final TranslationEngine? engine;

  final Widget child;

  /// See [OnDeviceAiLoadingNotice.ai].
  final OnDeviceAi? ai;

  /// See [OnDeviceAiLoadingNotice.onCancel].
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final engine = this.engine;
    if (engine == null || !isOnDeviceAiEngine(engine)) return child;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OnDeviceAiLoadingNotice.extra(ai: ai, onCancel: onCancel),
        child,
      ],
    );
  }
}
