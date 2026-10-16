import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/offline.dart' show OfflineEngineBadge;
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/aligned_text.dart';
import 'package:mozhi/translate/widgets/detection_chips.dart';
import 'package:mozhi/translate/widgets/empty_output.dart';
import 'package:mozhi/translate/widgets/extras_section.dart';
import 'package:mozhi/translate/widgets/insight_sheet.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';
import 'package:mozhi/translate/widgets/meaning_check_panel.dart';
import 'package:mozhi/translate/widgets/romanization_line.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/tool_chip.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:mozhi/translate/widgets/translation_memory_card.dart'
    show MemoryResultBadge;
import 'package:share_plus/share_plus.dart';
import 'package:translation_repository/translation_repository.dart';

export 'package:mozhi/translate/widgets/aligned_text.dart';
export 'package:mozhi/translate/widgets/detection_chips.dart';
export 'package:mozhi/translate/widgets/empty_output.dart';
export 'package:mozhi/translate/widgets/romanization_line.dart';

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

/// Opacity of a translation that belongs to text the user has since edited
/// (`TranslateState.isResultStale`).
const staleOutputOpacity = 0.6;

/// `SpeechService` clip id of the translation (the output card's Listen
/// button; "More tools > Listen to the translation slowly" reads the same
/// clip).
const translateOutputSpeechId = 'target';

/// Direction of the translated text: the target language's, or (custom
/// targets) the direction of its characters.
TextDirection? outputTextDirection(TranslateState state) =>
    textDirectionForLanguage(state.target) ??
    textDirectionForText(state.output);

/// The translation: streaming text, progress, errors, romanization,
/// detected language (with other likely languages when uncertain),
/// engine/latency footer, the everyday actions (copy, listen, favourite;
/// share at the end) and labelled tools (check meaning, insights,
/// romanization, matching phrases). Without a translation it shows
/// [EmptyOutput].
///
/// A finished translation is announced to screen readers once (never per
/// streamed token); errors are announced by [TranslateErrorView].
///
/// A translation of text the user has since edited is dimmed (and described
/// as out of date to screen readers) and offers no AI extras. Selecting part
/// of a finished translation offers "Alternatives" for that part when an AI
/// engine is available (see [showSpanAlternativesSheet]).
///
/// "Show matching phrases" loads the phrase alignment of the input and the
/// translation (`TranslateCubit.loadAlignment`); tapping or hovering a
/// phrase of the translation then highlights it and focuses its pair
/// (`TranslateCubit.focusAlignment`) so the input can highlight the
/// matching source phrase. Insights and alignment are shown one at a time.
/// Both stay on across translations (they reload once the next one is
/// complete), and so does a romanization the user asked for, as long as
/// that costs nothing (the assist engine runs locally, or Mozhi delivered
/// the romanization) or the user asked for the translation. After an
/// instant translation, or the automatic translation of a link or shared
/// text (`TranslateState.instantResult`), they are turned off instead, so
/// neither typing nor text from outside the app starts paid AI requests;
/// the buttons load them again.
///
/// "Romanization ready" and the alignment hint are announced for the load
/// the user asked for, not for the automatic reloads.
///
/// "Check meaning" starts a meaning check of the finished translation on
/// demand (`TranslateCubit.checkMeaning`, shown by [MeaningCheckPanel]);
/// pressed again it hides the check. The difference highlighted there
/// (`TranslateState.focusedMeaningIssue`) is highlighted in the
/// translation too, over the alignment and insights.
class OutputCard extends StatefulWidget {
  const new({this.meaningButtonFocusNode, super.key});

  /// Focus node of the "Check meaning" button, e.g. for
  /// [MeaningCheckPanel.returnFocusNode].
  final FocusNode? meaningButtonFocusNode;

  @override
  State<OutputCard> createState() => _OutputCardState();
}

class _OutputCardState extends State<OutputCard> {
  bool _showInsights = false;
  bool _showAlignment = false;

  /// Whether romanizations are shown: null follows
  /// `AppSettings.showTransliteration` until the user toggles them.
  bool? _romanize;

