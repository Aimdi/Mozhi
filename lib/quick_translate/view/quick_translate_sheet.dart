import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/router.dart' show AppRoutes;
import 'package:mozhi/core/widgets/consent_prompt.dart' show DestinationChip;
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/quick_translate/cubit/quick_translate_cubit.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';
import 'package:mozhi/quick_translate/widgets/widgets.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/speech/speech_error_message.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// Shows the quick translate UI for [text] handed over by another app
/// (Android `PROCESS_TEXT` selection action / share) or a hotkey: a modal
/// bottom sheet on phones, a dialog on wider windows (≥ 600 dp).
///
/// Reads [TranslationRepository] and [SettingsCubit] (required) and
/// [SpeechService] / [HistoryCubit] / [OfflineTranslator] (optional:
/// Listen is hidden / nothing is saved to history / there is no on-device
/// engine without them) from [context].
///
/// [onReplace] receives the translation when the user taps Replace; the
/// button only appears when [canReplace] is true and [onReplace] is given
/// (a writable `PROCESS_TEXT` request). [onOpenInApp] shows an "Open in
/// app" button. The sheet closes itself before either callback runs.
/// Completes when the sheet is closed. Blank [text] shows nothing.
///
/// [offlineOnly] ("Translate offline") translates with the on-device engine
/// only (see `QuickTranslateCubit`); when a language must be downloaded
/// first, its button closes the sheet and opens the offline languages
/// ([AppRoutes.offline]) with the [GoRouter] above [context], if any.
///
/// In the translucent quick translate window ([host], default
/// [QuickTranslateHost.instance], when it [QuickTranslateHost.isActive])
/// the offline languages open in the main window, and closing the sheet
/// closes the window.
Future<void> showQuickTranslate(
  BuildContext context, {
  required String text,
  bool canReplace = false,
  ValueChanged<String>? onReplace,
  VoidCallback? onOpenInApp,
  bool offlineOnly = false,
  QuickTranslateHost? host,
}) async {
  if (text.trim().isEmpty) return;
  final window = host ?? QuickTranslateHost.instance;
  final inWindow = window.isActive;
  final repository = context.read<TranslationRepository>();
  final settings = context.read<SettingsCubit>();
  final speech = _maybeRead<SpeechService>(context);
  final history = _maybeRead<HistoryCubit>(context);
  final offline = _maybeRead<OfflineTranslator>(context);
  final router = GoRouter.maybeOf(context);
  final wide = MediaQuery.sizeOf(context).width >= 600;

  Widget content(BuildContext routeContext, {required bool dialog}) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<TranslationRepository>.value(value: repository),
        if (speech != null)
          RepositoryProvider<SpeechService>.value(value: speech),
        if (offline != null)
          RepositoryProvider<OfflineTranslator>.value(value: offline),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<SettingsCubit>.value(value: settings),
          if (history != null) BlocProvider<HistoryCubit>.value(value: history),
        ],
        child: QuickTranslateSheet(
          text: text,
          canReplace: canReplace,
          onReplace: onReplace,
          onOpenInApp: onOpenInApp,
          offlineOnly: offlineOnly,
          onOpenOfflineModels: inWindow
              ? () => unawaited(window.openLocationInApp(AppRoutes.offline))
              : router == null
              ? null
              : () => unawaited(router.push<void>(AppRoutes.offline)),
          onClose: () => Navigator.of(routeContext).pop(),
          padding: dialog
              ? const EdgeInsets.fromLTRB(16, 12, 16, 16)
              // The sheet's safe area leaves out the bottom: keep the
              // actions above the navigation bar (edge to edge). The
              // padding is gone while the keyboard covers the bar.
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

/// Quick translate content (for a bottom sheet, dialog or a small desktop
/// window): creates a [QuickTranslateCubit] for [text] (from the
/// [TranslationRepository], [SettingsCubit] and optional [HistoryCubit] and
/// [OfflineTranslator] in context), starts translating right away and
/// shows [QuickTranslateView].
class QuickTranslateSheet extends StatelessWidget {
  const new({
    required this.text,
    this.canReplace = false,
    this.onReplace,
    this.onOpenInApp,
    this.offlineOnly = false,
    this.onOpenOfflineModels,
    this.onClose,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
    super.key,
  });

  /// See [showQuickTranslate].
  static Future<void> show(
    BuildContext context, {
    required String text,
    bool canReplace = false,
    ValueChanged<String>? onReplace,
    VoidCallback? onOpenInApp,
    bool offlineOnly = false,
  }) => showQuickTranslate(
    context,
    text: text,
    canReplace: canReplace,
    onReplace: onReplace,
    onOpenInApp: onOpenInApp,
    offlineOnly: offlineOnly,
  );

  final String text;
  final bool canReplace;
  final ValueChanged<String>? onReplace;
  final VoidCallback? onOpenInApp;

  /// Translate with the on-device engine only ("Translate offline").
  final bool offlineOnly;

  /// Opens the offline languages, offered when a language must be
  /// downloaded first (see [QuickTranslateView.onOpenOfflineModels]).
  final VoidCallback? onOpenOfflineModels;

  /// Closes the UI (default: pops the current route).
  final VoidCallback? onClose;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final cubit = QuickTranslateCubit(
          repository: context.read<TranslationRepository>(),
          settings: context.read<SettingsCubit>(),
          history: _maybeRead<HistoryCubit>(context),
          offline: _maybeRead<OfflineTranslator>(context),
          offlineOnly: offlineOnly,
          text: text,
        );
        unawaited(cubit.start());
        return cubit;
      },
      child: QuickTranslateView(
        canReplace: canReplace,
        onReplace: onReplace,
        onOpenInApp: onOpenInApp,
        onOpenOfflineModels: onOpenOfflineModels,
        onClose: onClose,
        padding: padding,
      ),
    );
  }
}

