import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/quick_translate/cubit/quick_translate_cubit.dart';
import 'package:mozhi/quick_translate/widgets/widgets.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:translation_repository/translation_repository.dart';

/// Shows the quick translate UI for [text] handed over by another app
/// (Android `PROCESS_TEXT` selection action / share) or a hotkey: a modal
/// bottom sheet on phones, a dialog on wider windows (≥ 600 dp).
///
/// Reads [TranslationRepository] and [SettingsCubit] (required) and
/// [SpeechService] / [HistoryCubit] (optional: Listen is hidden / nothing
/// is saved to history without them) from [context].
///
/// [onReplace] receives the translation when the user taps Replace; the
/// button only appears when [canReplace] is true and [onReplace] is given
/// (a writable `PROCESS_TEXT` request). [onOpenInApp] shows an "Open in
/// app" button. The sheet closes itself before either callback runs.
/// Completes when the sheet is closed. Blank [text] shows nothing.
Future<void> showQuickTranslate(
  BuildContext context, {
  required String text,
  bool canReplace = false,
  ValueChanged<String>? onReplace,
  VoidCallback? onOpenInApp,
}) async {
  if (text.trim().isEmpty) return;
  final repository = context.read<TranslationRepository>();
  final settings = context.read<SettingsCubit>();
  final speech = _maybeRead<SpeechService>(context);
  final history = _maybeRead<HistoryCubit>(context);
  final wide = MediaQuery.sizeOf(context).width >= 600;

  Widget content(BuildContext routeContext, {required bool dialog}) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<TranslationRepository>.value(value: repository),
        if (speech != null)
          RepositoryProvider<SpeechService>.value(value: speech),
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
          onClose: () => Navigator.of(routeContext).pop(),
          padding: dialog
              ? const EdgeInsets.fromLTRB(16, 12, 16, 16)
              : const EdgeInsets.fromLTRB(16, 0, 16, 16),
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
/// [TranslationRepository], [SettingsCubit] and optional [HistoryCubit] in
/// context), starts translating right away and shows [QuickTranslateView].
class QuickTranslateSheet extends StatelessWidget {
  const new({
    required this.text,
    this.canReplace = false,
    this.onReplace,
    this.onOpenInApp,
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
  }) => showQuickTranslate(
    context,
    text: text,
    canReplace: canReplace,
    onReplace: onReplace,
    onOpenInApp: onOpenInApp,
  );

  final String text;
  final bool canReplace;
  final ValueChanged<String>? onReplace;
  final VoidCallback? onOpenInApp;

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
          text: text,
        );
        unawaited(cubit.start());
        return cubit;
      },
      child: QuickTranslateView(
        canReplace: canReplace,
        onReplace: onReplace,
        onOpenInApp: onOpenInApp,
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
class QuickTranslateView extends StatefulWidget {
  const new({
    this.canReplace = false,
    this.onReplace,
    this.onOpenInApp,
    this.onClose,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
    super.key,
  });

  final bool canReplace;
  final ValueChanged<String>? onReplace;
  final VoidCallback? onOpenInApp;
  final VoidCallback? onClose;
  final EdgeInsetsGeometry padding;

  @override
  State<QuickTranslateView> createState() => _QuickTranslateViewState();
}

class _QuickTranslateViewState extends State<QuickTranslateView> {
  static const _copiedDuration = Duration(seconds: 2);
  static const _noticeDuration = Duration(seconds: 4);

  late final SpeechService? _speech = _maybeRead<SpeechService>(context);
  bool _picking = false;
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

  void _showNotice(String message) {
    _noticeTimer?.cancel();
    setState(() => _notice = message);
    _noticeTimer = Timer(_noticeDuration, () {
      if (mounted) setState(() => _notice = null);
    });
  }

  Future<void> _copy(String translation) async {
    final message = context.l10n.commonCopied;
    await Clipboard.setData(ClipboardData(text: translation));
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _showNotice(message);
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
          );
        }

        final replaceAvailable = widget.canReplace && widget.onReplace != null;
        final translation = state.translation;
        final speech = _speech;
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
                  _Header(onClose: _close),
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
                    const SizedBox(height: 16),
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
                              onError: () => _showNotice(
                                context.l10n.translateSpeechError,
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
                  _Notice(message: _notice),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const new({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.translate, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              l10n.quickTranslateTitle,
              style: theme.textTheme.titleMedium,
            ),
          ),
        ),
        IconButton(
          key: const Key('quick_translate_close'),
          tooltip: l10n.commonClose,
          icon: const Icon(Icons.close),
          onPressed: onClose,
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
  });

  final QuickTranslateState state;
  final VoidCallback? onPickTarget;
  final ValueChanged<TranslationEngine> onSelectEngine;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        QuickSourceCard(text: state.text, detectedSource: state.detectedSource),
        const SizedBox(height: 12),
        if (state.status != QuickTranslateStatus.noEngines) ...[
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              QuickTargetChip(target: state.target, onPressed: onPickTarget),
              QuickEngineChip(
                engine: state.engine,
                engines: state.engines,
                onSelected: onSelectEngine,
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: QuickResultView(state: state, onRetry: onRetry),
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
                  key: const Key('quick_translate_notice'),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
    );
  }
}
