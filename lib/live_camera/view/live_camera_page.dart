import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app_lock/view/app_lock_settings_tile.dart'
    show maybeAppLock;
import 'package:mozhi/image_translate/data/text_recognition_service.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart'
    show ocrPreferredLanguages;
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live/live_engine.dart';
import 'package:mozhi/live_camera/cubit/live_camera_cubit.dart';
import 'package:mozhi/live_camera/data/live_camera_controller.dart';
import 'package:mozhi/live_camera/data/method_channel_live_camera_controller.dart';
import 'package:mozhi/live_camera/live_camera_entry.dart' show LiveCameraRoutes;
import 'package:mozhi/live_camera/widgets/live_camera_controls.dart';
import 'package:mozhi/live_camera/widgets/live_camera_messages.dart';
import 'package:mozhi/live_camera/widgets/live_camera_preview.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/platform/mlkit_bindings.dart';
import 'package:mozhi/platform/text_recognition.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// The recognizer that reads camera frames: the app's when it reads raw
/// pixels (Tesseract, the default build), else Tesseract itself (the Play
/// variant's ML Kit reads files only).
TextRecognitionService liveTextRecognizer() {
  final app = createTextRecognitionService();
  return textRecognitionPixelsOf(app) != null
      ? app
      : defaultTextRecognitionService();
}

/// The live camera: point the camera at text and its translation is drawn
/// over the preview, as it reads ([LiveCameraCubit]). Opened from the
/// image screen ([LiveCameraRoutes]); **Freeze** pops the still back to it.
///
/// Needs `TranslationRepository` (RepositoryProvider), `TranslateCubit`
/// (the engines and the languages to start with) and `SettingsCubit` (the
/// live engine) above it; the app lock (`RepositoryProvider<AppLock>`)
/// pauses it while locked when provided. [camera], [recognizer] and
/// [conditions] replace the platform's (tests).
class LiveCameraPage extends StatelessWidget {
  const new({this.camera, this.recognizer, this.conditions, super.key});

  final LiveCameraController? camera;
  final TextRecognitionService? recognizer;
  final DeviceConditions? conditions;

  @override
  Widget build(BuildContext context) {
    // Read here: the create callback must not depend on inherited widgets.
    final locale = Localizations.maybeLocaleOf(context);
    final recognizer = this.recognizer ?? liveTextRecognizer();
    return RepositoryProvider<TextRecognitionService>.value(
      value: recognizer,
      child: BlocProvider(
        create: (context) {
          final settings = context.read<SettingsCubit>().state;
          final translate = context.read<TranslateCubit>().state;
          return LiveCameraCubit(
            camera: camera ?? defaultLiveCameraController(),
            recognizer: recognizer,
            repository: context.read<TranslationRepository>(),
            engine: resolveLiveEngine(settings, translate.engines),
            source: translate.source,
            target: translate.target,
            preferredLanguages: ocrPreferredLanguages(settings, locale),
            lock: maybeAppLock(context),
            conditions: conditions ?? DeviceConditions.instance,
          );
        },
        child: const LiveCameraView(),
      ),
    );
  }
}

class LiveCameraView extends StatefulWidget {
  const new({super.key});

  @override
  State<LiveCameraView> createState() => _LiveCameraViewState();
}

class _LiveCameraViewState extends State<LiveCameraView>
    with WidgetsBindingObserver {
  late final LiveCameraCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = context.read<LiveCameraCubit>();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_cubit.start());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Inactive (a dialog of the system, the notification shade) still
    // shows the app: the camera goes on.
    _cubit.setForeground(
      visible:
          state == AppLifecycleState.resumed ||
          state == AppLifecycleState.inactive,
    );
  }

  @override
  void didChangeMetrics() => unawaited(_cubit.refreshRotation());

  void _syncEngine(BuildContext context) {
    final settings = context.read<SettingsCubit>().state;
    final engines = context.read<TranslateCubit>().state.engines;
    _cubit.setEngine(resolveLiveEngine(settings, engines));
  }

  void _frozen(BuildContext context, LiveCameraState state) {
    final still = state.still;
    final router = GoRouter.maybeOf(context);
    if (router == null) {
      Navigator.of(context).pop(still);
    } else if (router.canPop()) {
      router.pop(still);
    } else {
      closeLiveCamera(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return MultiBlocListener(
      listeners: [
        BlocListener<SettingsCubit, AppSettings>(
          listenWhen: (previous, current) =>
              previous.liveEngineId != current.liveEngineId,
          listener: (context, _) => _syncEngine(context),
        ),
        BlocListener<TranslateCubit, TranslateState>(
          listenWhen: (previous, current) =>
              previous.engines != current.engines,
          listener: (context, _) => _syncEngine(context),
        ),
        BlocListener<LiveCameraCubit, LiveCameraState>(
          listenWhen: (previous, current) =>
              current.status == LiveCameraStatus.frozen &&
              current.still != null &&
              previous.still != current.still,
          listener: _frozen,
        ),
        BlocListener<LiveCameraCubit, LiveCameraState>(
          listenWhen: (previous, current) =>
              current.freezeFailures > previous.freezeFailures,
          listener: (context, _) => ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(content: Text(l10n.liveCameraFreezeFailed)),
            ),
        ),
      ],
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        // Light status bar icons over the camera picture.
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          key: const Key('live_camera_view'),
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              const LiveCameraPreview(),
              SafeArea(
                child: Column(
                  children: [
                    // The screen's name for screen readers (the camera
                    // picture needs all the room there is).
                    Semantics(
                      header: true,
                      label: l10n.liveCameraTitle,
                      child: const SizedBox(width: double.infinity),
                    ),
                    const LiveCameraTopBar(),
                    const Expanded(child: LiveCameraMessages()),
                    const LiveCameraBottomBar(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
