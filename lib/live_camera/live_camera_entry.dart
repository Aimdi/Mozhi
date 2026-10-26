import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/models/picked_image.dart';
import 'package:mozhi/platform/android_device.dart';

/// Where the live camera lives: a full-screen page above the image
/// screen, opened only from it (see [openLiveCamera]).
abstract final class LiveCameraRoutes {
  static const location = '/image/live';
}

/// The navigation's `extra` that opens the live camera. Without it (a link
/// from outside the app, `mozhi://image/live`) the router shows the image
/// screen instead: a link never turns the camera on by itself.
enum LiveCameraLaunch { open }

/// Whether the image screen offers the live camera: in the Android app
/// only ([runsOnAndroid]; never on the web).
bool get liveCameraOffered => debugLiveCameraOffered ?? runsOnAndroid;

/// Replaces [liveCameraOffered] in tests.
@visibleForTesting
bool? debugLiveCameraOffered;

/// Opens the live camera from the image screen; a still it froze is shown
/// (and read on the device) by the [ImageTranslateCubit] above [context].
Future<void> openLiveCamera(BuildContext context) async {
  final cubit = context.read<ImageTranslateCubit>();
  final still = await context.push<PickedImage>(
    LiveCameraRoutes.location,
    extra: LiveCameraLaunch.open,
  );
  if (still == null || cubit.isClosed) return;
  await cubit.setImage(still);
}
