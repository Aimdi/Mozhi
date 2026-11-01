import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/composer_card.dart' show ComposerEngineChip;
import 'package:mozhi/core/widgets/on_device_ai_setup_button.dart'
    show offersOnDeviceAiSetup;
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/proofread/widgets/proofread_labels.dart';
import 'package:mozhi/quick_improve/cubit/quick_improve_cubit.dart';
import 'package:mozhi/quick_improve/models/improve_engines.dart';
import 'package:mozhi/quick_improve/widgets/widgets.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';
import 'package:mozhi/quick_translate/widgets/quick_source_card.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

/// Shows the quick improve UI for [text] selected in another app ("Improve
/// with Mozhi", Android `PROCESS_TEXT`): a modal bottom sheet on phones, a
/// dialog on wider windows (≥ 600 dp), like `showQuickTranslate`.
///
/// Reads [TranslationRepository], [TranslateCubit] (the engines of the
/// Proofread tab) and [SettingsCubit] (consents given in the sheet), all
/// required, and [UsageTracker] (optional) from [context].
///
/// [onReplace] receives the improved text when the user taps Replace,
/// which only appears with it (a writable `PROCESS_TEXT` request).
/// [onOpenInProofread] shows an "Open in Proofread" button. The sheet
/// closes itself before either callback runs. Completes when the sheet is
/// closed. Blank [text] shows nothing.
///
/// Without an AI engine the sheet offers the AI provider settings
/// ([AppRoutes.providers]) and, where a model fits the phone, the
/// on-device AI settings ([AppRoutes.onDeviceAi]): in the translucent
/// quick translate window ([host], default [QuickTranslateHost.instance],
/// when it [QuickTranslateHost.isActive]) they open in the main window,
/// else with the [GoRouter] above [context], if any. In that window,
/// closing the sheet closes the window.
Future<void> showQuickImprove(
  BuildContext context, {
  required String text,
  ValueChanged<String>? onReplace,
  VoidCallback? onOpenInProofread,
  QuickTranslateHost? host,
}) async {
  if (text.trim().isEmpty) return;
  final window = host ?? QuickTranslateHost.instance;
  final inWindow = window.isActive;
  final repository = context.read<TranslationRepository>();
  final translate = context.read<TranslateCubit>();
  final settings = context.read<SettingsCubit>();
  final usage = _maybeRead<UsageTracker>(context);
  final router = GoRouter.maybeOf(context);
  final onDevice = offersOnDeviceAiSetup(context);
  final wide = MediaQuery.sizeOf(context).width >= 600;

  ValueChanged<String>? openSettings;
  if (inWindow) {
    openSettings = (location) => unawaited(window.openLocationInApp(location));
  } else if (router != null) {
    openSettings = (location) => unawaited(router.push<void>(location));
  }

  Widget content(BuildContext routeContext, {required bool dialog}) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<TranslationRepository>.value(value: repository),
        if (usage != null) RepositoryProvider<UsageTracker>.value(value: usage),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<TranslateCubit>.value(value: translate),
          BlocProvider<SettingsCubit>.value(value: settings),
        ],
        child: QuickImproveSheet(
          text: text,
          onReplace: onReplace,
          onOpenInProofread: onOpenInProofread,
          onOpenSettings: openSettings,
          offerOnDeviceAi: onDevice,
          onClose: () => Navigator.of(routeContext).pop(),
          padding: dialog
              ? const EdgeInsets.fromLTRB(16, 12, 16, 16)
              // The sheet's safe area leaves out the bottom: keep the
              // actions above the navigation bar (edge to edge).
              : EdgeInsets.fromLTRB(
                  16,
                  0,
                  16,
                  16 + MediaQuery.paddingOf(routeContext).bottom,
                ),
        ),
      ),
    );
  }

  if (wide) {
    await showDialog<void>(
      context: context,
      builder: (routeContext) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: content(routeContext, dialog: true),
        ),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (routeContext) => content(routeContext, dialog: false),
    );
  }
  // The window shows nothing else.
  if (inWindow) await window.close();
}

