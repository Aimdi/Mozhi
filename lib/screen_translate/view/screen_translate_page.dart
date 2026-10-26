import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/app_lock/data/app_lock.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/image_translate/cubit/image_translate_cubit.dart';
import 'package:mozhi/image_translate/data/data.dart';
import 'package:mozhi/image_translate/models/models.dart';
import 'package:mozhi/image_translate/view/image_translate_page.dart'
    show ocrPreferredLanguages;
import 'package:mozhi/image_translate/widgets/widgets.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/mlkit_bindings.dart';
import 'package:mozhi/screen_translate/cubit/screen_translate_cubit.dart';
import 'package:mozhi/screen_translate/data/screenshot_picker.dart';
import 'package:mozhi/screen_translate/screen_translate_host.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/translate_error.dart'
    show TranslateErrorFix, offlineModelsRoute;
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:translation_repository/translation_repository.dart';

/// The only page of the screen-translate window ([ScreenTranslateHost]):
/// nothing at all while the screenshot is taken (the window is in it),
/// then the screenshot full screen with its translation drawn over it.
///
/// Needs `TranslationRepository`, `TranslateCubit` and `SettingsCubit`
/// above it (the app provides them in every window); an `AppLock` above it
/// (optional) is asked to unlock before anything is shown, a
/// `UsageTracker` (optional) counts AI requests. [host], [lock],
/// [recognizer] and [encoder] replace the app's (tests).
class ScreenTranslatePage extends StatelessWidget {
  const new({this.host, this.lock, this.recognizer, this.encoder, super.key});

  final ScreenTranslateHost? host;
  final AppLock? lock;
  final TextRecognitionService? recognizer;
  final ImageEncoder? encoder;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final cubit = ScreenTranslateCubit(
          host: host ?? ScreenTranslateHost.instance,
          lock: lock ?? _maybeRead<AppLock>(context),
        );
        unawaited(cubit.start());
        return cubit;
      },
      child: ScreenTranslateView(recognizer: recognizer, encoder: encoder),
    );
  }
}

class ScreenTranslateView extends StatelessWidget {
  const new({this.recognizer, this.encoder, super.key});

  final TextRecognitionService? recognizer;
  final ImageEncoder? encoder;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<ScreenTranslateCubit>().state;
    final cubit = context.read<ScreenTranslateCubit>();
    final screenshot = state.screenshot;
    final body = switch (state.status) {
      // Drawn into the screenshot otherwise: nothing at all.
      ScreenTranslateStatus.capturing ||
      ScreenTranslateStatus.unlocking => Semantics(
        key: const Key('screen_translate_invisible'),
        label: l10n.screenTranslateTitle,
        child: const SizedBox.expand(),
      ),
      ScreenTranslateStatus.locked => _MessageView(
        key: const Key('screen_translate_locked'),
        icon: Icons.lock_outline,
        title: l10n.screenTranslateLockedTitle,
        message: l10n.screenTranslateLockedBody,
        action: FilledButton.icon(
          key: const Key('screen_translate_unlock'),
          onPressed: () => unawaited(cubit.unlock()),
          icon: const Icon(Icons.lock_open),
          label: Text(l10n.screenTranslateUnlock),
        ),
      ),
      ScreenTranslateStatus.blank => _MessageView(
        key: const Key('screen_translate_blank'),
        icon: Icons.hide_image_outlined,
        message: l10n.screenTranslateBlank,
      ),
      ScreenTranslateStatus.failed => _MessageView(
        key: const Key('screen_translate_failed'),
        icon: Icons.error_outline,
        message: l10n.screenTranslateFailed,
      ),
      ScreenTranslateStatus.ready when screenshot != null =>
        ScreenshotTranslation(
          image: screenshot,
          recognizer: recognizer,
          encoder: encoder,
        ),
      ScreenTranslateStatus.ready => const SizedBox.expand(),
    };
    // Back closes the window: the app below is back.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(cubit.closeWindow());
      },
      child: body,
    );
  }
}

/// A message above the app on the screen (a light scrim) with Close and an
/// optional [action].
class _MessageView extends StatelessWidget {
  const new({
    required this.icon,
    required this.message,
    this.title,
    this.action,
    super.key,
  });

