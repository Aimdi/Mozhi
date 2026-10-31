import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app_lock/view/app_lock_settings_tile.dart'
    show maybeAppLock;
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/live/live_engine_picker.dart';
import 'package:mozhi/live_captions/cubit/live_captions_cubit.dart';
import 'package:mozhi/live_captions/data/caption_recognizer.dart';
import 'package:mozhi/live_captions/data/captions_host.dart';
import 'package:mozhi/live_captions/data/method_channel_captions_host.dart';
import 'package:mozhi/live_captions/widgets/live_captions_widgets.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/screen_translate/data/screen_translate_controls.dart';
import 'package:mozhi/transcribe/data/transcript_export.dart';
import 'package:mozhi/transcribe/view/transcribe_page.dart'
    show TranscribeShareCallback, shareTranscriptText;
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:translation_repository/translation_repository.dart';

/// Live captions (`AppRoutes.liveCaptions`): translated captions of the
/// sound other apps play, in a caption bar over them and in a transcript
/// here. Creates a [LiveCaptionsCubit] for the page's lifetime: the
/// captions stop when the page goes (they go on while the app is in the
/// background, which is what they are for).
///
/// Requires [TranslationRepository], [TranslateCubit] and `SettingsCubit`
/// above it (the live engine is the settings' `liveEngineId`, see
/// `resolveLiveEngine`); [OfflineSpeech] (Whisper) and [HistoryCubit] are
/// used when provided. The other parameters replace the platform's
/// (tests): [host] (default [platformCaptionsHost]), [recognizer]
/// (default Whisper over [OfflineSpeech]), [overlay] ("Display over other
/// apps"), [conditions] (the phone's heat) and [openEnginePicker]
/// (default `showLiveEnginePicker`). The app lock (`maybeAppLock`) keeps
/// captions off the caption bar while the app is locked.
///
/// Opened with a start request (`?start=<token>`, [startParameter]: the
/// Quick Settings tile, `LiveCaptionsTileService.kt`), the captions start
/// as with Start, once the screen found out that they can run: the
/// microphone permission and the system's capture consent are asked as
/// always. Only the tile's own token starts them, once
/// ([CaptionsHost.consumeStartToken]): any other `start` value (the same
/// link from another app) only opens the screen.
class LiveCaptionsPage extends StatefulWidget {
  const new({
    this.host,
    this.recognizer,
    this.overlay,
    this.conditions,
    this.files = const PlatformDocumentFileService(),
    this.share = shareTranscriptText,
    this.openEnginePicker,
    super.key,
  });

  final Future<CaptionsHost> Function()? host;
  final CaptionRecognizer? recognizer;
  final ScreenTranslateControls? overlay;
  final DeviceConditions? conditions;
  final DocumentFileService files;
  final TranscribeShareCallback share;
  final LiveEnginePickerOpener? openEnginePicker;

  /// The query parameter of a start request (see the class).
  static const startParameter = 'start';

  @override
  State<LiveCaptionsPage> createState() => _LiveCaptionsPageState();
}

/// The start requests already handled in this app process: a page built
/// again at the same location does not start the captions again.
final _handledStarts = <String>{};

/// The start request of the page's location, if any: none outside a page
/// of the router (as in tests).
String? _startRequest(BuildContext context) {
  if (GoRouter.maybeOf(context) == null ||
      ModalRoute.of(context)?.settings is! Page<Object?>) {
    return null;
  }
  final token = GoRouterState.of(context)
      .uri
      .queryParameters[LiveCaptionsPage.startParameter];
  return token == null || token.isEmpty ? null : token;
}

class _LiveCaptionsPageState extends State<LiveCaptionsPage> {
  late final Future<CaptionsHost> _host = (widget.host ?? platformCaptionsHost)
      .call();

