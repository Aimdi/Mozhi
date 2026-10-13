import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/data/data.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/widgets/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:translation_repository/translation_repository.dart';

/// Image translation (Kagi-style context-aware image translation and a
/// Google Lens-lite via Mozhi).
///
/// Needs `TranslationRepository` (RepositoryProvider), `TranslateCubit` and
/// `SettingsCubit` above it. The platform services default to the plugin
/// implementations and can be injected (tests, other platforms).
class ImageTranslatePage extends StatelessWidget {
  const new({
    this.initialSource,
    this.picker,
    this.encoder,
    this.recognizer,
    super.key,
  });

  /// Route path below `/translate`.
  static const path = 'image';

  /// Full location of the page.
  static const location = '/translate/$path';

  /// Query parameter that opens the picker on arrival (`gallery`/`camera`).
  static const sourceParameter = 'source';

  /// [location], optionally opening the picker for [source] on arrival.
  static String locationFor({ImagePickSource? source}) => source == null
      ? location
      : Uri(
          path: location,
          queryParameters: {sourceParameter: source.name},
        ).toString();

  /// A route for [path], to be nested under the `/translate` route.
  static GoRoute route({GlobalKey<NavigatorState>? parentNavigatorKey}) =>
      GoRoute(
        path: path,
        parentNavigatorKey: parentNavigatorKey,
        builder: (context, state) => ImageTranslatePage(
          initialSource: ImagePickSource.tryParse(
            state.uri.queryParameters[sourceParameter],
          ),
        ),
      );

  /// Opens the picker for this source once the page is shown.
  final ImagePickSource? initialSource;
  final ImagePickerService? picker;
  final ImageEncoder? encoder;
  final TextRecognitionService? recognizer;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final translate = context.read<TranslateCubit>().state;
        final settings = context.read<SettingsCubit>().state;
        return ImageTranslateCubit(
          repository: context.read<TranslationRepository>(),
          picker: picker ?? PluginImagePickerService(),
          encoder: encoder ?? const UiImageEncoder(),
          recognizer: recognizer ?? MlKitTextRecognitionService(),
          engines: translate.engines,
          providers: settings.providers,
          translateEngine: translate.engine,
          source: translate.source,
          target: translate.target,
          options: translate.options,
        );
      },
      child: ImageTranslateView(initialSource: initialSource),
    );
  }
}

class ImageTranslateView extends StatefulWidget {
  const new({this.initialSource, super.key});

  /// Width from which image and results are shown side by side.
  static const wideBreakpoint = 840.0;

  final ImagePickSource? initialSource;

  @override
  State<ImageTranslateView> createState() => _ImageTranslateViewState();
}

class _ImageTranslateViewState extends State<ImageTranslateView> {
  @override
  void initState() {
    super.initState();
    final source = widget.initialSource;
    if (source != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(context.read<ImageTranslateCubit>().pickImage(source));
        }
      });
    }
  }

  void _syncContext(BuildContext context) {
    final translate = context.read<TranslateCubit>().state;
    context.read<ImageTranslateCubit>().updateContext(
      engines: translate.engines,
      providers: context.read<SettingsCubit>().state.providers,
      translateEngine: translate.engine,
      options: translate.options,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (hasImage, canUseCamera, canPick) = context
        .select<ImageTranslateCubit, (bool, bool, bool)>(
          (cubit) => (
            cubit.state.hasImage,
            cubit.state.canUseCamera,
            cubit.state.methods.isNotEmpty,
          ),
        );
    final cubit = context.read<ImageTranslateCubit>();

    return MultiBlocListener(
      listeners: [
        BlocListener<TranslateCubit, TranslateState>(
          listenWhen: (previous, current) =>
              previous.engines != current.engines ||
              previous.engine != current.engine ||
              previous.options != current.options,
          listener: (context, _) => _syncContext(context),
        ),
        BlocListener<SettingsCubit, AppSettings>(
          listenWhen: (previous, current) =>
              previous.providers != current.providers,
          listener: (context, _) => _syncContext(context),
        ),
        BlocListener<ImageTranslateCubit, ImageTranslateState>(
          listenWhen: (previous, current) =>
              current.pickError != null &&
              previous.pickError != current.pickError,
          listener: (context, state) {
            final info = describeImageTranslateError(l10n, state.pickError);
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(info.message)));
          },
        ),
      ],
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.imageTranslateTitle),
          actions: [
            if (hasImage) ...[
              IconButton(
                key: const Key('image_translate_appbar_gallery'),
                tooltip: l10n.imageTranslatePickGallery,
                onPressed: canPick
                    ? () => unawaited(cubit.pickImage(ImagePickSource.gallery))
                    : null,
                icon: const Icon(Icons.photo_library_outlined),
              ),
              if (canUseCamera)
                IconButton(
                  key: const Key('image_translate_appbar_camera'),
                  tooltip: l10n.imageTranslateTakePhoto,
                  onPressed: canPick
                      ? () => unawaited(cubit.pickImage(ImagePickSource.camera))
                      : null,
                  icon: const Icon(Icons.photo_camera_outlined),
                ),
              IconButton(
                key: const Key('image_translate_appbar_clear'),
                tooltip: l10n.imageTranslateRemoveImage,
                onPressed: cubit.clearImage,
                icon: const Icon(Icons.close),
              ),
            ],
          ],
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) =>
                constraints.maxWidth >= ImageTranslateView.wideBreakpoint
                ? _WideLayout(hasImage: hasImage)
                : _NarrowLayout(hasImage: hasImage),
          ),
        ),
      ),
    );
  }
}

/// Language bar and method selector.
class _Controls extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ImageLanguageBar(),
        SizedBox(height: 16),
        ImageMethodSelector(),
      ],
    );
  }
}

/// "Translate" button, error, or results, depending on the status.
class _Status extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<ImageTranslateCubit>().state;
    final cubit = context.read<ImageTranslateCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.status == ImageTranslateStatus.ready) ...[
          Center(
            child: FilledButton.icon(
              key: const Key('image_translate_translate_button'),
              onPressed: state.canTranslate
                  ? () => unawaited(cubit.translate())
                  : null,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              icon: const Icon(Icons.translate),
              label: Text(l10n.imageTranslateTranslateAction),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (state.status == ImageTranslateStatus.failure) ...[
          ImageTranslateErrorView(
            error: state.error,
            onRetry: state.canTranslate
                ? () => unawaited(cubit.translate())
                : null,
          ),
          const SizedBox(height: 16),
        ],
        const ImageTranslateResultSection(),
      ],
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  const new({required this.hasImage});

  final bool hasImage;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const Key('image_translate_narrow'),
          padding: const EdgeInsets.all(16),
          children: [
            const _Controls(),
            const SizedBox(height: 16),
            if (!hasImage)
              const ImageTranslateEmptyState()
            else ...[
              ImageTranslatePreview(height: (height * 0.45).clamp(240, 480)),
              const SizedBox(height: 16),
              const _Status(),
            ],
          ],
        ),
      ),
    );
  }
}

class _WideLayout extends StatelessWidget {
  const new({required this.hasImage});

  final bool hasImage;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('image_translate_wide'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: hasImage
                ? const ImageTranslatePreview(expand: true)
                : Center(
                    child: SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: const ImageTranslateEmptyState(),
                      ),
                    ),
                  ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 2,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _Controls(),
              if (hasImage) ...[const SizedBox(height: 16), const _Status()],
            ],
          ),
        ),
      ],
    );
  }
}