  final IconData icon;
  final String? title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<ScreenTranslateCubit>();
    return Material(
      color: theme.colorScheme.scrim.withValues(alpha: 0.32),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(icon, size: 32, color: theme.colorScheme.primary),
                      const SizedBox(height: 16),
                      if (title case final title?) ...[
                        Semantics(
                          header: true,
                          child: Text(
                            title,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          message,
                          key: const Key('screen_translate_message'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          TextButton(
                            key: const Key('screen_translate_close'),
                            onPressed: () => unawaited(cubit.closeWindow()),
                            child: Text(l10n.commonClose),
                          ),
                          ?action,
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The screenshot full screen, read on the device and translated with the
/// translator's engine (and privacy settings), the translation drawn over
/// it ([TranslatedImageOverlay]); the language bar above, the actions
/// below.
///
/// It reuses the image translation ([ImageTranslateCubit]) with on-device
/// text recognition only: the screenshot itself never leaves the device
/// (no AI vision, no upload), only its recognised text goes to the engine
/// the user chose, as on the image screen.
class ScreenshotTranslation extends StatelessWidget {
  const new({required this.image, this.recognizer, this.encoder, super.key});

  final PickedImage image;
  final TextRecognitionService? recognizer;
  final ImageEncoder? encoder;

  @override
  Widget build(BuildContext context) {
    // Read here: the create callback must not depend on inherited widgets.
    final locale = Localizations.maybeLocaleOf(context);
    final recognizer = this.recognizer ?? createTextRecognitionService();
    return RepositoryProvider<TextRecognitionService>.value(
      value: recognizer,
      child: BlocProvider(
        create: (context) {
          final translate = context.read<TranslateCubit>().state;
          final settings = context.read<SettingsCubit>().state;
          final cubit = ImageTranslateCubit(
            repository: context.read<TranslationRepository>(),
            picker: const ScreenshotPicker(),
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
          );
          // Waits for the on-device method (see the view).
          unawaited(cubit.setImage(image, autoTranslate: false));
          return cubit;
        },
        child: const ScreenshotTranslationView(),
      ),
    );
  }
}

class ScreenshotTranslationView extends StatefulWidget {
  const new({super.key});

  @override
  State<ScreenshotTranslationView> createState() =>
      _ScreenshotTranslationViewState();
}

class _ScreenshotTranslationViewState extends State<ScreenshotTranslationView> {
  /// Whether the translation was started (once; Retry starts it again).
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeTranslate();
    });
  }

  void _syncContext() {
    final translate = context.read<TranslateCubit>().state;
    context.read<ImageTranslateCubit>().updateContext(
      engines: translate.engines,
      providers: context.read<SettingsCubit>().state.providers,
      translateEngine: translate.engine,
      options: translate.options,
    );
    _maybeTranslate();
  }

  /// Translates with on-device recognition as soon as it is available
  /// (the translator's engines may still be loading in this window).
  void _maybeTranslate() {
    if (_started) return;
    final cubit = context.read<ImageTranslateCubit>();
    final state = cubit.state;
    // A new screenshot, or Retry after a failure or Cancel.
    if (!state.hasImage || state.isWorking) return;
    final onDevice = state.onDeviceMethod;
    if (onDevice == null) {
      if (_enginesSettled(context)) setState(() {});
      return;
    }
    _started = true;
    if (state.method == onDevice) {
      unawaited(cubit.translate());
    } else {
      unawaited(cubit.useOnDevice());
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ImageTranslateCubit>().state;
    final unavailable =
        !_started && state.onDeviceMethod == null && _enginesSettled(context);
    return MultiBlocListener(
      listeners: [
        BlocListener<TranslateCubit, TranslateState>(
          listenWhen: (previous, current) =>
              previous.engines != current.engines ||
              previous.engine != current.engine ||
              previous.options != current.options ||
              previous.enginesStatus != current.enginesStatus,
          listener: (context, _) => _syncContext(),
        ),
        BlocListener<SettingsCubit, AppSettings>(
          listenWhen: (previous, current) =>
              previous.providers != current.providers,
          listener: (context, _) => _syncContext(),
        ),
      ],
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _Screenshot(state: state),
            if (state.isWorking)
              const Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(16),
                  child: ImageTranslateProgress(),
                ),
              ),
            const Positioned(top: 0, left: 0, right: 0, child: _TopBar()),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _BottomPanel(
                state: state,
                unavailable: unavailable,
                onRetry: () {
                  _started = false;
                  _maybeTranslate();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Whether the translator's engines finished loading (successfully or
/// not): only then can on-device recognition be said to be unavailable.
bool _enginesSettled(BuildContext context) =>
    switch (context.read<TranslateCubit>().state.enginesStatus) {
      EnginesStatus.ready || EnginesStatus.failure => true,
      _ => false,
    };

/// The screenshot, zoomable, with the translation over it once there is
/// one.
class _Screenshot extends StatelessWidget {
  const new({required this.state});

  final ImageTranslateState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final image = state.image;
    if (image == null) return const SizedBox.expand();
    final result = state.result;
    final overlay = state.showsOverlay ? result : null;
    return InteractiveViewer(
      key: const Key('screen_translate_viewer'),
      maxScale: 6,
      child: Center(
        child: overlay != null
            ? TranslatedImageOverlay(
                key: const Key('screen_translate_overlay'),
                image: image.bytes,
                layout: overlay.layout!,
                translations: overlay.translatedParagraphs,
                source: _sourceOf(state),
                target: state.target,
                showOriginal: state.showOriginal,
              )
            : Image.memory(
                image.bytes,
                key: const Key('screen_translate_screenshot'),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                semanticLabel: l10n.screenTranslateScreenshotLabel,
              ),
      ),
    );
  }
}

/// Close and the languages, at the top.
class _TopBar extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Material(
              color: theme.colorScheme.surfaceContainerHigh,
              elevation: 3,
              borderRadius: BorderRadius.circular(28),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 12, 4),
                child: Row(
                  children: [
                    IconButton(
                      key: const Key('screen_translate_close_button'),
                      tooltip: l10n.commonClose,
                      onPressed: () => unawaited(
                        context.read<ScreenTranslateCubit>().closeWindow(),
                      ),
                      icon: const Icon(Icons.close),
                    ),
                    const SizedBox(width: 4),
                    const Expanded(child: ImageLanguageBar()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What comes next, at the bottom: the actions on a translation, what
/// went wrong, or why the screen can't be read here.
class _BottomPanel extends StatelessWidget {
  const new({
    required this.state,
    required this.unavailable,
    required this.onRetry,
  });

  final ImageTranslateState state;
  final bool unavailable;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final Widget? content;
    if (unavailable) {
      content = _Notice(message: context.l10n.screenTranslateUnavailable);
    } else if (state.status == ImageTranslateStatus.failure) {
      content = _TranslationError(state: state, onRetry: onRetry);
    } else if (state.isWorking) {
      content = null;
    } else if (state.result case final result?
        when result.translatedText.isNotEmpty) {
      content = _Actions(state: state, result: result);
    } else if (state.status == ImageTranslateStatus.ready && state.hasImage) {
      // Cancelled: translate again or close.
      content = _Notice(
        action: FilledButton.icon(
          key: const Key('screen_translate_retry'),
          onPressed: onRetry,
          icon: const Icon(Icons.translate),
          label: Text(context.l10n.screenTranslateTitle),
        ),
      );
    } else {
      content = null;
    }
    if (content == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.5;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 640, maxHeight: maxHeight),
            child: Material(
              key: const Key('screen_translate_panel'),
              color: theme.colorScheme.surfaceContainerHigh,
              elevation: 3,
              borderRadius: BorderRadius.circular(AppRadius.card),
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A message (optional) with Close and an optional [action].
class _Notice extends StatelessWidget {
  const new({this.message, this.action});

  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (message case final message?)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                key: const Key('screen_translate_notice'),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              key: const Key('screen_translate_notice_close'),
              onPressed: () =>
                  unawaited(context.read<ScreenTranslateCubit>().closeWindow()),
              child: Text(l10n.commonClose),
            ),
            ?action,
          ],
        ),
      ],
    );
  }
}

/// The actions on a translation: hold to see the original, the texts,
/// copy, and "Open in Mozhi" (the recognised text in the translate tab).
class _Actions extends StatelessWidget {
  const new({required this.state, required this.result});

  final ImageTranslateState state;
  final ImageTranslation result;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<ImageTranslateCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.hasLowRecognitionConfidence)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('screen_translate_choose_source'),
              onPressed: () =>
                  unawaited(pickImageLanguage(context, source: true)),
              icon: const Icon(Icons.help_outline),
              label: Text(l10n.imageTranslateChooseSourceLanguage),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (state.showsOverlay)
              HoldToShowOriginalButton(
                key: const Key('screen_translate_hold_original'),
                showing: state.showOriginal,
                onChanged: (showing) =>
                    cubit.setShowOriginal(showOriginal: showing),
              ),
            OutlinedButton.icon(
              key: const Key('screen_translate_show_text'),
              onPressed: () => unawaited(
                showOverlayParagraph(
                  context,
                  original: result.sourceText,
                  translation: result.translatedText,
                  source: _sourceOf(state),
                  target: state.target,
                ),
              ),
              style: _buttonStyle,
              icon: const Icon(Icons.notes),
              label: Text(l10n.screenTranslateShowText),
            ),
            IconButton(
              key: const Key('screen_translate_copy'),
              tooltip: l10n.screenTranslateCopyTranslation,
              onPressed: () => unawaited(
                copyImageTranslation(context, result.translatedText),
              ),
              icon: const Icon(Icons.copy_outlined),
            ),
            if (result.sourceText.isNotEmpty)
              FilledButton.icon(
                key: const Key('screen_translate_open_in_app'),
                onPressed: () => unawaited(
                  context.read<ScreenTranslateCubit>().openInApp(
                    result.sourceText,
                  ),
                ),
                style: _buttonStyle,
                icon: const Icon(Icons.open_in_new),
                label: Text(l10n.screenTranslateOpenInApp),
              ),
          ],
        ),
      ],
    );
  }

  static final _buttonStyle = ButtonStyle(
    minimumSize: WidgetStateProperty.all(const Size(48, 48)),
  );
}

