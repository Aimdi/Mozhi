import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/live_camera/cubit/live_camera_cubit.dart';
import 'package:mozhi/live_camera/widgets/live_overlay.dart';

/// Where content of [content] size is drawn to cover [box] (centred, the
/// overflow cut off), as a camera viewfinder fills the screen.
Rect coverRect(Size content, Size box) {
  if (content.isEmpty || box.isEmpty) return Offset.zero & box;
  final scale = math.max(
    box.width / content.width,
    box.height / content.height,
  );
  final width = content.width * scale;
  final height = content.height * scale;
  return Rect.fromLTWH(
    (box.width - width) / 2,
    (box.height - height) / 2,
    width,
    height,
  );
}

/// The camera preview filling the screen, turned with the display, and
/// the [LiveOverlay] over it in the same place. Pinch to zoom.
class LiveCameraPreview extends StatefulWidget {
  const new({super.key});

  @override
  State<LiveCameraPreview> createState() => _LiveCameraPreviewState();
}

class _LiveCameraPreviewState extends State<LiveCameraPreview> {
  double _pinchStart = 1;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LiveCameraCubit>().state;
    final preview = state.preview;
    final showing =
        preview != null &&
        (state.status == LiveCameraStatus.running ||
            state.status == LiveCameraStatus.freezing);
    if (!showing) {
      return const ColoredBox(
        key: Key('live_camera_no_preview'),
        color: Colors.black,
      );
    }
    final cubit = context.read<LiveCameraCubit>();
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final rect = coverRect(
            preview.sizeOnScreen(state.displayRotation),
            constraints.biggest,
          );
          final turns = (4 - state.displayRotation ~/ 90) % 4;
          return GestureDetector(
            key: const Key('live_camera_preview'),
            behavior: HitTestBehavior.opaque,
            onScaleStart: (_) => _pinchStart = state.zoom,
            onScaleUpdate: (details) {
              if (details.pointerCount < 2) return;
              unawaited(cubit.setZoom(_pinchStart * details.scale));
            },
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: ExcludeSemantics(
                    child: RotatedBox(
                      quarterTurns: turns,
                      child: Texture(textureId: preview.textureId),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: LiveOverlay(
                    blocks: state.blocks,
                    frameSize: state.frameSize,
                    previewRect: rect,
                    target: state.target,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