  static T? _maybe<T>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CaptionsHost>(
    future: _host,
    builder: (context, snapshot) {
      final host = snapshot.data;
      if (host == null) {
        return Scaffold(
          appBar: AppBar(title: Text(context.l10n.liveCaptionsTitle)),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      final l10n = context.l10n;
      final startRequest = _startRequest(context);
      return BlocProvider(
        create: (context) {
          final translate = context.read<TranslateCubit>();
          final target = translate.state.target;
          final speech = _maybe<OfflineSpeech>(context);
          final cubit = LiveCaptionsCubit(
            host: host,
            repository: context.read<TranslationRepository>(),
            engine: () => liveCaptionsEngine(context),
            source: Language.auto,
            target: target.isAuto || target.isCustom
                ? LanguageCatalog.byCode('en') ??
                      const Language(code: 'en', name: 'English')
                : target,
            recognizer:
                widget.recognizer ??
                (speech == null || !speech.isAvailable
                    ? null
                    : WhisperCaptionRecognizer(speech)),
            overlay:
                widget.overlay ?? MethodChannelScreenTranslateControls.instance,
            conditions: widget.conditions ?? DeviceConditions.instance,
            history: _maybe<HistoryCubit>(context),
            lock: maybeAppLock(context),
            describe: (text) => switch (text) {
              LiveCaptionsBarText.listening => l10n.liveCaptionsBarListening,
              LiveCaptionsBarText.silence => l10n.liveCaptionsBarSilence,
              LiveCaptionsBarText.hot => l10n.liveCaptionsBarHot,
              LiveCaptionsBarText.appLocked => l10n.liveCaptionsBarLocked,
            },
          );
          unawaited(cubit.load());
          return cubit;
        },
        child: _StartOnRequest(
          token: startRequest,
          host: host,
          child: LiveCaptionsView(
            files: widget.files,
            share: widget.share,
            openEnginePicker: widget.openEnginePicker ?? showLiveEnginePicker,
          ),
        ),
      );
    },
  );
}

/// The layout of the [LiveCaptionsCubit] above it: the options, the
/// transcript (or what captions do, while it is empty) and Start / Stop.
/// One-off messages show in snack bars, "Display over other apps" is
/// explained in a dialog, and starting, stopping and pausing are announced
/// to screen readers (each caption is not).
class LiveCaptionsView extends StatelessWidget {
  const new({
    required this.openEnginePicker,
    this.files = const PlatformDocumentFileService(),
    this.share = shareTranscriptText,
    super.key,
  });

  final LiveEnginePickerOpener openEnginePicker;
  final DocumentFileService files;
  final TranscribeShareCallback share;

  /// Widest the content gets on large screens.
  static const double maxContentWidth = 1100;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = context.select<LiveCaptionsCubit, LiveCaptionsStatus>(
      (cubit) => cubit.state.status,
    );
    final empty = context.select<LiveCaptionsCubit, bool>(
      (cubit) => cubit.state.entries.isEmpty,
    );
    final body = switch (status) {
      LiveCaptionsStatus.loading => const Center(
        child: CircularProgressIndicator(),
      ),
      LiveCaptionsStatus.unsupported ||
      LiveCaptionsStatus.needsModel => LiveCaptionsUnavailable(status: status),
      _ => Column(
        children: [
          LiveCaptionsOptions(openEnginePicker: openEnginePicker),
          const LiveCaptionsBanners(),
          const Divider(height: 1),
          Expanded(
            child: empty
                ? const LiveCaptionsAbout()
                : const LiveCaptionsTranscript(),
          ),
          const LiveCaptionsControls(),
        ],
      ),
    };
    final ready =
        status != LiveCaptionsStatus.loading &&
        status != LiveCaptionsStatus.unsupported &&
        status != LiveCaptionsStatus.needsModel;
    return MultiBlocListener(
      listeners: [
        BlocListener<LiveCaptionsCubit, LiveCaptionsState>(
          listenWhen: (previous, current) =>
              current.notices > previous.notices && current.notice != null,
          listener: (context, state) =>
              _say(context, _noticeText(l10n, state.notice!)),
        ),
        BlocListener<LiveCaptionsCubit, LiveCaptionsState>(
          listenWhen: (previous, current) =>
              current.overlayPrompt && !previous.overlayPrompt,
          listener: (context, state) => unawaited(_explainOverlay(context)),
        ),
      ],
      child: _LiveCaptionsAnnouncer(
        child: Scaffold(
          appBar: AppBar(
            title: Text(l10n.liveCaptionsTitle),
            actions: [
              if (ready) ...[
                const _CopyButton(),
                _MenuButton(files: files, share: share),
              ],
              const SizedBox(width: 4),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: maxContentWidth),
              child: body,
            ),
          ),
        ),
      ),
    );
  }