T? _maybeRead<T>(BuildContext context) {
  try {
    return context.read<T>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// English name of the UI language of [locale], for the edits'
/// explanations (as the Proofread tab sends it).
String quickImproveUiLanguage(Locale locale) {
  if (locale.languageCode == 'en') return 'English';
  return LanguageCatalog.byCode(locale.languageCode)?.name ?? 'English';
}

/// Quick improve content (for a bottom sheet or dialog): creates a
/// [QuickImproveCubit] for [text] with the engines of the [TranslateCubit]
/// in context (followed while the sheet is open), the
/// [TranslationRepository] and the optional [UsageTracker], starts
/// proofreading right away and shows [QuickImproveView].
class QuickImproveSheet extends StatelessWidget {
  const new({
    required this.text,
    this.onReplace,
    this.onOpenInProofread,
    this.onOpenSettings,
    this.offerOnDeviceAi = false,
    this.onClose,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
    super.key,
  });

  final String text;
  final ValueChanged<String>? onReplace;
  final VoidCallback? onOpenInProofread;

  /// Opens a settings location (the AI providers, on-device AI); no
  /// buttons without it.
  final ValueChanged<String>? onOpenSettings;

  /// Whether to offer setting up on-device AI when no engine can proofread.
  final bool offerOnDeviceAi;

  /// Closes the UI (default: pops the current route).
  final VoidCallback? onClose;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final uiLanguage = quickImproveUiLanguage(Localizations.localeOf(context));
    final openSettings = onOpenSettings;
    return BlocProvider(
      create: (context) {
        final cubit = QuickImproveCubit(
          repository: context.read<TranslationRepository>(),
          text: text,
          engines: ImproveEngines.fromTranslateState(
            context.read<TranslateCubit>().state,
          ),
          uiLanguage: uiLanguage,
          usageTracker: _maybeRead<UsageTracker>(context),
        );
        unawaited(cubit.start());
        return cubit;
      },
      child: BlocListener<TranslateCubit, TranslateState>(
        // Engine equality ignores details such as the model, so compare
        // instances to pick up edited providers.
        listenWhen: (previous, current) =>
            !identical(previous.engines, current.engines) ||
            !identical(previous.assistEngine, current.assistEngine) ||
            previous.enginesStatus != current.enginesStatus,
        listener: (context, state) => unawaited(
          context.read<QuickImproveCubit>().updateEngines(
            ImproveEngines.fromTranslateState(state),
          ),
        ),
        child: Builder(
          builder: (context) => QuickImproveView(
            onReplace: onReplace,
            onOpenInProofread: onOpenInProofread,
            onReloadEngines: () => unawaited(
              context.read<TranslateCubit>().loadEngines(refresh: true),
            ),
            onAddProvider: openSettings == null
                ? null
                : () => openSettings(AppRoutes.providers),
            onSetUpOnDeviceAi: openSettings == null || !offerOnDeviceAi
                ? null
                : () => openSettings(AppRoutes.onDeviceAi),
            onClose: onClose,
            padding: padding,
          ),
        ),
      ),
    );
  }
}

/// Builds the quick improve UI from the [QuickImproveCubit] in context:
/// a header with Close, the selected text (collapsible), the AI model,
/// correction level and style chips, the improved text with its changes
/// highlighted ([QuickImproveResultView]) and the Copy / Retry / Open in
/// Proofread / Replace actions ([QuickImproveActionsBar]).
///
/// Replace is offered only with [onReplace] (an editable selection) and
/// enabled once the improved text changes something. The settings
/// callbacks ([onAddProvider], [onSetUpOnDeviceAi]) and the actions that
/// leave the sheet close it first.
class QuickImproveView extends StatefulWidget {
  const new({
    this.onReplace,
    this.onOpenInProofread,
    this.onReloadEngines,
    this.onAddProvider,
    this.onSetUpOnDeviceAi,
    this.onClose,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
    super.key,
  });

  final ValueChanged<String>? onReplace;
  final VoidCallback? onOpenInProofread;

  /// Loads the engine list again after it failed.
  final VoidCallback? onReloadEngines;
  final VoidCallback? onAddProvider;
  final VoidCallback? onSetUpOnDeviceAi;
  final VoidCallback? onClose;
  final EdgeInsetsGeometry padding;

  @override
  State<QuickImproveView> createState() => _QuickImproveViewState();
}

class _QuickImproveViewState extends State<QuickImproveView> {
  static const _copiedDuration = Duration(seconds: 2);
  static const _noticeDuration = Duration(seconds: 4);

  bool _copied = false;
  String? _notice;
  Timer? _copiedTimer;
  Timer? _noticeTimer;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _noticeTimer?.cancel();
    super.dispose();
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// Closes the sheet, then runs [action] (it leaves the sheet).
  void _closeThen(VoidCallback? action) {
    _close();
    action?.call();
  }

  void _showNotice(String message) {
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(_noticeDuration, () {
      if (mounted) setState(() => _notice = null);
    });
  }

  Future<void> _copy(String text) async {
    final message = context.l10n.commonCopied;
    await copyText(text);
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    // Android 13+ confirms copies itself.
    if (!systemShowsCopyConfirmation) _showNotice(message);
    _copiedTimer = Timer(_copiedDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _replace(String text) {
    final onReplace = widget.onReplace;
    _close();
    onReplace?.call(text);
  }

  /// Where [engine] sends the text, or null when the repository cannot
  /// tell.
  DataDestination? _destinationOf(TranslationEngine? engine) {
    if (engine == null) return null;
    try {
      return context.read<TranslationRepository>().destinationOf(engine.id);
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QuickImproveCubit>();
    return BlocBuilder<QuickImproveCubit, QuickImproveState>(
      builder: (context, state) {
        final improved = state.improvedText;
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Padding(
            padding: widget.padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(onClose: _close),
                const SizedBox(height: 4),
                Flexible(
                  child: SingleChildScrollView(
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          QuickSourceCard(
                            text: state.text,
                            detectedSource: state.result?.detectedLanguage,
                          ),
                          const Hairline(),
                          const SizedBox(height: 12),
                          if (state.engine case final engine?) ...[
                            _Options(
                              state: state,
                              engine: engine,
                              onSelectEngine: (engine) =>
                                  unawaited(cubit.selectEngine(engine)),
                              onManage: widget.onAddProvider == null
                                  ? null
                                  : () => _closeThen(widget.onAddProvider),
                            ),
                            const SizedBox(height: 16),
                          ],
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: QuickImproveResultView(
                              state: state,
                              onRetry: () => unawaited(cubit.retry()),
                              onReloadEngines: widget.onReloadEngines,
                              onAddProvider: widget.onAddProvider == null
                                  ? null
                                  : () => _closeThen(widget.onAddProvider),
                              onSetUpOnDeviceAi:
                                  widget.onSetUpOnDeviceAi == null
                                  ? null
                                  : () => _closeThen(widget.onSetUpOnDeviceAi),
                              destination: state.hasResult
                                  ? _destinationOf(state.engine)
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Hairline(),
                const SizedBox(height: 4),
                QuickImproveActionsBar(
                  canCopy: state.hasResult,
                  copied: _copied,
                  onCopy: () => unawaited(_copy(improved)),
                  onRetry: state.canImprove
                      ? () => unawaited(cubit.retry())
                      : null,
                  onOpenInProofread: widget.onOpenInProofread == null
                      ? null
                      : () => _closeThen(widget.onOpenInProofread),
                  onReplace: widget.onReplace == null
                      ? null
                      : () => _replace(improved),
                  canReplace: state.hasResult && !state.isUnchanged,
                ),
                _Notice(message: _notice),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// X compose-style header: Close at the start, a bold title.
class _Header extends StatelessWidget {
  const new({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Row(
      children: [
        IconButton(
          key: const Key('quick_improve_close'),
          tooltip: l10n.commonClose,
          icon: const Icon(Icons.close),
          onPressed: onClose,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              l10n.quickImproveTitle,
              style: theme.textTheme.titleLarge,
            ),
          ),
        ),
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: Icon(
              Icons.auto_fix_high_outlined,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}

/// The AI model, correction level and style of the proofread.
class _Options extends StatelessWidget {
  const new({
    required this.state,
    required this.engine,
    required this.onSelectEngine,
    required this.onManage,
  });

  final QuickImproveState state;
  final TranslationEngine engine;
  final ValueChanged<TranslationEngine> onSelectEngine;
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<QuickImproveCubit>();
    final enabled = !state.isImproving;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ComposerEngineChip(
          key: const Key('quick_improve_engine_chip'),
          engine: engine,
          engines: state.engines,
          onSelected: enabled ? onSelectEngine : null,
          onManage: onManage,
        ),
        QuickImproveOptionChip<CorrectionLevel>(
          keyPrefix: 'quick_improve_level',
          icon: Icons.tune,
          value: state.level,
          values: CorrectionLevel.values,
          labelOf: l10n.proofreadCorrectionLevel,
          tooltip: l10n.quickImproveLevelTooltip(
            l10n.proofreadCorrectionLevel(state.level),
          ),
          onSelected: enabled
              ? (level) => unawaited(cubit.setLevel(level))
              : null,
        ),
        QuickImproveOptionChip<WritingStyle>(
          keyPrefix: 'quick_improve_style',
          icon: Icons.brush_outlined,
          value: state.style,
          values: WritingStyle.values,
          labelOf: l10n.proofreadWritingStyle,
          tooltip: l10n.quickImproveStyleTooltip(
            l10n.proofreadWritingStyle(state.style),
          ),
          onSelected: enabled
              ? (style) => unawaited(cubit.setStyle(style))
              : null,
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const new({required this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = message;
    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      child: text == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  text,
                  key: const Key('quick_improve_notice'),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppPalette.of(context).secondaryText,
                  ),
                ),
              ),
            ),
    );
  }
}