  /// The results the user turned the romanization / alignment on for: only
  /// their loads are announced (not the reloads for later results).
  TranslationResult? _romanizationAskedFor;
  TranslationResult? _alignmentAskedFor;

  /// Whether the AI extras of [state] may be reloaded without a user
  /// action: they cost nothing (a local assist engine), or the user asked
  /// for the translation (not an instant one, nor the automatic one of
  /// external text).
  static bool _mayReload(TranslateState state) =>
      !state.instantResult || (state.assistEngine?.isLocal ?? false);

  /// The same for the romanization, which is also free when the result
  /// has a transliteration of its own.
  static bool _mayReloadRomanization(TranslateState state) =>
      _mayReload(state) ||
      (state.result?.targetTransliteration.trim().isNotEmpty ?? false);

  void _toggleInsights(TranslateState state) {
    final cubit = context.read<TranslateCubit>();
    setState(() {
      _showInsights = !_showInsights;
      // One kind of highlight in the translation at a time.
      if (_showInsights) _showAlignment = false;
    });
    if (!_showInsights) return;
    if (state.alignmentFocus != null) cubit.focusAlignment(null);
    if (state.insightsStatus == ExtraStatus.idle ||
        state.insightsStatus == ExtraStatus.failure) {
      unawaited(cubit.loadInsights());
    }
  }

  void _toggleAlignment(TranslateState state) {
    final cubit = context.read<TranslateCubit>();
    setState(() {
      _showAlignment = !_showAlignment;
      if (_showAlignment) {
        _showInsights = false;
        _alignmentAskedFor = state.result;
      }
    });
    if (!_showAlignment) {
      if (state.alignmentFocus != null) cubit.focusAlignment(null);
      return;
    }
    if (state.alignmentStatus == ExtraStatus.idle ||
        state.alignmentStatus == ExtraStatus.failure) {
      unawaited(cubit.loadAlignment());
    }
  }

  void _toggleRomanization(TranslateState state, {required bool shown}) {
    setState(() {
      _romanize = !shown;
      if (!shown) _romanizationAskedFor = state.result;
    });
    if (!shown &&
        romanizationOf(state) == null &&
        (state.romanizationStatus == ExtraStatus.idle ||
            state.romanizationStatus == ExtraStatus.failure)) {
      unawaited(context.read<TranslateCubit>().loadRomanization());
    }
  }