  static String _noticeText(AppLocalizations l10n, LiveCaptionsNotice notice) =>
      switch (notice) {
        LiveCaptionsNotice.declined => l10n.liveCaptionsDeclined,
        LiveCaptionsNotice.permissionDenied =>
          l10n.liveCaptionsPermissionDenied,
        LiveCaptionsNotice.startFailed => l10n.liveCaptionsStartFailed,
        LiveCaptionsNotice.captureEnded => l10n.liveCaptionsEnded,
        LiveCaptionsNotice.saved => l10n.transcribeSavedHistory,
        LiveCaptionsNotice.savedAsFavorite => l10n.transcribeSavedFavorite,
        LiveCaptionsNotice.saveFailed => l10n.transcribeSaveHistoryFailed,
      };

  static void _say(BuildContext context, String message) =>
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));

  /// "Show captions over other apps?": the setting, captions on this
  /// screen only, or (dismissed) not now.
  static Future<void> _explainOverlay(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<LiveCaptionsCubit>();
    final allow = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.liveCaptionsOverlayTitle),
        content: Text(l10n.liveCaptionsOverlayBody),
        actions: [
          TextButton(
            key: const Key('live_captions_overlay_skip'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.liveCaptionsOverlaySkip),
          ),
          FilledButton(
            key: const Key('live_captions_overlay_allow'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.liveCaptionsOverlayAllow),
          ),
        ],
      ),
    );
    if (cubit.isClosed) return;
    switch (allow) {
      case true:
        await cubit.allowCaptionBar();
      case false:
        await cubit.skipCaptionBar();
      case null:
        cubit.dismissCaptionBarPrompt();
    }
  }
}

/// Tells screen readers, once, that captions started, stopped or paused
/// (and why); never the captions themselves.
class _LiveCaptionsAnnouncer extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_LiveCaptionsAnnouncer> createState() => _LiveCaptionsAnnouncerState();
}

class _LiveCaptionsAnnouncerState extends State<_LiveCaptionsAnnouncer> {
  String? _message;
  int _count = 0;

  void _onChange(BuildContext context, LiveCaptionsState state) {
    final l10n = context.l10n;
    final message = switch (state) {
      LiveCaptionsState(isRunning: true, pause: LiveCaptionsPause.locked) =>
        l10n.liveCaptionsStatusLocked,
      LiveCaptionsState(isRunning: true, pause: LiveCaptionsPause.hot) =>
        l10n.liveCaptionsStatusHot,
      LiveCaptionsState(isRunning: true) => l10n.liveCaptionsAnnounceStarted,
      _ => l10n.liveCaptionsAnnounceStopped,
    };
    setState(() {
      _message = message;
      _count++;
    });
  }

  @override
  Widget build(BuildContext context) =>
      BlocListener<LiveCaptionsCubit, LiveCaptionsState>(
        listenWhen: (previous, current) =>
            (previous.isRunning != current.isRunning &&
                (current.isRunning ||
                    previous.status == LiveCaptionsStatus.running)) ||
            (current.isRunning && previous.pause != current.pause),
        listener: _onChange,
        child: StatusAnnouncer(
          message: _message,
          announcementId: _count,
          child: widget.child,
        ),
      );
}

/// The transcript as text, with the date as its title.
String liveCaptionsText(BuildContext context, LiveCaptionsState state) {
  final l10n = context.l10n;
  final date = MaterialLocalizations.of(context)
      .formatMediumDate(DateTime.now());
  return TranscriptExport.text(
    state.entries,
    skipped: l10n.transcribeSkippedMark,
    title: l10n.transcribeExportTitle(date),
  );
}

class _CopyButton extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final has = context.select<LiveCaptionsCubit, bool>(
      (cubit) => cubit.state.hasTranscript,
    );
    return IconButton(
      key: const Key('live_captions_copy'),
      tooltip: l10n.transcribeCopy,
      icon: const Icon(Icons.content_copy_outlined),
      onPressed: !has
          ? null
          : () async {
              final messenger = ScaffoldMessenger.maybeOf(context);
              final message = l10n.commonCopied;
              await copyText(
                liveCaptionsText(
                  context,
                  context.read<LiveCaptionsCubit>().state,
                ),
              );
              if (systemShowsCopyConfirmation) return;
              messenger
                ?..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text(message)));
            },
    );
  }
}

enum _MenuAction { share, saveText, saveSubtitles, history, clear }

/// Share, export (text, subtitles), save to History, clear: only when the
/// user asks.
class _MenuButton extends StatelessWidget {
  const new({required this.files, required this.share});