/// Why the translation failed, and what helps: the consent prompt when the
/// privacy settings stopped it, the offer to download missing text
/// recognition data, else the message with Retry, "Choose the language of
/// the text" or "Open Mozhi" (fixes such as the offline languages open in
/// the main window).
class _TranslationError extends StatelessWidget {
  const new({required this.state, required this.onRetry});

  final ImageTranslateState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final error = state.error;
    if (error is ConsentRequiredException) {
      return ConsentInlinePrompt(
        key: const Key('screen_translate_consent'),
        consent: error,
        onGranted: onRetry,
      );
    }
    final data = _textRecognitionData(context);
    if (error is OcrDataMissingException && data != null) {
      return OcrLanguageOffer(
        key: ValueKey(error),
        missing: error,
        data: data,
        onInstalled: onRetry,
      );
    }
    final l10n = context.l10n;
    final info = describeImageTranslateError(
      l10n,
      error,
      method: ImageTranslateMethodKind.onDevice,
    );
    final fix = switch (info.fix) {
      _ when info.offlineModels => offlineModelsRoute,
      TranslateErrorFix.instances => ImageTranslateLinks.instances,
      TranslateErrorFix.providers => ImageTranslateLinks.providers,
      TranslateErrorFix.none => null,
    };
    final cubit = context.read<ScreenTranslateCubit>();
    return _Notice(
      message: info.message,
      action: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (info.chooseSourceLanguage)
            FilledButton.icon(
              key: const Key('screen_translate_error_choose_source'),
              onPressed: () =>
                  unawaited(pickImageLanguage(context, source: true)),
              icon: const Icon(Icons.translate),
              label: Text(l10n.imageTranslateChooseSourceLanguage),
            )
          else
            FilledButton.icon(
              key: const Key('screen_translate_error_retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRetry),
            ),
          if (fix != null)
            TextButton(
              key: const Key('screen_translate_error_fix'),
              onPressed: () => unawaited(cubit.openLocation(fix)),
              child: Text(l10n.screenTranslateOpenMozhi),
            ),
        ],
      ),
    );
  }
}

/// The language of the text on the screen: the chosen source, else the
/// one the translator detected.
Language _sourceOf(ImageTranslateState state) {
  if (!state.source.isAuto) return state.source;
  final detected = state.result?.detectedSource;
  if (detected == null || detected.isEmpty) return state.source;
  return LanguageCatalog.byCode(detected) ??
      Language(code: detected, name: detected);
}

/// The recognizer's downloadable language data ([ScreenshotTranslation]
/// provides the recognizer), if it has any.
TextRecognitionLanguageData? _textRecognitionData(BuildContext context) =>
    textRecognitionLanguageDataOf(context.read<TextRecognitionService>());

/// The app's [T] (app lock, usage tracker), or null when none is provided.
T? _maybeRead<T>(BuildContext context) {
  try {
    return context.read<T>();
  } on ProviderNotFoundException {
    return null;
  }
}
