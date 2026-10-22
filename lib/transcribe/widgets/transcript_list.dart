import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/transcribe/cubit/transcribe_cubit.dart';
import 'package:mozhi/transcribe/data/transcriber.dart';
import 'package:mozhi/transcribe/models/transcript_entry.dart';
import 'package:mozhi/voice/offline/phrase_transcriber.dart';
import 'package:translation_repository/translation_repository.dart'
    show ConsentRequiredException;

/// The rolling transcript: one paragraph per phrase with its time and,
/// with translation on, its translation (side by side from [wideBreakpoint]
/// on). It follows new phrases while it is scrolled to the end; the
/// words of a phrase in progress ([TranscribeState.partial]) come last.
class TranscriptList extends StatefulWidget {
  const new({super.key});

  /// From this width the translation sits beside the phrase.
  static const double wideBreakpoint = 840;

  @override
  State<TranscriptList> createState() => _TranscriptListState();
}

class _TranscriptListState extends State<TranscriptList> {
  final _scroll = ScrollController();

  /// Whether the list is (about) at its end, so new phrases scroll in.
  bool _atEnd = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final position = _scroll.position;
      _atEnd = position.pixels >= position.maxScrollExtent - 48;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _follow() {
    if (!_atEnd) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(
          end,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = context.select<TranscribeCubit, List<TranscriptEntry>>(
      (cubit) => cubit.state.entries,
    );
    final partial = context.select<TranscribeCubit, String>(
      (cubit) => cubit.state.partial,
    );
    final consentId = context.select<TranscribeCubit, int?>(
      (cubit) => cubit.state.awaitingConsent.lastOrNull?.id,
    );
    final waitingForConsent = context.select<TranscribeCubit, int>(
      (cubit) => cubit.state.awaitingConsent.length,
    );
    final wide =
        MediaQuery.sizeOf(context).width >= TranscriptList.wideBreakpoint;
    return BlocListener<TranscribeCubit, TranscribeState>(
      listenWhen: (previous, current) =>
          previous.entries.length != current.entries.length ||
          previous.partial != current.partial,
      listener: (context, state) => _follow(),
      child: ListView.builder(
        key: const Key('transcribe_list'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: entries.length + (partial.isEmpty ? 0 : 1),
        itemBuilder: (context, index) {
          if (index == entries.length) return _PartialParagraph(partial);
          final entry = entries[index];
          return TranscriptParagraph(
            key: ValueKey('transcribe_entry_${entry.id}'),
            entry: entry,
            wide: wide,
            showConsent: entry.id == consentId,
            consentRequests: waitingForConsent,
          );
        },
      ),
    );
  }
}

/// One phrase: its time, the words and the translation.
class TranscriptParagraph extends StatelessWidget {
  const new({
    required this.entry,
    this.wide = false,
    this.showConsent = false,
    this.consentRequests = 1,
    super.key,
  });

  final TranscriptEntry entry;

  /// The translation beside the words instead of below.
  final bool wide;

  /// Show the consent prompt (for the latest entry that waits for it).
  final bool showConsent;

  /// How many entries the consent lets through.
  final int consentRequests;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final time = formatTranscriptTime(entry.start);
    final original = switch (entry.status) {
      PhraseStatus.transcribed => SelectableText(
        entry.text,
        style: theme.textTheme.bodyLarge,
      ),
      PhraseStatus.skipped => Text(
        l10n.transcribeSkipped,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: palette.secondaryText,
          fontStyle: FontStyle.italic,
        ),
      ),
      PhraseStatus.failed => Text(
        l10n.transcribePhraseFailed,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: palette.secondaryText,
          fontStyle: FontStyle.italic,
        ),
      ),
    };
    final translation = entry.translationStatus == null
        ? null
        : _Translation(
            entry: entry,
            showConsent: showConsent,
            consentRequests: consentRequests,
          );
    final body = translation == null
        ? original
        : wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: original),
              const SizedBox(width: 24),
              Expanded(child: translation),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [original, const SizedBox(height: 6), translation],
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: l10n.transcribeTimeLabel(time),
            excludeSemantics: true,
            child: Text(
              time,
              style: theme.textTheme.labelMedium?.copyWith(
                color: palette.secondaryText,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );
  }
}

class _Translation extends StatelessWidget {
  const new({
    required this.entry,
    required this.showConsent,
    required this.consentRequests,
  });

  final TranscriptEntry entry;
  final bool showConsent;
  final int consentRequests;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final scheme = theme.colorScheme;
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: palette.secondaryText,
    );
    final text = entry.translation.trim();
    switch (entry.translationStatus) {
      case null:
        return const SizedBox.shrink();
      case TranscriptTranslationStatus.done:
        return SelectableText(
          text,
          style: theme.textTheme.bodyLarge?.copyWith(color: scheme.primary),
        );
      case TranscriptTranslationStatus.translating:
        if (text.isNotEmpty) {
          return Text(
            text,
            style: theme.textTheme.bodyLarge?.copyWith(color: scheme.primary),
          );
        }
        return Semantics(
          liveRegion: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(l10n.transcribeTranslating, style: quiet),
            ],
          ),
        );
      case TranscriptTranslationStatus.failed:
        final error = entry.translationError;
        if (error is ConsentRequiredException) {
          if (!showConsent) {
            return Text(l10n.transcribeTranslationWaiting, style: quiet);
          }
          return ConsentInlinePrompt(
            key: Key('transcribe_consent_${entry.id}'),
            consent: error,
            requests: consentRequests,
            onGranted: () =>
                context.read<TranscribeCubit>().retryTranslations(),
          );
        }
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text(
              error is TranscribeNoEngineException
                  ? l10n.transcribeNoEngine
                  : l10n.transcribeTranslationFailed,
              style: quiet,
            ),
            TextButton.icon(
              key: Key('transcribe_retry_${entry.id}'),
              onPressed: () =>
                  context.read<TranscribeCubit>().retryTranslations(),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRetry),
            ),
          ],
        );
    }
  }
}

/// The words of the phrase being heard (system recognisers).
class _PartialParagraph extends StatelessWidget {
  const new(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const Key('transcribe_partial'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        text,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: AppPalette.of(context).secondaryText,
        ),
      ),
    );
  }
}
