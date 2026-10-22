import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/documents/data/document_file_service.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/transcribe/cubit/transcribe_cubit.dart';
import 'package:mozhi/transcribe/data/screen_awake.dart';
import 'package:mozhi/transcribe/data/transcriber.dart';
import 'package:mozhi/transcribe/data/transcript_export.dart';
import 'package:mozhi/transcribe/widgets/transcribe_controls.dart';
import 'package:mozhi/transcribe/widgets/transcribe_options.dart';
import 'package:mozhi/transcribe/widgets/transcript_list.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/data/usage_tracker.dart';
import 'package:mozhi/voice/cubit/voice_settings_state.dart'
    show VoiceModelErrorKind;
import 'package:mozhi/voice/offline/offline_speech.dart';
import 'package:mozhi/voice/speech_input_service.dart';
import 'package:mozhi/voice/widgets/voice_error_message.dart';
import 'package:share_plus/share_plus.dart';
import 'package:translation_repository/translation_repository.dart';

/// Hands text to the platform share sheet ([origin]: the button's
/// rectangle, for popovers).
typedef TranscribeShareCallback = Future<void> Function(
  String text, {
  String? subject,
  Rect? origin,
});

/// Default [TranscribeShareCallback] backed by `share_plus`.
Future<void> shareTranscriptText(
  String text, {
  String? subject,
  Rect? origin,
}) async {
  await SharePlus.instance.share(
    ShareParams(text: text, subject: subject, sharePositionOrigin: origin),
  );
}

/// Transcribe: a rolling transcript of a lecture, a tour or a meeting,
/// with a translation of each phrase when the user turns it on. Creates a
/// [TranscribeCubit] for the page's lifetime: translations use the
/// app-wide [TranslateCubit]'s engine and options, the spoken language and
/// the translation language default to its source and target.
///
/// Requires [TranslationRepository], [TranslateCubit] and `SettingsCubit`
/// above it; [OfflineSpeech] (where Whisper runs), [SpeechInputService],
/// [HistoryCubit] and [UsageTracker] are used when provided. [transcriber]
/// and [screenAwake] replace the platform's (tests).
class TranscribePage extends StatelessWidget {
  const new({
    this.transcriber,
    this.screenAwake,
    this.files = const PlatformDocumentFileService(),
    this.share = shareTranscriptText,
    super.key,
  });

  final Transcriber Function(TranscribeMode mode)? transcriber;
  final ScreenAwake? screenAwake;
  final DocumentFileService files;
  final TranscribeShareCallback share;

  static T? _maybe<T>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) {
        final translate = context.read<TranslateCubit>();
        final target = translate.state.target;
        final cubit = TranscribeCubit(
          repository: context.read<TranslationRepository>(),
          engine: () => translate.state.engine,
          engines: () => translate.state.engines,
          options: () => translate.state.options,
          source: translate.state.source,
          target: target.isAuto
              ? LanguageCatalog.byCode('en') ??
                    const Language(code: 'en', name: 'English')
              : target,
          offline: _maybe<OfflineSpeech>(context),
          speechInput: _maybe<SpeechInputService>(context),
          history: _maybe<HistoryCubit>(context),
          usageTracker: _maybe<UsageTracker>(context),
          screenAwake: screenAwake,
          transcriber: transcriber,
        );
        unawaited(cubit.load());
        return cubit;
      },
      child: TranscribeView(files: files, share: share),
    );
  }
}

/// The layout of the [TranscribeCubit] above it: what listens and where
/// the translations go, the transcript and the microphone. Listening
/// pauses when the app goes to the background or the page is covered (it
/// can only listen on screen); failures and saves are explained in snack
/// bars.
class TranscribeView extends StatelessWidget {
  const new({
    this.files = const PlatformDocumentFileService(),
    this.share = shareTranscriptText,
    super.key,
  });

  final DocumentFileService files;
  final TranscribeShareCallback share;