/// Builds the quick translate UI from the [QuickTranslateCubit] in context:
/// header with Close, the incoming text (collapsible) with the detected
/// language, target language and engine chips, the (streaming) translation
/// and the Copy / Listen / Open in app / Replace actions.
///
/// Offline only ([QuickTranslateState.offlineOnly]) the title is
/// "Translate offline" and an "On device" destination chip replaces the
/// engine picker. Listen is only offered when reading aloud stays on the
/// device too ([SpeechService.preferDeviceVoice], or the offline-only
/// privacy mode), and never offers to listen online.
class QuickTranslateView extends StatefulWidget {
  const new({
    this.canReplace = false,
    this.onReplace,
    this.onOpenInApp,
    this.onOpenOfflineModels,
    this.onClose,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
    super.key,
  });

  final bool canReplace;
  final ValueChanged<String>? onReplace;
  final VoidCallback? onOpenInApp;

  /// Opens the offline languages: offered (after the UI closed itself)
  /// when a language must be downloaded to translate on the device. No
  /// button without it.
  final VoidCallback? onOpenOfflineModels;
  final VoidCallback? onClose;
  final EdgeInsetsGeometry padding;

  @override
  State<QuickTranslateView> createState() => _QuickTranslateViewState();
}

class _QuickTranslateViewState extends State<QuickTranslateView> {
  static const _copiedDuration = Duration(seconds: 2);
  static const _noticeDuration = Duration(seconds: 4);

  SpeechService? _speech;

  /// Whether the privacy mode is offline only, where the repository never
  /// lets text-to-speech reach a Mozhi instance.
  bool _offlineOnlyPrivacy = false;
  bool _picking = false;
  bool _copied = false;
  String? _notice;
  _NoticeAction? _noticeAction;
  Timer? _copiedTimer;
  Timer? _noticeTimer;

  @override
  void initState() {
    super.initState();
    _speech = _maybeRead<SpeechService>(context);
    _offlineOnlyPrivacy =
        _maybeRead<SettingsCubit>(context)?.state.privacyMode ==
        PrivacyMode.offlineOnly;
  }

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

