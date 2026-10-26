import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/language_pair_bar.dart';
import 'package:mozhi/image_translate/widgets/image_translate_labels.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live/live_engine_picker.dart';
import 'package:mozhi/live_camera/cubit/live_camera_cubit.dart';
import 'package:mozhi/live_camera/widgets/live_camera_labels.dart';
import 'package:mozhi/live_camera/widgets/live_camera_messages.dart';
import 'package:translation_repository/translation_repository.dart';

/// The location the live camera goes back to when it cannot pop (it was
/// opened on its own): the image screen.
const _imageLocation = '/image';

/// Closes the live camera: back to the image screen.
void closeLiveCamera(BuildContext context) {
  final router = GoRouter.maybeOf(context);
  if (router == null) {
    Navigator.of(context).maybePop();
  } else if (router.canPop()) {
    router.pop();
  } else {
    router.go(_imageLocation);
  }
}

/// Close, the languages (source → target) and the live engine chip,
/// above the preview.
class LiveCameraTopBar extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (source, target, engine) = context
        .select<LiveCameraCubit, (Language, Language, TranslationEngine)>(
          (cubit) =>
              (cubit.state.source, cubit.state.target, cubit.state.engine),
        );
    final sourceLabel = imageLanguageLabel(l10n, source);
    final targetLabel = imageLanguageLabel(l10n, target);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            spacing: 8,
            children: [
              LiveCameraChromeButton(
                key: const Key('live_camera_close'),
                icon: Icons.close,
                tooltip: l10n.commonClose,
                onPressed: () => closeLiveCamera(context),
              ),
              Expanded(
                child: LanguagePairBar(
                  key: const Key('live_camera_language_bar'),
                  source: LanguagePairSide(
                    key: const Key('live_camera_source_button'),
                    label: sourceLabel,
                    semanticLabel: l10n.translateSourceLanguage(sourceLabel),
                    onPressed: () => unawaited(
                      pickLiveCameraLanguage(context, source: true),
                    ),
                  ),
                  target: LanguagePairSide(
                    key: const Key('live_camera_target_button'),
                    label: targetLabel,
                    semanticLabel: l10n.translateTargetLanguage(targetLabel),
                    onPressed: () => unawaited(
                      pickLiveCameraLanguage(context, source: false),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LiveEngineChip(engine: engine),
        ],
      ),
    );
  }
}

/// The live engine, opening "Translate live with" ([showLiveEnginePicker]).
class LiveEngineChip extends StatelessWidget {
  const new({required this.engine, super.key});

  final TranslationEngine engine;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    void open() => unawaited(showLiveEnginePicker(context));
    return Semantics(
      button: true,
      label: l10n.liveCameraEngineChip(engine.name),
      onTap: open,
      excludeSemantics: true,
      child: ActionChip(
        key: const Key('live_camera_engine_chip'),
        avatar: Icon(
          engine.isOnDevice ? Icons.phone_android : Icons.cloud_outlined,
        ),
        label: Text(engine.name, overflow: TextOverflow.ellipsis),
        tooltip: l10n.liveEnginePickerTitle,
        onPressed: open,
      ),
    );
  }
}

/// The status line (a live region: it changes with the status only, so it
/// is not read out for every frame), the hint, then the flashlight, Freeze
/// and zoom.
class LiveCameraBottomBar extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<LiveCameraCubit>().state;
    final cubit = context.read<LiveCameraCubit>();
    final preview = state.preview;
    final live = state.isLive;
    final status = liveCameraStatusText(l10n, state);
    final showHint =
        live &&
        state.translatedBlocks.isEmpty &&
        state.ocrMissing == null &&
        !state.ocrUnsupported;
    final onScrim = theme.textTheme.bodyMedium?.copyWith(color: Colors.white);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      status,
                      key: const Key('live_camera_status'),
                      textAlign: TextAlign.center,
                      style: onScrim,
                    ),
                  ),
                  if (showHint)
                    Text(
                      l10n.liveCameraHint,
                      key: const Key('live_camera_hint'),
                      textAlign: TextAlign.center,
                      style: onScrim?.copyWith(color: Colors.white70),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (preview != null && preview.hasTorch)
                LiveCameraChromeButton(
                  key: const Key('live_camera_torch'),
                  icon: state.torchOn
                      ? Icons.flashlight_off
                      : Icons.flashlight_on,
                  tooltip: state.torchOn
                      ? l10n.liveCameraTorchOff
                      : l10n.liveCameraTorchOn,
                  selected: state.torchOn,
                  onPressed: live
                      ? () => unawaited(cubit.setTorch(on: !state.torchOn))
                      : null,
                )
              else
                const SizedBox.square(dimension: 48),
              _FreezeButton(
                onPressed: live ? () => unawaited(cubit.freeze()) : null,
              ),
              if (preview != null && preview.maxZoom > preview.minZoom)
                _ZoomButton(
                  zoom: state.zoom,
                  onPressed: live
                      ? () => unawaited(
                          cubit.setZoom(
                            nextLiveCameraZoom(
                              state.zoom,
                              min: preview.minZoom,
                              max: preview.maxZoom,
                            ),
                          ),
                        )
                      : null,
                )
              else
                const SizedBox.square(dimension: 48),
            ],
          ),
        ],
      ),
    );
  }
}

/// A round icon button that reads over the camera picture (white on a
/// dark scrim), 48 dp.
class LiveCameraChromeButton extends StatelessWidget {
  const new({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) => IconButton.filled(
    tooltip: tooltip,
    isSelected: selected,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: selected ? Colors.white : Colors.black54,
      foregroundColor: selected ? Colors.black : Colors.white,
      disabledBackgroundColor: Colors.black26,
      disabledForegroundColor: Colors.white38,
      minimumSize: const Size.square(48),
    ),
    icon: Icon(icon),
  );
}

class _FreezeButton extends StatelessWidget {
  const new({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: l10n.liveCameraFreeze,
      hint: l10n.liveCameraFreezeHint,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: l10n.liveCameraFreezeHint,
        child: FilledButton(
          key: const Key('live_camera_freeze'),
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            shape: const CircleBorder(),
            fixedSize: const Size.square(72),
            padding: EdgeInsets.zero,
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            disabledBackgroundColor: Colors.white38,
          ),
          child: const Icon(Icons.pause, size: 32),
        ),
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const new({required this.zoom, required this.onPressed});

  final double zoom;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = l10n.liveCameraZoom(liveCameraZoomLabel(zoom));
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      hint: l10n.liveCameraZoomHint,
      onTap: onPressed,
      excludeSemantics: true,
      child: TextButton(
        key: const Key('live_camera_zoom'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          shape: const CircleBorder(),
          minimumSize: const Size.square(48),
          backgroundColor: Colors.black54,
          foregroundColor: Colors.white,
        ),
        child: Text('${liveCameraZoomLabel(zoom)}×'),
      ),
    );
  }
}