  /// Widest the transcript gets on large screens (both columns).
  static const double maxContentWidth = 1100;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mode = context.select<TranscribeCubit, TranscribeMode>(
      (cubit) => cubit.state.mode,
    );
    final loading = context.select<TranscribeCubit, bool>(
      (cubit) => cubit.state.status == TranscribeStatus.loading,
    );
    final empty = context.select<TranscribeCubit, bool>(
      (cubit) => cubit.state.entries.isEmpty && cubit.state.partial.isEmpty,
    );
    final vadMissing = context.select<TranscribeCubit, bool>(
      (cubit) =>
          cubit.state.voiceDetectionMissing ||
          cubit.state.voiceDetectionProgress != null,
    );
    final Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!mode.canListen) {
      body = TranscribeUnavailable(mode: mode);
    } else {
      body = Column(
        children: [
          const TranscribeOptions(),
          if (vadMissing) const TranscribeVadBanner(),
          const Divider(height: 1),
          Expanded(
            child: empty ? const TranscribeEmpty() : const TranscriptList(),
          ),
          const TranscribeControls(),
        ],
      );
    }
    return _ListeningGuard(
      child: MultiBlocListener(
        listeners: [
          BlocListener<TranscribeCubit, TranscribeState>(
            listenWhen: (previous, current) =>
                current.failures > previous.failures && current.failure != null,
            listener: (context, state) => showVoiceInputErrorSnackBar(
              context,
              state.failure!,
              onDevice: state.mode == TranscribeMode.whisper,
              offlineSupported: state.mode == TranscribeMode.whisper,
            ),
          ),
          BlocListener<TranscribeCubit, TranscribeState>(
            listenWhen: (previous, current) =>
                current.historySaves > previous.historySaves,
            listener: (context, state) =>
                _say(context, switch (state.historyOutcome) {
                  TranscribeHistoryOutcome.saved => l10n.transcribeSavedHistory,
                  TranscribeHistoryOutcome.savedAsFavorite =>
                    l10n.transcribeSavedFavorite,
                  _ => l10n.transcribeSaveHistoryFailed,
                }),
          ),
          BlocListener<TranscribeCubit, TranscribeState>(
            listenWhen: (previous, current) =>
                current.voiceDetectionError != null &&
                previous.voiceDetectionError != current.voiceDetectionError &&
                current.voiceDetectionError!.kind !=
                    VoiceModelErrorKind.metered,
            listener: (context, state) =>
                _say(context, l10n.transcribeVadFailed),
          ),
        ],
        child: Scaffold(
          appBar: AppBar(
            title: Text(l10n.transcribeTitle),
            actions: [
              if (mode.canListen) ...[
                _CopyButton(),
                TranscribeMenuButton(files: files, share: share),
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

  static void _say(BuildContext context, String message) =>
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
}

/// The transcript as text, with the date as its title.
String transcriptText(BuildContext context, TranscribeState state) {
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
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final has = context.select<TranscribeCubit, bool>(
      (cubit) => cubit.state.hasTranscript,
    );
    return IconButton(
      key: const Key('transcribe_copy'),
      tooltip: l10n.transcribeCopy,
      icon: const Icon(Icons.content_copy_outlined),
      onPressed: !has
          ? null
          : () async {
              final messenger = ScaffoldMessenger.maybeOf(context);
              final message = l10n.commonCopied;
              await copyText(
                transcriptText(context, context.read<TranscribeCubit>().state),
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

/// Share, export (text, subtitles), save to History, clear.
class TranscribeMenuButton extends StatelessWidget {
  const new({
    this.files = const PlatformDocumentFileService(),
    this.share = shareTranscriptText,
    super.key,
  });

  final DocumentFileService files;
  final TranscribeShareCallback share;

  Future<void> _save(BuildContext context, {required bool subtitles}) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final state = context.read<TranscribeCubit>().state;
    final contents = subtitles
        ? TranscriptExport.srt(state.entries)
        : transcriptText(context, state);
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 16)
        .replaceAll(':', '-');
    String? message;
    try {
      final saved = await files.saveFile(
        fileName: 'transcript-$stamp.${subtitles ? 'srt' : 'txt'}',
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
      transcriptText(context, context.read<TranscribeCubit>().state),
      subject: context.l10n.transcribeTitle,
      origin: origin,
    );
  }

  Future<void> _clear(BuildContext context) async {
    final l10n = context.l10n;
    final cubit = context.read<TranscribeCubit>();
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
            key: const Key('transcribe_clear_confirm'),
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
    final state = context.watch<TranscribeCubit>().state;
    final has = state.hasTranscript;
    return PopupMenuButton<_MenuAction>(
      key: const Key('transcribe_menu'),
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
            unawaited(context.read<TranscribeCubit>().saveToHistory());
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
          enabled: state.entries.isNotEmpty && !state.isRecording,
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
    key: Key('transcribe_menu_${action.name}'),
    value: action,
    enabled: enabled,
    child: ListTile(leading: Icon(icon), title: Text(label)),
  );
}

/// Pauses listening when the app is hidden (another app, the screen off)
/// or [child] is covered (a page pushed above it): the app can only listen
/// on screen, and the microphone is never left open.
class _ListeningGuard extends StatefulWidget {
  const new({required this.child});

  final Widget child;

  @override
  State<_ListeningGuard> createState() => _ListeningGuardState();
}

class _ListeningGuardState extends State<_ListeningGuard> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: _pause);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled) _pause();
  }

  void _pause() {
    if (!mounted) return;
    final cubit = context.read<TranscribeCubit>();
    if (cubit.state.isRecording) unawaited(cubit.onHidden());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