  void _showNotice(String message, {_NoticeAction? action}) {
    _noticeTimer?.cancel();
    setState(() {
      _notice = message;
      _noticeAction = action;
    });
    // Long enough to read the offer and decide.
    _noticeTimer = Timer(
      action == null ? _noticeDuration : _noticeDuration * 3,
      () {
        if (mounted) {
          setState(() {
            _notice = null;
            _noticeAction = null;
          });
        }
      },
    );
  }

  /// [error] as reported when nothing can be offered: without the Mozhi
  /// instance it could have used.
  static Object _withoutConsent(Object error) => switch (error) {
    SpeechUnavailableException(:final languageCode)
        when error.onlineConsent != null =>
      SpeechUnavailableException(languageCode),
    _ => error,
  };

  Future<void> _copy(String translation) async {
    final message = context.l10n.commonCopied;
    await copyText(translation);
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    // Android 13+ confirms copies itself.
    if (!systemShowsCopyConfirmation) _showNotice(message);
    _copiedTimer = Timer(_copiedDuration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _replace(String translation) {
    final onReplace = widget.onReplace;
    _close();
    onReplace?.call(translation);
  }

  void _openInApp() {
    final onOpenInApp = widget.onOpenInApp;
    _close();
    onOpenInApp?.call();
  }

  /// The offline languages are a page of the settings tab, below this
  /// sheet or dialog: close it first.
  void _openOfflineModels() {
    final onOpenOfflineModels = widget.onOpenOfflineModels;
    _close();
    onOpenOfflineModels?.call();
  }

  /// The [SpeechService] for Listen, or null to hide it. Offline only,
  /// reading aloud must not reach Mozhi's text-to-speech either: only with
  /// "device voice only" or in the offline-only privacy mode.
  SpeechService? _listenSpeech(QuickTranslateState state) {
    final speech = _speech;
    if (speech == null || !state.offlineOnly) return speech;
    return speech.preferDeviceVoice || _offlineOnlyPrivacy ? speech : null;
  }

  void _pickTarget(Language language) {
    setState(() => _picking = false);
    unawaited(context.read<QuickTranslateCubit>().setTarget(language));
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QuickTranslateCubit>();
    return BlocBuilder<QuickTranslateCubit, QuickTranslateState>(
      builder: (context, state) {
        final Widget body;
        if (_picking) {
          body = QuickLanguagePanel(
            languages: cubit.pickerLanguages(
              preferredCodes: [
                for (final locale in View.of(
                  context,
                ).platformDispatcher.locales)
                  locale.languageCode,
              ],
            ),
            selected: state.target,
            allowCustom: state.allowsCustomTarget,
            onSelected: _pickTarget,
            onBack: () => setState(() => _picking = false),
          );
        } else {
          body = _ResultBody(
            state: state,
            onPickTarget: state.engine == null
                ? null
                : () => setState(() => _picking = true),
            onSelectEngine: (engine) => unawaited(cubit.selectEngine(engine)),
            onRetry: () => unawaited(cubit.retry()),
            onOpenOfflineModels: widget.onOpenOfflineModels == null
                ? null
                : _openOfflineModels,
          );
        }

        final replaceAvailable = widget.canReplace && widget.onReplace != null;
        final translation = state.translation;
        final speech = _listenSpeech(state);
        final target = state.target;

        return PopScope(
          canPop: !_picking,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _picking) setState(() => _picking = false);
          },
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Padding(
              padding: widget.padding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(onClose: _close, offlineOnly: state.offlineOnly),
                  const SizedBox(height: 4),
                  Flexible(
                    child: SingleChildScrollView(
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: body,
                      ),
                    ),
                  ),
                  if (!_picking) ...[
                    const SizedBox(height: 12),
                    const Hairline(),
                    const SizedBox(height: 4),
                    QuickActionsBar(
                      enabled: state.hasTranslation,
                      copied: _copied,
                      onCopy: () => unawaited(_copy(translation)),
                      listenButton: speech == null
                          ? null
                          : QuickListenButton(
                              speech: speech,
                              text: state.hasTranslation ? translation : '',
                              languageCode: target.isCustom
                                  ? null
                                  : target.code,
                              onError: (error, listenOnline) => _showNotice(
                                listenOnline == null || state.offlineOnly
                                    ? speechErrorMessage(
                                        context.l10n,
                                        _withoutConsent(error),
                                      )
                                    : speechErrorMessage(context.l10n, error),
                                action:
                                    listenOnline == null || state.offlineOnly
                                    ? null
                                    : (
                                        label: speechListenOnlineLabel(
                                          context.l10n,
                                          error,
                                        )!,
                                        onPressed: listenOnline,
                                      ),
                              ),
                            ),
                      onReplace: replaceAvailable
                          ? () => _replace(translation)
                          : null,
                      onOpenInApp: widget.onOpenInApp == null
                          ? null
                          : _openInApp,
                    ),
                  ],
                  _Notice(message: _notice, action: _noticeAction),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// X compose-style header: Close at the start, a bold title.
class _Header extends StatelessWidget {
  const new({required this.onClose, required this.offlineOnly});

  final VoidCallback onClose;

  /// "Translate offline" with the on-device icon.
  final bool offlineOnly;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Row(
      children: [
        IconButton(
          key: const Key('quick_translate_close'),
          tooltip: l10n.commonClose,
          icon: const Icon(Icons.close),
          onPressed: onClose,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              offlineOnly
                  ? l10n.quickTranslateOfflineTitle
                  : l10n.quickTranslateTitle,
              style: theme.textTheme.titleLarge,
            ),
          ),
        ),
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: Icon(
              offlineOnly ? Icons.offline_bolt_outlined : Icons.translate,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}

class _ResultBody extends StatelessWidget {
  const new({
    required this.state,
    required this.onPickTarget,
    required this.onSelectEngine,
    required this.onRetry,
    required this.onOpenOfflineModels,
  });

  final QuickTranslateState state;
  final VoidCallback? onPickTarget;
  final ValueChanged<TranslationEngine> onSelectEngine;
  final VoidCallback onRetry;
  final VoidCallback? onOpenOfflineModels;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        QuickSourceCard(text: state.text, detectedSource: state.detectedSource),
        const Hairline(),
        const SizedBox(height: 12),
        if (state.status != QuickTranslateStatus.noEngines &&
            state.status != QuickTranslateStatus.offlineUnavailable) ...[
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              QuickTargetChip(target: state.target, onPressed: onPickTarget),
              if (state.offlineOnly)
                const DestinationChip(
                  key: Key('quick_translate_on_device'),
                  destination: OnDeviceDestination(),
                  engineId: TranslationEngine.offlineId,
                )
              else
                QuickEngineChip(
                  engine: state.engine,
                  engines: state.engines,
                  onSelected: onSelectEngine,
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: QuickResultView(
            state: state,
            onRetry: onRetry,
            onOpenOfflineModels: onOpenOfflineModels,
          ),
        ),
      ],
    );
  }
}

/// An action offered with a notice ("Listen online").
typedef _NoticeAction = ({String label, VoidCallback onPressed});

class _Notice extends StatelessWidget {
  const new({required this.message, this.action});

  final String? message;
  final _NoticeAction? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = message;
    final action = this.action;
    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      child: text == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      text,
                      key: const Key('quick_translate_notice'),
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppPalette.of(context).secondaryText,
                      ),
                    ),
                  ),
                  if (action != null)
                    TextButton(
                      key: const Key('quick_translate_notice_action'),
                      onPressed: action.onPressed,
                      child: Text(action.label),
                    ),
                ],
              ),
            ),
    );
  }
}