  /// Whether the romanization (or its progress or error) is on screen.
  bool _romanizationShown(TranslateState state, AppSettings settings) =>
      (_romanize ?? settings.showTransliteration) &&
      (romanizationOf(state) != null ||
          state.romanizationStatus == ExtraStatus.loading ||
          state.romanizationStatus == ExtraStatus.failure);

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
          // The text the shown translation was made for (the input may
          // have been edited since).
          text: (state.resultInput ?? state.input).trim(),
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
    return MultiBlocListener(
      listeners: [
        BlocListener<TranslateCubit, TranslateState>(
          // Keep insights on across translations: reload once the next one
          // is complete.
          listenWhen: (previous, current) =>
              _showInsights &&
              current.status == TranslateStatus.success &&
              current.insightsStatus == ExtraStatus.idle &&
              current.hasExtras &&
              (previous.status != current.status ||
                  previous.insightsStatus != current.insightsStatus),
          listener: (context, state) {
            if (_mayReload(state)) {
              unawaited(context.read<TranslateCubit>().loadInsights());
            } else {
              setState(() => _showInsights = false);
            }
          },
        ),
        BlocListener<TranslateCubit, TranslateState>(
          // The same for the alignment.
          listenWhen: (previous, current) =>
              _showAlignment &&
              current.canAlign &&
              current.alignmentStatus == ExtraStatus.idle &&
              (previous.status != current.status ||
                  previous.result != current.result ||
                  previous.alignmentStatus != current.alignmentStatus),
          listener: (context, state) {
            if (_mayReload(state)) {
              unawaited(context.read<TranslateCubit>().loadAlignment());
              return;
            }
            final cubit = context.read<TranslateCubit>();
            setState(() => _showAlignment = false);
            if (state.alignmentFocus != null) cubit.focusAlignment(null);
          },
        ),
        BlocListener<TranslateCubit, TranslateState>(
          // And for a romanization the user asked for.
          listenWhen: (previous, current) =>
              (_romanize ?? false) &&
              current.canRomanize &&
              current.romanizationStatus == ExtraStatus.idle &&
              (previous.status != current.status ||
                  previous.result != current.result ||
                  previous.romanizationStatus != current.romanizationStatus),
          listener: (context, state) {
            if (_mayReloadRomanization(state)) {
              unawaited(context.read<TranslateCubit>().loadRomanization());
            } else {
              // Back to the setting (free romanizations only).
              setState(() => _romanize = null);
            }
          },
        ),
      ],
      child: BlocBuilder<TranslateCubit, TranslateState>(
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
              color: TranslateLayout.outputSurface(theme.colorScheme),
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
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      TranslateLayout.cardPadding,
                      13,
                      8,
                      8,
                    ),
                    child: _content(context, state),
                  ),
                ],
              ),
            ),
          );
        },
      ),
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
      if (state.status != TranslateStatus.translating) {
        return EmptyOutput(state: state);
      }
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 96),
        child: Padding(
          padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
          child: Text(
            l10n.translateTranslating,
            style: TranslateLayout.outputTextStyle(
              context,
              0,
            )?.copyWith(color: muted),
          ),
        ),
      );
    }

    final settings = context.watch<SettingsCubit>().state;
    final style = TranslateLayout.outputTextStyle(context, output.length);
    final complete = result?.isComplete ?? true;
    final insightsReady =
        _showInsights &&
        state.insightsStatus == ExtraStatus.ready &&
        state.insights.isNotEmpty &&
        complete;
    final stale = state.isResultStale;
    final alignmentReady =
        _showAlignment &&
        state.alignmentStatus == ExtraStatus.ready &&
        state.alignment.isNotEmpty &&
        complete &&
        !stale;
    final detected = result?.detectedSource;
    final elapsed = result?.elapsed;
    final direction = outputTextDirection(state);
    final locale = localeForLanguage(state.target);
    final offline = result != null && isOfflineEngineId(result.engineId);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final meaningHighlight = outputMeaningHighlight(state);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
          // A named container; completion is announced separately (a live
          // region here would fire on every streamed token or not at all).
          child: Semantics(
            key: const Key('translate_output_semantics'),
            container: true,
            label: l10n.translateOutputLabel,
            // Out of date until the edited text is translated (a running
            // translation shows its own progress).
            hint: stale && state.status != TranslateStatus.translating
                ? l10n.translateResultStaleHint
                : null,
            child: AnimatedOpacity(
              key: const Key('translate_output_opacity'),
              opacity: stale ? staleOutputOpacity : 1,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 150),
              child: SizedBox(
                width: double.infinity,
                child: meaningHighlight != null
                    ? SelectableText.rich(
                        highlightedTextSpan(
                          output,
                          meaningHighlight,
                          theme.colorScheme,
                          locale: locale,
                        ),
                        key: const Key('translate_output_text'),
                        style: style,
                        textDirection: direction,
                        contextMenuBuilder: (context, editable) =>
                            _contextMenu(context, editable, state),
                      )
                    : alignmentReady
                    ? AlignedText(
                        text: output,
                        alignment: state.alignment,
                        focus: state.alignmentFocus,
                        onFocus: context.read<TranslateCubit>().focusAlignment,
                        other: state.input,
                        style: style,
                        textDirection: direction,
                        locale: locale,
                      )
                    : insightsReady
                    ? InsightText(
                        text: output,
                        insights: state.insights,
                        source: state.resultInput ?? state.input,
                        style: style,
                        textDirection: direction,
                        locale: locale,
                        onTapAt: (insight, offset) => unawaited(
                          showInsightSheet(context, insight, offset: offset),
                        ),
                      )
                    : SelectableText.rich(
                        TextSpan(text: output, locale: locale),
                        key: const Key('translate_output_text'),
                        style: style,
                        textDirection: direction,
                        contextMenuBuilder: (context, editable) =>
                            _contextMenu(context, editable, state),
                      ),
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
        if (_romanize ?? settings.showTransliteration)
          RomanizationLine(
            key: const ValueKey('translate_romanization'),
            state: state,
            announce:
                (_romanize ?? false) &&
                result != null &&
                result == _romanizationAskedFor,
          ),
        if (_showInsights && state.hasExtras) _insightsStatus(context, state),
        if (_showAlignment && state.hasExtras) _alignmentStatus(context, state),
        if (complete && result != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 12, end: 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (detected != null && state.source.isAuto)
                  DetectedLanguageChips(state: state),
                if (offline) const OfflineEngineBadge(),
                if (state.resultFromMemory) const MemoryResultBadge(),
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

  /// Whether alternatives can be requested for a part of the translation.
  static bool _offersSpanAlternatives(TranslateState state) =>
      state.hasExtras &&
      state.status == TranslateStatus.success &&
      (state.result?.isComplete ?? false) &&
      !state.isResultStale;

  /// The platform's selection toolbar plus "Alternatives" for the selected
  /// part of a finished translation.
  Widget _contextMenu(
    BuildContext context,
    EditableTextState editable,
    TranslateState state,
  ) {
    final value = editable.textEditingValue;
    final selection = value.selection;
    final items = [...editable.contextMenuButtonItems];
    if (_offersSpanAlternatives(state) &&
        selection.isValid &&
        !selection.isCollapsed &&
        selection.textInside(value.text).trim().isNotEmpty) {
      items.add(
        ContextMenuButtonItem(
          label: context.l10n.translateAlternatives,
          onPressed: () {
            editable.hideToolbar();
            _alternativesForSelection(value);
          },
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editable.contextMenuAnchors,
      buttonItems: items,
    );
  }

  /// Requests alternatives for the selected text (trimmed, with its offset
  /// in the output) and shows them in a sheet.
  void _alternativesForSelection(TextEditingValue value) {
    final selection = value.selection;
    final raw = selection.textInside(value.text);
    final span = raw.trim();
    if (span.isEmpty) return;
    final start = selection.start + raw.length - raw.trimLeft().length;
    unawaited(
      context.read<TranslateCubit>().loadAlternatives(
        span: span,
        spanStart: start,
      ),
    );
    unawaited(showSpanAlternativesSheet(context));
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

  Widget _alignmentStatus(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // Announced once, when the alignment the user asked for arrives (not
    // after every later translation).
    final live = state.result != null && state.result == _alignmentAskedFor;
    final child = switch (state.alignmentStatus) {
      ExtraStatus.loading => LinearProgressIndicator(
        key: const Key('translate_alignment_progress'),
        semanticsLabel: l10n.translateAlignmentLoading,
      ),
      ExtraStatus.failure => TranslateErrorView(
        key: const Key('translate_alignment_error'),
        error: state.alignmentError,
        dense: true,
        onRetry: () =>
            unawaited(context.read<TranslateCubit>().loadAlignment()),
      ),
      ExtraStatus.ready when state.alignment.isEmpty => Semantics(
        liveRegion: live,
        child: Text(
          l10n.translateAlignmentEmpty,
          key: const Key('translate_alignment_empty'),
          style: muted,
        ),
      ),
      ExtraStatus.ready => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: live,
            child: Text(
              l10n.translateAlignmentHint,
              key: const Key('translate_alignment_hint'),
              style: muted,
            ),
          ),
          // The phrases cannot be tapped without touch or a mouse.
          Text(
            l10n.translateAlignmentKeyboardHint,
            key: const Key('translate_alignment_keyboard_hint'),
            style: muted,
          ),
        ],
      ),
      ExtraStatus.idle => const SizedBox.shrink(),
    };
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 12, end: 12),
      child: child,
    );
  }

  /// "Check meaning" (on demand only), or "Hide meaning check" while a
  /// check is shown.
  Widget _meaningButton(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final shown = state.meaningStatus != ExtraStatus.idle;
    return TranslateToolChip(
      key: const Key('translate_meaning_button'),
      focusNode: widget.meaningButtonFocusNode,
      icon: Icons.fact_check_outlined,
      label: l10n.translateMeaningCheck,
      tooltip: shown
          ? l10n.translateMeaningCheckHide
          : l10n.translateMeaningCheck,
      selected: shown,
      onPressed: shown
          ? context.read<TranslateCubit>().clearMeaningCheck
          : state.canCheckMeaning
          ? () => unawaited(checkMeaningIn(context))
          : null,
    );
  }

  /// The everyday actions (copy, listen, favourite, and share at the end)
  /// as icon buttons, then the labelled tools ([_tools]).
  Widget _actions(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final output = state.output;
    final complete = state.result?.isComplete ?? true;
    final target = state.target;
    final tools = _tools(context, state);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('translate_copy_button'),
              tooltip: l10n.commonCopy,
              icon: const Icon(Icons.copy_outlined),
              onPressed: () => unawaited(copyToClipboard(context, output)),
            ),
            ListenButton(
              id: translateOutputSpeechId,
              text: output,
              languageCode: target.isCustom ? null : target.code,
            ),
            BlocBuilder<HistoryCubit, HistoryState>(
              builder: (context, history) {
                final entry = findHistoryEntry(
                  history.entries,
                  state.resultInput ?? state.input,
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
                  onPressed: complete
                      ? () => _toggleFavorite(state, entry)
                      : null,
                );
              },
            ),
            const Spacer(),
            Builder(
              builder: (buttonContext) => IconButton(
                key: const Key('translate_share_button'),
                tooltip: l10n.commonShare,
                icon: const Icon(Icons.share_outlined),
                onPressed: () => unawaited(_share(buttonContext, output)),
              ),
            ),
          ],
        ),
        if (tools.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 12, 4),
            child: Semantics(
              key: const Key('translate_output_tools'),
              container: true,
              explicitChildNodes: true,
              label: l10n.translateToolsLabel,
              child: Wrap(spacing: 8, runSpacing: 8, children: tools),
            ),
          ),
      ],
    );
  }

  /// The on/off tools for the translation: check meaning, insights (AI
  /// extras), romanization and matching phrases (alignment), each a
  /// labelled chip.
  List<Widget> _tools(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final complete = state.result?.isComplete ?? true;
    final romanizationShown = _romanizationShown(
      state,
      context.watch<SettingsCubit>().state,
    );
    return [
      _meaningButton(context, state),
      if (state.hasExtras)
        TranslateToolChip(
          key: const Key('translate_insights_button'),
          icon: Icons.lightbulb_outline,
          label: l10n.translateInsights,
          tooltip: _showInsights
              ? l10n.translateInsightsHide
              : l10n.translateInsights,
          selected: _showInsights,
          // No extras for a translation of text that has been edited.
          onPressed: complete && !state.isResultStale
              ? () => _toggleInsights(state)
              : null,
        ),
      if (complete && (romanizationShown || romanizationAvailable(state)))
        RomanizationButton(
          shown: romanizationShown,
          onPressed: () => _toggleRomanization(state, shown: romanizationShown),
        ),
      if (state.assistEngine?.supportsExtras ?? false)
        TranslateToolChip(
          key: const Key('translate_alignment_button'),
          icon: Icons.sync_alt,
          label: l10n.translateToolAlignment,
          tooltip: _showAlignment
              ? l10n.translateAlignmentHide
              : l10n.translateAlignmentShow,
          selected: _showAlignment,
          // Can always be turned off; turned on for a finished, current
          // translation.
          onPressed: _showAlignment || state.canAlign
              ? () => _toggleAlignment(state)
              : null,
        ),
    ];
  }
}