  final DocumentFileService files;
  final TranscribeShareCallback share;

  Future<void> _save(BuildContext context, {required bool subtitles}) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final state = context.read<LiveCaptionsCubit>().state;
    final contents = subtitles
        ? TranscriptExport.srt(state.entries)
        : liveCaptionsText(context, state);
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 16)
        .replaceAll(':', '-');
    String? message;
    try {
      final saved = await files.saveFile(
        fileName: 'captions-$stamp.${subtitles ? 'srt' : 'txt'}',
        bytes: TranscriptExport.bytes(contents),
        mimeType: subtitles
            ? TranscriptExport.srtMimeType
            : TranscriptExport.textMimeType,
      );
      if (saved) message = l10n.transcribeFileSaved;
    } on Object {
      message = l10n.transcribeFileFailed;
    }
    if (message == null) return;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _share(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    await share(
      liveCaptionsText(context, context.read<LiveCaptionsCubit>().state),
      subject: context.l10n.liveCaptionsTitle,
      origin: origin,
    );
  }

  Future<void> _clear(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<LiveCaptionsCubit>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.transcribeClearTitle),
        content: Text(l10n.transcribeClearBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            key: const Key('live_captions_clear_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.commonClear),
          ),
        ],
      ),
    );
    if (confirmed ?? false) cubit.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<LiveCaptionsCubit>().state;
    final has = state.hasTranscript;
    return PopupMenuButton<_MenuAction>(
      key: const Key('live_captions_menu'),
      tooltip: l10n.commonMoreOptions,
      icon: const Icon(Icons.more_vert),
      onSelected: (action) {
        switch (action) {
          case _MenuAction.share:
            unawaited(_share(context));
          case _MenuAction.saveText:
            unawaited(_save(context, subtitles: false));
          case _MenuAction.saveSubtitles:
            unawaited(_save(context, subtitles: true));
          case _MenuAction.history:
            unawaited(context.read<LiveCaptionsCubit>().saveToHistory());
          case _MenuAction.clear:
            unawaited(_clear(context));
        }
      },
      itemBuilder: (context) => [
        _item(
          _MenuAction.share,
          Icons.share_outlined,
          l10n.transcribeShare,
          enabled: has,
        ),
        _item(
          _MenuAction.saveText,
          Icons.description_outlined,
          l10n.transcribeSaveText,
          enabled: has,
        ),
        _item(
          _MenuAction.saveSubtitles,
          Icons.subtitles_outlined,
          l10n.transcribeSaveSubtitles,
          enabled: has,
        ),
        _item(
          _MenuAction.history,
          Icons.history,
          l10n.transcribeSaveHistory,
          enabled: has,
        ),
        _item(
          _MenuAction.clear,
          Icons.delete_sweep_outlined,
          l10n.transcribeClear,
          enabled: state.entries.isNotEmpty && !state.isActive,
        ),
      ],
    );
  }

  static PopupMenuItem<_MenuAction> _item(
    _MenuAction action,
    IconData icon,
    String label, {
    required bool enabled,
  }) => PopupMenuItem(
    key: Key('live_captions_menu_${action.name}'),
    value: action,
    enabled: enabled,
    child: ListTile(leading: Icon(icon), title: Text(label)),
  );
}

/// Starts the captions for a new start request [token] of the page's
/// location ([LiveCaptionsPage.startParameter]) when [host] knows it as the
/// tile's ([CaptionsHost.consumeStartToken]).
class _StartOnRequest extends StatefulWidget {
  const new({required this.token, required this.host, required this.child});

  final String? token;
  final CaptionsHost host;
  final Widget child;

  @override
  State<_StartOnRequest> createState() => _StartOnRequestState();
}

class _StartOnRequestState extends State<_StartOnRequest> {
  @override
  void initState() {
    super.initState();
    _handle();
  }

  @override
  void didUpdateWidget(_StartOnRequest oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token) _handle();
  }

  void _handle() {
    final token = widget.token;
    if (token == null || !_handledStarts.add(token)) return;
    unawaited(_startFor(token));
  }

  Future<void> _startFor(String token) async {
    // Not the tile's: the screen only opens.
    if (!await widget.host.consumeStartToken(token) || !mounted) return;
    unawaited(context.read<LiveCaptionsCubit>().requestStart());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
