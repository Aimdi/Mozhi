import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/data/data.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/widgets/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live_camera/live_camera_entry.dart';
import 'package:mozhi/platform/mlkit_bindings.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

/// Image translation: on-device text recognition (recommended), Kagi-style
/// context-aware translation by AI vision models, and (experimental) Mozhi
/// passing the photo on to Google Translate.
///
/// Needs `TranslationRepository` (RepositoryProvider), `TranslateCubit` and
/// `SettingsCubit` above it; a `UsageTracker` above it (optional) counts AI
/// requests and a `KeyValueStore` (optional) remembers the chosen method.
/// The platform services default to the plugin implementations and can be
/// injected (tests, other platforms).
///
/// A photo recovered after Android ended the app while the camera was open
/// ([LostImageRecovery], or the picker's own lost data) is shown right
/// away.
class ImageTranslatePage extends StatelessWidget {
  const new({
    this.initialSource,
    this.picker,
    this.encoder,
    this.recognizer,
    this.autoTranslate = true,
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

  /// Whether an image the page starts with (from [picker]'s
  /// `retrieveLost`, e.g. one shared from another app) is translated right
  /// away with on-device recognition; false shows it and waits for
  /// Translate (`ImageTranslateCubit.setImage`).
  final bool autoTranslate;
  final ImagePickerService? picker;
  final ImageEncoder? encoder;
  final TextRecognitionService? recognizer;

  @override
  Widget build(BuildContext context) {
    // Read here: the create callback must not depend on inherited widgets.
    final locale = Localizations.maybeLocaleOf(context);
    final recognizer = this.recognizer ?? createTextRecognitionService();
    // Provided for the view's offer to download missing language data.
    return RepositoryProvider<TextRecognitionService>.value(
      value: recognizer,
      child: BlocProvider(
        create: (context) {
          final translate = context.read<TranslateCubit>().state;
          final settings = context.read<SettingsCubit>().state;
          return ImageTranslateCubit(
            repository: context.read<TranslationRepository>(),
            picker: picker ?? PluginImagePickerService(),
            encoder: encoder ?? const UiImageEncoder(),
            recognizer: recognizer,
            engines: translate.engines,
            providers: settings.providers,
            translateEngine: translate.engine,
            source: translate.source,
            target: translate.target,
            options: translate.options,
            usageTracker: _maybeRead<UsageTracker>(context),
            preferredLanguages: ocrPreferredLanguages(settings, locale),
            store: _maybeRead<KeyValueStore>(context),
          );
        },
        child: ImageTranslateView(
          initialSource: initialSource,
          autoTranslate: autoTranslate,
        ),
      ),
    );
  }
}

class ImageTranslateView extends StatefulWidget {
  const new({this.initialSource, this.autoTranslate = true, super.key});

  /// Width from which image and results are shown side by side.
  static const wideBreakpoint = 840.0;

  final ImagePickSource? initialSource;

  /// See [ImageTranslatePage.autoTranslate].
  final bool autoTranslate;

  @override
  State<ImageTranslateView> createState() => _ImageTranslateViewState();
}

class _ImageTranslateViewState extends State<ImageTranslateView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start(context.read<ImageTranslateCubit>()));
    });
  }

  /// Continues with a recovered photo, else opens the requested picker,
  /// else asks the picker for a photo Android could not deliver.
  Future<void> _start(ImageTranslateCubit cubit) async {
    final recovered = LostImageRecovery.take();
    if (recovered != null) {
      // With the remembered method: an uploading one waits for Translate.
      await cubit.methodRestored;
      if (!cubit.isClosed) await cubit.setImage(recovered);
      return;
    }
    final source = widget.initialSource;
    if (source != null) {
      await cubit.pickImage(source);
    } else {
      await cubit.recoverLostImage(autoTranslate: widget.autoTranslate);
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
              // Live camera (W7-A): the Android app only.
              if (liveCameraOffered)
                IconButton(
                  key: const Key('image_translate_appbar_live_camera'),
                  tooltip: l10n.liveCameraOpen,
                  onPressed: () => unawaited(openLiveCamera(context)),
                  icon: const Icon(Icons.center_focus_weak),
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
    final column = Column(
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
              icon: const Icon(Icons.translate),
              label: Text(l10n.imageTranslateTranslateAction),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (state.status == ImageTranslateStatus.failure) ...[
          ImageTranslateErrorView(
            error: state.error,
            method: state.method?.kind,
            onRetry: state.canTranslate
                ? () => unawaited(cubit.translate())
                : null,
            onUseOnDevice: state.offersOnDevice
                ? () => unawaited(cubit.useOnDevice())
                : null,
            onChooseSourceLanguage: () =>
                unawaited(pickImageLanguage(context, source: true)),
            textRecognitionData: _textRecognitionData(context),
          ),
          const SizedBox(height: 16),
        ],
        const ImageTranslateResultSection(),
      ],
    );
    // Translating is the user's own action here: when the privacy settings
    // stop it, ask right away, and translate once allowed.
    return ConsentDialogListener<ImageTranslateCubit, ImageTranslateState>(
      consentOf: (state) => state.status == ImageTranslateStatus.failure
          ? switch (state.error) {
              final ConsentRequiredException consent => consent,
              _ => null,
            }
          : null,
      onGranted: (context) =>
          unawaited(context.read<ImageTranslateCubit>().translate()),
      child: column,
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
        const Hairline(vertical: true),
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

/// The app language codes on-device text recognition prefers for "Detect
/// language" (see `planTextRecognition`), best first: the sources of the
/// recent language pairs, the recent languages, then the app's [locale].
List<String> ocrPreferredLanguages(AppSettings settings, Locale? locale) {
  final codes = <String>[];
  void add(Language language) {
    if (language.isAuto || language.isCustom) return;
    if (!codes.contains(language.code)) codes.add(language.code);
  }

  for (final pair in settings.recentPairs) {
    add(pair.source);
  }
  settings.recentLanguages.forEach(add);
  if (locale != null) add(Language(code: locale.languageCode, name: ''));
  return List.unmodifiable(codes);
}

/// The language data of the recognizer provided by [ImageTranslatePage],
/// if it downloads data per language (none with ML Kit or in tests that
/// pump the view alone).
TextRecognitionLanguageData? _textRecognitionData(BuildContext context) {
  try {
    return textRecognitionLanguageDataOf(
      context.read<TextRecognitionService>(),
    );
  } on ProviderNotFoundException {
    return null;
  }
}

/// The app's [T] (usage tracker, preferences), or null when none is
/// provided (e.g. in tests).
T? _maybeRead<T>(BuildContext context) {
  try {
    return context.read<T>();
  } on ProviderNotFoundException {
    return null;
  }
}
