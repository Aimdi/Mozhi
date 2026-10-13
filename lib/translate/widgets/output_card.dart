import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/offline.dart' show OfflineEngineBadge;
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/insight_sheet.dart';
import 'package:mozhi/translate/widgets/language_bar.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:share_plus/share_plus.dart';

/// Copies [text] and confirms with a snackbar.
Future<void> copyToClipboard(BuildContext context, String text) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final message = context.l10n.commonCopied;
  await Clipboard.setData(ClipboardData(text: text));
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Newest history entry for this exact text + translation (entries are
/// newest first).
HistoryEntry? findHistoryEntry(
  List<HistoryEntry> entries,
  String text,
  String translation,
) {
  final wanted = text.trim();
  for (final entry in entries) {
    if (entry.text.trim() == wanted && entry.translation == translation) {
      return entry;
    }
  }
  return null;
}

/// Outputs longer than this are announced as "Translation ready" instead
/// of being read out in full.
const maxAnnouncedOutputLength = 400;

/// Direction of the translated text: the target language's, or (custom
/// targets) the direction of its characters.
TextDirection? outputTextDirection(TranslateState state) =>
    textDirectionForLanguage(state.target) ??
    textDirectionForText(state.output);

/// The translation: streaming text, progress, errors, transliteration,
/// detected language, engine/latency footer and actions (copy, share,
/// listen, favourite, insights).
///
/// A finished translation is announced to screen readers once (never per
/// streamed token); errors are announced by [TranslateErrorView].
class OutputCard extends StatefulWidget {
  const new({super.key});

  @override
  State<OutputCard> createState() => _OutputCardState();
}

class _OutputCardState extends State<OutputCard> {
  bool _showInsights = false;

  void _toggleInsights(TranslateState state) {
    setState(() => _showInsights = !_showInsights);
    if (_showInsights &&
        (state.insightsStatus == ExtraStatus.idle ||
            state.insightsStatus == ExtraStatus.failure)) {
      unawaited(context.read<TranslateCubit>().loadInsights());
    }
  }

  void _toggleFavorite(TranslateState state, HistoryEntry? entry) {
    final history = context.read<HistoryCubit>();
    if (entry != null) {
      unawaited(history.toggleFavorite(entry.id));
      return;
    }
    final result = state.result;
    if (result == null) return;
    final now = DateTime.now();
    unawaited(
      history.add(
        HistoryEntry(
          id: now.microsecondsSinceEpoch.toString(),
          text: state.input.trim(),
          translation: state.output,
          source: state.source,
          target: state.target,
          engineId: result.engineId,
          engineName: result.engineName,
          createdAt: now,
          detectedSource: result.detectedSource,
          isFavorite: true,
        ),
      ),
    );
  }

  Future<void> _share(BuildContext buttonContext, String text) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    await SharePlus.instance.share(
      ShareParams(text: text, sharePositionOrigin: origin),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocConsumer<TranslateCubit, TranslateState>(
      // Keep insights on across translations: reload once the next one is
      // complete.
      listenWhen: (previous, current) =>
          _showInsights &&
          current.status == TranslateStatus.success &&
          current.insightsStatus == ExtraStatus.idle &&
          current.hasExtras &&
          (previous.status != current.status ||
              previous.insightsStatus != current.insightsStatus),
      listener: (context, state) =>
          unawaited(context.read<TranslateCubit>().loadInsights()),
      builder: (context, state) {
        final translating = state.status == TranslateStatus.translating;
        final (announcement, announcementDirection) = _announcement(
          context,
          state,
        );
        return StatusAnnouncer(
          message: announcement,
          textDirection: announcementDirection,
          child: Card(
            key: const Key('translate_output_card'),
            margin: EdgeInsets.zero,
            elevation: 0,
            clipBehavior: Clip.antiAlias,
            color: theme.colorScheme.surfaceContainer,
            shape: const RoundedRectangleBorder(
              borderRadius: TranslateLayout.cardBorderRadius,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 3,
                  child: translating
                      ? LinearProgressIndicator(
                          key: const Key('translate_output_progress'),
                          minHeight: 3,
                          semanticsLabel: context.l10n.translateTranslating,
                        )
                      : null,
                ),
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(20, 13, 8, 8),
                  child: _content(context, state),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// What to tell screen-reader users once a translation has finished: the
  /// translation itself (in the target's direction), or "Translation ready"
  /// for long texts. Null while idle, streaming or failed.
  (String?, TextDirection?) _announcement(
    BuildContext context,
    TranslateState state,
  ) {
    final output = state.output;
    final complete = state.result?.isComplete ?? false;
    if (state.status != TranslateStatus.success ||
        !complete ||
        output.trim().isEmpty) {
      return (null, null);
    }
    if (output.length > maxAnnouncedOutputLength) {
      return (context.l10n.translateAnnounceReady, null);
    }
    return (output, outputTextDirection(state));
  }

  Widget _content(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final output = state.output;
    final result = state.result;

    if (state.status == TranslateStatus.failure && output.isEmpty) {
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: 12, bottom: 8),
        child: TranslateErrorView(
          error: state.error,
          onRetry: () => unawaited(context.read<TranslateCubit>().translate()),
        ),
      );
    }

    if (output.isEmpty) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 96),
        child: Padding(
          padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
          child: Text(
            state.status == TranslateStatus.translating
                ? l10n.translateTranslating
                : l10n.translateOutputHint,
            style: TranslateLayout.textStyle(
              context,
              0,
            )?.copyWith(color: muted),
          ),
        ),
      );
    }

    final settings = context.watch<SettingsCubit>().state;
    final style = TranslateLayout.textStyle(context, output.length);
    final complete = result?.isComplete ?? true;
    final insightsReady =
        _showInsights &&
        state.insightsStatus == ExtraStatus.ready &&
        state.insights.isNotEmpty &&
        complete;
    final transliteration = result?.targetTransliteration.trim() ?? '';
    final detected = result?.detectedSource;
    final elapsed = result?.elapsed;
    final direction = outputTextDirection(state);
    final locale = localeForLanguage(state.target);
    final uncertain = detectionIsUncertain(state);
    final offline = result != null && isOfflineEngineId(result.engineId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
          // A named container; completion is announced separately (a live
          // region here would fire on every streamed token or not at all).
          child: Semantics(
            container: true,
            label: l10n.translateOutputLabel,
            child: SizedBox(
              width: double.infinity,
              child: insightsReady
                  ? InsightText(
                      text: output,
                      insights: state.insights,
                      style: style,
                      textDirection: direction,
                      locale: locale,
                      onTap: (insight) =>
                          unawaited(showInsightSheet(context, insight)),
                    )
                  : SelectableText.rich(
                      TextSpan(text: output, locale: locale),
                      key: const Key('translate_output_text'),
                      style: style,
                      textDirection: direction,
                    ),
            ),
          ),
        ),
        if (insightsReady)
          InsightChips(
            insights: state.insights,
            locale: locale,
            textDirection: direction,
          ),
        if (settings.showTransliteration && transliteration.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
            child: Text(
              transliteration,
              key: const Key('translate_output_transliteration'),
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ),
        if (_showInsights && state.hasExtras) _insightsStatus(context, state),
        if (complete && result != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 12, end: 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (detected != null && state.source.isAuto)
                  _DetectedChip(
                    uncertain: uncertain,
                    language: languageNameFor(detected, state.sourceLanguages),
                  ),
                if (offline) const OfflineEngineBadge(),
                Text(
                  elapsed == null
                      ? result.engineName
                      : l10n.translateEngineElapsed(
                          result.engineName,
                          formatSeconds(elapsed),
                        ),
                  key: const Key('translate_output_footer'),
                  style: theme.textTheme.labelMedium?.copyWith(color: muted),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        _actions(context, state),
      ],
    );
  }

  Widget _insightsStatus(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final child = switch (state.insightsStatus) {
      ExtraStatus.loading => LinearProgressIndicator(
        key: const Key('translate_insights_progress'),
        semanticsLabel: l10n.translateLoading,
      ),
      ExtraStatus.failure => TranslateErrorView(
        error: state.extraError,
        dense: true,
        onRetry: () => unawaited(context.read<TranslateCubit>().loadInsights()),
      ),
      // Live regions: announced once when the insights arrive.
      ExtraStatus.ready when state.insights.isEmpty => Semantics(
        liveRegion: true,
        child: Text(l10n.translateInsightsEmpty, style: muted),
      ),
      ExtraStatus.ready => Semantics(
        liveRegion: true,
        child: Text(l10n.translateInsightsHint, style: muted),
      ),
      ExtraStatus.idle => const SizedBox.shrink(),
    };
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 12, end: 12),
      child: child,
    );
  }

  Widget _actions(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final output = state.output;
    final complete = state.result?.isComplete ?? true;
    final target = state.target;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton(
          key: const Key('translate_copy_button'),
          tooltip: l10n.commonCopy,
          icon: const Icon(Icons.copy_outlined),
          onPressed: () => unawaited(copyToClipboard(context, output)),
        ),
        Builder(
          builder: (buttonContext) => IconButton(
            key: const Key('translate_share_button'),
            tooltip: l10n.commonShare,
            icon: const Icon(Icons.share_outlined),
            onPressed: () => unawaited(_share(buttonContext, output)),
          ),
        ),
        ListenButton(
          id: 'target',
          text: output,
          languageCode: target.isCustom ? null : target.code,
        ),
        BlocBuilder<HistoryCubit, HistoryState>(
          builder: (context, history) {
            final entry = findHistoryEntry(
              history.entries,
              state.input,
              output,
            );
            final favorite = entry?.isFavorite ?? false;
            return IconButton(
              key: const Key('translate_favorite_button'),
              tooltip: favorite
                  ? l10n.translateUnfavorite
                  : l10n.translateFavorite,
              isSelected: favorite,
              icon: const Icon(Icons.star_outline),
              selectedIcon: const Icon(Icons.star),
              onPressed: complete ? () => _toggleFavorite(state, entry) : null,
            );
          },
        ),
        if (state.hasExtras)
          IconButton(
            key: const Key('translate_insights_button'),
            tooltip: _showInsights
                ? l10n.translateInsightsHide
                : l10n.translateInsights,
            isSelected: _showInsights,
            icon: const Icon(Icons.lightbulb_outline),
            selectedIcon: const Icon(Icons.lightbulb),
            onPressed: complete ? () => _toggleInsights(state) : null,
          ),
      ],
    );
  }
}

/// "Detected: X" under the translation; tapping it opens the source
/// language picker to correct a wrong detection. Marked with a question
/// mark when the detection is uncertain (very short input).
class _DetectedChip extends StatelessWidget {
  const new({required this.language, required this.uncertain});

  final String language;
  final bool uncertain;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final label = uncertain
        ? l10n.translateDetectedLanguageUncertain(language)
        : l10n.translateDetectedLanguage(language);
    return ActionChip(
      key: const Key('translate_detected_chip'),
      avatar: Icon(
        uncertain ? Icons.help_outline : Icons.auto_awesome_outlined,
        color: scheme.onSecondaryContainer,
      ),
      label: Text(label),
      tooltip: uncertain
          ? l10n.translateDetectionUncertainHint
          : l10n.translateChangeSourceLanguage,
      backgroundColor: scheme.secondaryContainer,
      labelStyle: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: scheme.onSecondaryContainer),
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
      onPressed: () => unawaited(pickTranslateLanguage(context, source: true)),
    );
  }
}
