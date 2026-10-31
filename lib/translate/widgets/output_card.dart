import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart' show AppLook;
import 'package:mozhi/core/haptics.dart';
import 'package:mozhi/core/on_device_ai_engine.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/offline.dart' show OfflineEngineBadge;
import 'package:mozhi/on_device_ai/view/on_device_ai_paused_notice.dart';
import 'package:mozhi/phrasebook/widgets/add_to_phrasebook.dart'
    show AddToPhrasebookButton, translationPhraseDraft;
import 'package:mozhi/phrasebook/widgets/phrasebook_labels.dart'
    show maybePhrasebookRepository;
import 'package:mozhi/platform/android_device.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/platform/device_conditions.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/speech/widgets/spoken_range_builder.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/aligned_text.dart';
import 'package:mozhi/translate/widgets/copy_action_button.dart';
import 'package:mozhi/translate/widgets/detection_chips.dart';
import 'package:mozhi/translate/widgets/extras_section.dart';
import 'package:mozhi/translate/widgets/first_use_hint.dart';
import 'package:mozhi/translate/widgets/insight_sheet.dart';
import 'package:mozhi/translate/widgets/instance_switcher.dart';
import 'package:mozhi/translate/widgets/language_bar.dart'
    show pickTranslateLanguage;
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';
import 'package:mozhi/translate/widgets/meaning_check_panel.dart';
import 'package:mozhi/translate/widgets/offline_offer.dart';
import 'package:mozhi/translate/widgets/offline_only_notice.dart';
import 'package:mozhi/translate/widgets/on_device_ai_loading.dart';
import 'package:mozhi/translate/widgets/romanization_line.dart';
import 'package:mozhi/translate/widgets/short_query_panel.dart';
import 'package:mozhi/translate/widgets/show_mode.dart';
import 'package:mozhi/translate/widgets/skeleton.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/terminal_chrome.dart';
import 'package:mozhi/translate/widgets/tool_chip.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:mozhi/translate/widgets/translate_more.dart';
import 'package:mozhi/translate/widgets/translation_memory_card.dart'
    show MemoryResultBadge;
import 'package:mozhi/translate/widgets/translation_notes.dart';
import 'package:mozhi/word_lookup/cubit/word_lookup_cubit.dart'
    show WordLookupCubit;
import 'package:mozhi/word_lookup/data/word_segmenter.dart';
import 'package:mozhi/word_lookup/view/word_lookup_sheet.dart'
    show lookUpWordAt, showWordLookupSheet;
import 'package:mozhi/word_lookup/widgets/word_tap_tracker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:translation_repository/translation_repository.dart';

export 'package:mozhi/translate/widgets/aligned_text.dart';
export 'package:mozhi/translate/widgets/detection_chips.dart';
export 'package:mozhi/translate/widgets/romanization_line.dart';

/// Whether a copy that its button confirms in place (a check mark,
/// [CopyActionButton]) still gets a "Copied" snack bar: only on Android
/// versions without a system confirmation of their own (Android 12 and
/// older); never on the web. Null follows the platform; tests set it.
@visibleForTesting
bool? debugSnackBarAfterInlineCopy;

/// Copies [text] (marked as sensitive, see [copyText]) and confirms with a
/// snackbar, unless the system confirms copies itself (Android 13+), or
/// [inlineConfirmation] says the caller confirms it in place and the
/// platform is not an older Android (see [copyAndConfirm]).
Future<void> copyToClipboard(
  BuildContext context,
  String text, {
  bool inlineConfirmation = false,
}) => copyAndConfirm(context, text, inlineConfirmation: inlineConfirmation);

/// [copyToClipboard], telling whether it showed the "Copied to clipboard"
/// snack bar: never when the system confirms copies itself (Android 13+);
/// with [inlineConfirmation] (a check mark in the button) only on Android
/// 12 and older, so not on the web.
Future<bool> copyAndConfirm(
  BuildContext context,
  String text, {
  bool inlineConfirmation = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final message = context.l10n.commonCopied;
  await copyText(text);
  if (systemShowsCopyConfirmation || messenger == null) return false;
  if (inlineConfirmation &&
      !(debugSnackBarAfterInlineCopy ?? (runsOnAndroid && !kIsWeb))) {
    return false;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
  return true;
}

/// Newest history entry for this exact text + translation (entries are
/// newest first). Dictionary look-ups ([HistoryEntry.isDictionary]) never
/// match: their `translation` is a summary of the entry, which may happen
/// to equal a translation.
HistoryEntry? findHistoryEntry(
  List<HistoryEntry> entries,
  String text,
  String translation,
) {
  final wanted = text.trim();
  for (final entry in entries) {
    if (!entry.isDictionary &&
        entry.text.trim() == wanted &&
        entry.translation == translation) {
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
/// button, which also reads it slowly on a long press).
const translateOutputSpeechId = 'target';

/// Direction of the translated text: the target language's, or (custom
/// targets) the direction of its characters.
TextDirection? outputTextDirection(TranslateState state) =>
    textDirectionForLanguage(state.target) ??
    textDirectionForText(state.output);

/// The other side of [state]'s translation, for the word card of a word of
/// the translation: the source language, the detected one with "Detect
/// language" (when the catalogue knows it); null for a custom language or
/// while undetected.
Language? wordLookupInto(TranslateState state) {
  final source = state.source;
  if (source.isCustom) return null;
  if (!source.isAuto) return source;
  final detected = state.result?.detectedSource?.trim() ?? '';
  return detected.isEmpty ? null : LanguageCatalog.byCode(detected);
}

/// Whether the engine's languages could not be loaded (e.g. offline first
/// has not loaded the lists of this server yet): the output shows the
/// error with Retry.
bool showsTranslateEngineError(TranslateState state) =>
    state.enginesStatus == EnginesStatus.failure &&
    state.error != null &&
    state.status == TranslateStatus.idle &&
    state.output.isEmpty;

/// Whether the output has nothing to show for [state]: no translation (nor
/// one queued or in progress, `TranslateState.isPending`), no consent
/// prompt and no error.
bool translateOutputIsEmpty(TranslateState state) =>
    state.output.isEmpty &&
    !state.isPending &&
    state.status != TranslateStatus.failure &&
    state.consent == null &&
    !showsTranslateEngineError(state);

/// Whether the output shows a translation it is about to replace: one is
/// queued or running (`TranslateState.isPending`) and the shown one is
/// finished (an earlier result, not the new one streaming in). It stays,
/// dimmed, until the new text arrives.
bool outputIsRefreshing(TranslateState state) =>
    state.isPending &&
    state.output.isNotEmpty &&
    (state.result?.isComplete ?? false);

/// Whether the translation is streaming in: text has arrived, the rest is
/// still on its way.
bool outputIsStreaming(TranslateState state) =>
    state.status == TranslateStatus.translating &&
    state.output.isNotEmpty &&
    !(state.result?.isComplete ?? true);

/// The translation: header, the text on a raised surface (the hero of the
/// screen), progress, errors, romanization, the checks' findings, the
/// everyday actions and, for AI engines, the refinement chips; for short
/// inputs what the engine returned about the words ([ShortQueryPanel]);
/// behind the "Tools" toggle ([TranslateMoreToggle]) the analysis tools as
/// rows ([TranslateToolRow]: check meaning, insights, romanization,
/// matching phrases, compare engines). The toggle's state is the
/// [TranslateMoreScope]'s above (shared with the sections under the card),
/// else the card's own; it starts closed. Without a translation it shows
/// nothing ([translateOutputIsEmpty]; the empty screen shows the greeting
/// instead, `TranslateHero`).
///
/// **Header:** the target language in bold, then " · engine" (" · 0.7 s"
/// once complete), where the text went ([DestinationChip]; a placeholder of
/// its size while the first text is awaited, so nothing moves when it
/// arrives) and a tag per applied refinement ("More formal ×", the × undoes
/// it).
///
/// **Instant and still:** as soon as a translation is queued or running
/// (`TranslateState.isPending`) without text yet, the header and three
/// placeholder lines show (no extra delay); while on-device AI loads its
/// model they say so, with Cancel ([OnDeviceAiLoadingNotice]). While a new
/// translation of the same input runs, the previous one stays, dimmed
/// ([outputIsRefreshing]; a thin bar shows once it takes
/// [loadingRevealDelay]). The actions keep their place while text streams
/// in (hidden until it is complete, then they fade in over 150 ms and, on
/// Android, a light haptic tick says it is done when the haptic feedback
/// setting is on). What only a finished
/// translation has (the checks' findings, other likely source languages,
/// refinement chips, the short-input panel) comes under the actions. The
/// detected language is in the language bar, not repeated here. A new
/// result, the empty state, an error or a consent prompt replace one
/// another with a fade through ([FadeThroughSwitcher]).
///
/// **Refinements:** after a refinement (or undoing one) the changed words
/// light up and fade out over [refinementFlash] ([changedWordRanges]; held
/// without the fade with reduced motion), and the translation scrolls into
/// view when its start is off screen.
///
/// **On-device engine:** sentences it is unsure about
/// (`TranslateState.lowConfidenceSentences`) get a dotted underline (a
/// tooltip on hover or tap says so), and a note under the text counts them
/// and offers "Compare with another engine" (compare mode, run at once).
///
/// **Copy** morphs into a check mark and is announced politely
/// ([CopyActionButton]); "Show full screen" opens [ShowModeView].
///
/// **Screen readers:** the text is a container named "Translation"; on the
/// web ([webSemantics]) the text is its read-only value and the selectable
/// text is left out of the semantics tree (the web renders it as an empty
/// field otherwise). A finished translation is announced once (never per
/// streamed token); errors are announced by [TranslateErrorView].
///
/// While the privacy settings hold a translation back
/// (`TranslateState.consent`), the inline prompt is followed by the
/// on-device alternative when the offline engine supports the pair
/// ([OfflinePairOffer]: "Download German (25 MB)"); when "Offline only"
/// held it back and the device has nothing to translate with either, an
/// [OfflineOnlyNotice] says so instead. When the on-device engine tried
/// first and lacks the language (`ConsentRequest.fromOnDevice`), the offer
/// is for the language it recognised, and the first-use hint
/// ([TranslateFirstUseHint]) says what Download and Once do. A Mozhi
/// instance error offers "Switch instance" ([switchInstanceAndRetry]) when
/// several instances are configured.
///
/// A translation of text the user has since edited is dimmed (and described
/// as out of date to screen readers) and offers no AI extras. Selecting part
/// of a finished translation offers "Alternatives" for that part when an AI
/// engine is available (see [showSpanAlternativesSheet]).
///
/// "Matching phrases" loads the phrase alignment of the input and the
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
/// the rows load them again.
///
/// "Romanization ready" and the alignment hint are announced for the load
/// the user asked for, not for the automatic reloads.
///
/// "Check meaning" starts a meaning check of the finished translation on
/// demand (`TranslateCubit.checkMeaning`, shown by [MeaningCheckPanel]);
/// pressed again it hides the check. The difference highlighted there
/// (`TranslateState.focusedMeaningIssue`) is highlighted in the
/// translation too, over the alignment and insights.
///
/// **Tap a word** (`AppSettings.tapToLookUp`): a tap on a word of a
/// finished translation opens its word card ([lookUpWordAt]: the offline
/// dictionaries first), while no other highlight mode (alignment,
/// insights, a meaning check difference) is on; selecting, copying and
/// the long press work as before ([WordTapTracker]), and "Look up" in the
/// selection toolbar opens the card of a selected word or two (for
/// keyboards and screen readers). **The word being
/// read** (`AppSettings.highlightSpokenWord`): while Listen reads the
/// translation with a voice that reports its progress, the word it reads
/// is highlighted ([SpokenRangeBuilder]; not while text is selected).
class OutputCard extends StatefulWidget {
  const new({
    this.meaningButtonFocusNode,
    this.webSemantics = kIsWeb,
    super.key,
  });

  /// How long the changed words of a refinement stay highlighted.
  static const refinementFlash = Duration(milliseconds: 1500);

  /// Focus node of the "Check meaning" row, e.g. for
  /// [MeaningCheckPanel.returnFocusNode].
  final FocusNode? meaningButtonFocusNode;

  /// Whether the text is exposed for the web's semantics tree: as the
  /// read-only value of the "Translation" container, with the selectable
  /// text left out (true on the web).
  final bool webSemantics;

  @override
  State<OutputCard> createState() => _OutputCardState();
}

class _OutputCardState extends State<OutputCard>
    with SingleTickerProviderStateMixin {
  bool _showInsights = false;

  /// The "More" state when no [TranslateMoreScope] is above.
  TranslateMoreController? _ownMore;

  /// The card's content (outside the fade between its states), to scroll
  /// the translation into view after a refinement.
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'translate_output');

  /// The words a refinement changed ([OutputCard.refinementFlash]), in the
  /// text [_flashText].
  List<TextRange> _flash = const [];
  String? _flashText;
  late final AnimationController _flashFade = AnimationController(
    vsync: this,
    duration: OutputCard.refinementFlash,
  )..addStatusListener(_onFlashStatus);

  TranslateMoreController _more(BuildContext context) =>
      TranslateMoreScope.maybeOf(context) ??
      (_ownMore ??= TranslateMoreController());

  @override
  void dispose() {
    _ownMore?.dispose();
    _flashFade.dispose();
    super.dispose();
  }

  bool _showAlignment = false;

  /// Whether romanizations are shown: null follows
  /// `AppSettings.showTransliteration` until the user toggles them.
  bool? _romanize;

  /// The results the user turned the romanization / alignment on for: only
  /// their loads are announced (not the reloads for later results).
  TranslationResult? _romanizationAskedFor;
  TranslationResult? _alignmentAskedFor;

  /// Whether the AI extras of [state] may be reloaded without a user
  /// action: they cost nothing (a local assist engine, but not on-device
  /// AI while the phone is hot or saving battery: [DeviceConditions]), or
  /// the user asked for the translation (not an instant one, nor the
  /// automatic one of external text).
  static bool _mayReload(TranslateState state) {
    if (!state.instantResult) return true;
    final assist = state.assistEngine;
    if (assist == null || !assist.isLocal) return false;
    return !isOnDeviceAiEngine(assist) ||
        DeviceConditions.instance.latest.strain == null;
  }

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
    Haptics.light(context);
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

  // Refinement feedback -----------------------------------------------------

  /// Whether [current] is [previous]'s translation after a refinement was
  /// applied or undone: same input, another output.
  static bool _refined(TranslateState previous, TranslateState current) =>
      !listEquals(previous.appliedRefinements, current.appliedRefinements) &&
      current.status == TranslateStatus.success &&
      current.input == previous.input &&
      previous.output.isNotEmpty &&
      current.output.isNotEmpty &&
      previous.output != current.output;

  /// The output before the refinement [_refined] noticed last.
  String _refinedFrom = '';

  void _onRefined(TranslateState current) {
    final ranges = changedWordRanges(_refinedFrom, current.output);
    setState(() {
      _flash = ranges;
      _flashText = current.output;
    });
    if (ranges.isNotEmpty) _flashFade.forward(from: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealText());
  }

  void _onFlashStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _flash = const []);
    }
  }

  /// Scrolls the translation into view when its start is above the
  /// viewport (the refinement chips are under it).
  void _revealText() {
    final textContext = _contentKey.currentContext;
    if (!mounted || textContext == null) return;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    Scrollable.ensureVisible(
      textContext,
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
  }

  /// The highlight of the changed words at this point of the fade: held
  /// for a while, then fading out (held all along with reduced motion).
  double _flashStrength(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final t = _flashFade.value;
    if (reduceMotion || t < 0.4) return 1;
    return 1 - Curves.easeOut.transform((t - 0.4) / 0.6);
  }

  // Low confidence ----------------------------------------------------------

  void _compareWithAnotherEngine() {
    final cubit = context.read<TranslateCubit>()..setCompareMode(enabled: true);
    if (!cubit.state.comparing) unawaited(cubit.runCompare());
  }

  /// A light tick when a streamed translation is complete (Android only,
  /// and only with the haptic feedback setting on).
  static bool _settled(TranslateState previous, TranslateState current) =>
      outputIsStreaming(previous) &&
      current.status == TranslateStatus.success &&
      (current.result?.isComplete ?? false);

  @override
  Widget build(BuildContext context) {
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
        BlocListener<TranslateCubit, TranslateState>(
          // Show what a refinement changed.
          listenWhen: (previous, current) {
            if (!_refined(previous, current)) return false;
            _refinedFrom = previous.output;
            return true;
          },
          listener: (context, state) => _onRefined(state),
        ),
        BlocListener<TranslateCubit, TranslateState>(
          listenWhen: _settled,
          listener: (context, state) {
            if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
              Haptics.selection(context);
            }
          },
        ),
      ],
      child: BlocBuilder<TranslateCubit, TranslateState>(
        builder: (context, state) {
          final refreshing = outputIsRefreshing(state);
          final (announcement, announcementDirection) = _announcement(
            context,
            state,
          );
          return StatusAnnouncer(
            message: announcement,
            textDirection: announcementDirection,
            child: TranslateFlatCard(
              key: const Key('translate_output_card'),
              look: TranslateCardLook.plain,
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 2,
                    // A new translation of a shown one, once it takes a
                    // while (the placeholder lines show progress without
                    // a translation).
                    child: refreshing
                        ? DelayedReveal(
                            child: LinearProgressIndicator(
                              key: const Key('translate_output_progress'),
                              minHeight: 2,
                              borderRadius: BorderRadius.all(
                                Radius.circular(
                                  AppLook.of(context).controlRadius(1),
                                ),
                              ),
                              semanticsLabel: context.l10n.translateTranslating,
                            ),
                          )
                        : null,
                  ),
                  // A refinement (or another new translation of the shown
                  // one) that waits for the on-device model says so, and
                  // so does a long text that waits between its parts
                  // while the phone is hot or saving battery.
                  if (state.isPending &&
                      state.output.isNotEmpty &&
                      _onDeviceAi(state))
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        TranslateLayout.cardPadding,
                        8,
                        12,
                        0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (refreshing) const OnDeviceAiLoadingNotice(),
                          OnDeviceAiPausedNotice(
                            onCancel: context
                                .read<TranslateCubit>()
                                .stopTranslation,
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    key: _contentKey,
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      TranslateLayout.cardPadding,
                      6,
                      0,
                      0,
                    ),
                    child: FadeThroughSwitcher(
                      child: KeyedSubtree(
                        key: _phaseKey(state),
                        child: _content(context, state),
                      ),
                    ),
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

  /// What the card shows, as told apart by [FadeThroughSwitcher]: the
  /// consent prompt, an error, the empty state, progress, or the result
  /// (one key per input, target and engine, so a translation streaming in
  /// keeps its key).
  Key _phaseKey(TranslateState state) {
    final output = state.output;
    if (state.consent != null && output.isEmpty) {
      return const ValueKey('translate_phase_consent');
    }
    if (showsTranslateEngineError(state)) {
      return const ValueKey('translate_phase_engine_error');
    }
    if (state.status == TranslateStatus.failure && output.isEmpty) {
      return const ValueKey('translate_phase_failure');
    }
    if (output.isEmpty) {
      return state.isPending
          ? const ValueKey('translate_phase_loading')
          : const ValueKey('translate_phase_empty');
    }
    return ValueKey((
      'translate_phase_result',
      state.resultInput ?? state.input,
      state.target,
      state.result?.engineId,
    ));
  }

  /// "Switch instance" for Mozhi errors when there is another instance.
  VoidCallback? _switchInstance(BuildContext context) {
    final instances = context.read<SettingsCubit>().state.instances;
    if (instances.length < 2) return null;
    return () => unawaited(switchInstanceAndRetry(context));
  }

  /// [child] on the raised surface that makes the translation the hero of
  /// the screen.
  ///
  /// In the terminal look the `stdout` box around the card is that
  /// surface: the text sits in it directly.
  Widget _surface(BuildContext context, Widget child) {
    final look = AppLook.of(context);
    if (look.isTerminal) {
      return KeyedSubtree(
        key: const Key('translate_output_surface'),
        child: child,
      );
    }
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 12),
      child: DecoratedBox(
        key: const Key('translate_output_surface'),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          borderRadius: look.cardRadius,
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 14),
          child: child,
        ),
      ),
    );
  }

  Widget _content(BuildContext context, TranslateState state) {
    final output = state.output;
    final result = state.result;

    final consent = state.consent;
    if (consent != null && output.isEmpty) {
      // Never a dialog by itself: an instant translation shows this inline
      // prompt (a translation the user asked for also opens the dialog).
      final prompt = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConsentInlinePrompt(
            key: const Key('translate_consent_prompt'),
            consent: consent.exception,
            onGranted: () {
              if (consent.fromOnDevice) {
                unawaited(TranslateFirstUseHint.markSeen(context));
              }
              unawaited(context.read<TranslateCubit>().retryAfterConsent());
            },
          ),
          // The device tried first: offer the language it recognised (the
          // stopped request's own pair may say "Detect language").
          if (consent.fromOnDevice)
            OfflinePairOffer.pair(
              source: consent.onDeviceSource ?? consent.exception.source,
              target: consent.exception.target ?? state.target.code,
            )
          else
            OfflinePairOffer(consent: consent.exception),
          if (consent.fromOnDevice)
            TranslateFirstUseHint(consent: consent.exception),
        ],
      );
      return Padding(
        padding: const EdgeInsetsDirectional.only(top: 8, end: 12, bottom: 8),
        // "Offline only" with nothing on the device to translate with: say
        // that instead of "this engine needs the network".
        child: consent.exception.kind == ConsentKind.offlineOnly
            ? OfflineOnlyNotice(consent: consent.exception, fallback: prompt)
            : prompt,
      );
    }

    if (showsTranslateEngineError(state)) {
      // The engine's languages could not be loaded (e.g. offline first has
      // not loaded the lists of this server yet).
      return Padding(
        padding: const EdgeInsetsDirectional.only(top: 8, end: 12, bottom: 8),
        child: TranslateErrorView(
          key: const Key('translate_engine_error'),
          error: state.error,
          onRetry: () =>
              unawaited(context.read<TranslateCubit>().loadEngines()),
          onSwitchInstance: _switchInstance(context),
        ),
      );
    }

    if (state.status == TranslateStatus.failure && output.isEmpty) {
      final cubit = context.read<TranslateCubit>();
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: 12, bottom: 8),
        child: TranslateErrorView(
          error: state.error,
          onRetry: () => unawaited(cubit.translate()),
          onSwitchInstance: _switchInstance(context),
          // The engine could not detect the language (e.g. a short text on
          // the offline engine): pick it, or take the last one used.
          onChooseSourceLanguage: () =>
              unawaited(pickTranslateLanguage(context, source: true)),
          suggestedSourceLanguage: state.recentSourceSuggestion(
            context.read<SettingsCubit>().state.recentPairs,
          ),
          onUseSourceLanguage: cubit.setSource,
        ),
      );
    }

    if (output.isEmpty) {
      if (!state.isPending) {
        return const SizedBox(
          key: Key('translate_empty_output'),
          width: double.infinity,
        );
      }
      // Queued or running without text yet: the header and placeholder
      // lines at once, with the actions' room kept, so nothing moves when
      // the text arrives.
      final skeleton = TranslateOutputSkeleton(
        label: context.l10n.translateTranslating,
      );
      final engine = state.engine;
      final onDeviceAi = engine != null && isOnDeviceAiEngine(engine);
      return Column(
        key: const Key('translate_output_loading'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context, state, loading: true),
          const SizedBox(height: 8),
          _surface(
            context,
            // The first request after a pause loads the model.
            onDeviceAi
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [const OnDeviceAiLoadingNotice(), skeleton],
                  )
                : skeleton,
          ),
          const SizedBox(height: 4 + 48),
        ],
      );
    }

    final settings = context.watch<SettingsCubit>().state;
    final complete = result?.isComplete ?? true;
    final detected = result?.detectedSource;
    final offline = result != null && isOfflineEngineId(result.engineId);
    final insightsReady =
        _showInsights &&
        state.insightsStatus == ExtraStatus.ready &&
        state.insights.isNotEmpty &&
        complete;
    final uncertain = state.lowConfidenceSentences;
    final streaming = outputIsStreaming(state);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final uncertainDetection =
        complete &&
        detected != null &&
        state.source.isAuto &&
        detectionLooksUncertain(state) &&
        state.detectedAlternativeLanguages.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, state),
        const SizedBox(height: 8),
        _surface(
          context,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _text(context, state, settings),
              if (insightsReady)
                InsightChips(
                  insights: state.insights,
                  locale: localeForLanguage(state.target),
                  textDirection: outputTextDirection(state),
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
              if (_showInsights && state.hasExtras)
                _insightsStatus(context, state),
              if (_showAlignment && state.hasExtras)
                _alignmentStatus(context, state),
              if (uncertain.isNotEmpty)
                _uncertainNote(context, state, uncertain.length),
            ],
          ),
        ),
        // The translation stopped part way: what arrived stays, with the
        // error and Retry.
        if (state.status == TranslateStatus.failure)
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
            child: TranslateErrorView(
              key: const Key('translate_partial_error'),
              error: state.error,
              dense: true,
              onRetry: () =>
                  unawaited(context.read<TranslateCubit>().translate()),
            ),
          ),
        // Known from the first text on, so they never move the actions.
        if (offline || state.resultFromMemory)
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
            child: Wrap(
              key: const Key('translate_output_badges'),
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (offline) const OfflineEngineBadge(),
                if (state.resultFromMemory) const MemoryResultBadge(),
              ],
            ),
          ),
        const SizedBox(height: 4),
        // Kept in place while the text streams in, faded in once it is
        // complete.
        IgnorePointer(
          ignoring: streaming,
          child: ExcludeSemantics(
            excluding: streaming,
            child: AnimatedOpacity(
              key: const Key('translate_output_actions_fade'),
              opacity: streaming ? 0 : 1,
              duration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 150),
              child: _actions(context, state),
            ),
          ),
        ),
        // What only a finished translation has: under the actions, so it
        // never moves them.
        if (TranslationNotes.hasNotes(state))
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: TranslationNotes(state: state),
          ),
        if (uncertainDetection)
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
            child: DetectedLanguageChips(state: state),
          ),
        if (_showsRefinements(state)) _refinements(context, state),
        ShortQueryPanel(state: state),
        _tools(context, state),
      ],
    );
  }

  /// The translation's header line, like a reply's: the target language in
  /// bold, then " · engine" (" · 0.7 s" once complete) in the secondary
  /// colour, where the text went and the applied refinements. [loading]
  /// keeps the place of the destination while the first text is awaited.
  Widget _header(
    BuildContext context,
    TranslateState state, {
    bool loading = false,
  }) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    final result = state.result;
    final complete = result?.isComplete ?? false;
    final elapsed = result?.elapsed;
    final meta = theme.textTheme.bodyMedium?.copyWith(color: muted);
    final engineName = loading
        ? state.engine?.name
        : result?.engineName ?? state.engine?.name;
    final destination = loading ? null : result?.destination;
    final refinements = state.isResultStale || loading
        ? const <AppliedRefinement>[]
        : state.appliedRefinements;
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 8, end: 12),
      child: Wrap(
        key: const Key('translate_output_header'),
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            state.target.name,
            key: const Key('translate_output_language'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (engineName != null && engineName.isNotEmpty) ...[
            ExcludeSemantics(child: Text(' · ', style: meta)),
            Text(
              complete && elapsed != null && result != null
                  ? l10n.translateEngineElapsed(
                      result.engineName,
                      formatSeconds(elapsed),
                    )
                  : engineName,
              key: const Key('translate_output_footer'),
              style: meta,
            ),
          ],
          if (destination != null) ...[
            const SizedBox(width: 8),
            DestinationChip(
              key: const Key('translate_output_destination'),
              destination: destination,
              engineId: result?.engineId,
            ),
          ] else if (loading && state.engine != null) ...[
            // The destination chip's room (it comes with the first text).
            const SizedBox(width: 8),
            const ExcludeSemantics(
              child: SizedBox(
                key: Key('translate_output_destination_placeholder'),
                height: 48,
                child: Center(
                  widthFactor: 1,
                  child: SkeletonBox(height: 26, width: 132, radius: 13),
                ),
              ),
            ),
          ],
          for (final (index, applied) in refinements.indexed) ...[
            const SizedBox(width: 8),
            _RefinementTag(
              key: ValueKey('translate_refinement_tag:$index'),
              suggestion: applied.suggestion,
            ),
          ],
        ],
      ),
    );
  }

  /// The translation's text, in the highlight mode that applies: a meaning
  /// check difference, the alignment, insights, or the plain text (with the
  /// changed words of a refinement and the unsure sentences); in the
  /// "Translation" container, dimmed while out of date or being replaced.
  Widget _text(
    BuildContext context,
    TranslateState state,
    AppSettings settings,
  ) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final output = state.output;
    final complete = state.result?.isComplete ?? true;
    final style = TranslateLayout.outputTextStyle(
      context,
      output.length,
    )?.copyWith(fontWeight: FontWeight.w500);
    final stale = state.isResultStale;
    final dimmed = stale || outputIsRefreshing(state);
    final alignmentReady =
        _showAlignment &&
        state.alignmentStatus == ExtraStatus.ready &&
        state.alignment.isNotEmpty &&
        complete &&
        !stale;
    final insightsReady =
        _showInsights &&
        state.insightsStatus == ExtraStatus.ready &&
        state.insights.isNotEmpty &&
        complete;
    final direction = outputTextDirection(state);
    final locale = localeForLanguage(state.target);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final meaningHighlight = outputMeaningHighlight(state);

    Widget text;
    if (meaningHighlight != null) {
      text = SelectableText.rich(
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
      );
    } else if (alignmentReady) {
      text = AlignedText(
        text: output,
        alignment: state.alignment,
        focus: state.alignmentFocus,
        onFocus: context.read<TranslateCubit>().focusAlignment,
        other: state.input,
        style: style,
        textDirection: direction,
        locale: locale,
      );
    } else if (insightsReady) {
      text = InsightText(
        text: output,
        insights: state.insights,
        source: state.resultInput ?? state.input,
        style: style,
        textDirection: direction,
        locale: locale,
        onTapAt: (insight, offset) =>
            unawaited(showInsightSheet(context, insight, offset: offset)),
      );
    } else {
      final tapToLookUp =
          settings.tapToLookUp &&
          !_showAlignment &&
          !_showInsights &&
          complete &&
          !state.target.isCustom &&
          !state.target.isAuto &&
          output.trim().isNotEmpty;
      text = SpokenRangeBuilder(
        id: translateOutputSpeechId,
        text: output,
        enabled: settings.highlightSpokenWord,
        builder: (context, spoken) => _plainText(
          context,
          state,
          style,
          direction,
          locale,
          spoken: spoken,
          onWordTap: tapToLookUp
              ? (offset) => unawaited(_lookUpWord(state, offset))
              : null,
        ),
      );
    }

    // On the web the text is the container's value: the selectable text
    // would be an empty, disabled field there.
    final web = widget.webSemantics;
    if (web) text = ExcludeSemantics(child: text);
    final hint = stale && !state.isPending
        ? l10n.translateResultStaleHint
        : null;
    return Semantics(
      key: const Key('translate_output_semantics'),
      // A named container; completion is announced separately (a live
      // region here would fire on every streamed token or not at all).
      container: true,
      label: l10n.translateOutputLabel,
      attributedValue: web
          ? AttributedString(
              output,
              attributes: [
                if (locale != null)
                  LocaleStringAttribute(
                    range: TextRange(start: 0, end: output.length),
                    locale: locale,
                  ),
              ],
            )
          : null,
      readOnly: web ? true : null,
      textDirection: direction,
      // Out of date until the edited text is translated (a running
      // translation shows its own progress).
      hint: hint,
      child: AnimatedOpacity(
        key: const Key('translate_output_opacity'),
        opacity: dimmed ? staleOutputOpacity : 1,
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 150),
        child: SizedBox(width: double.infinity, child: text),
      ),
    );
  }

  /// Whether a word card is being opened ([_lookUpWord]).
  bool _lookingUpWord = false;

  /// Opens the word card for the word of [state]'s translation at
  /// [offset], unless one is being opened.
  Future<void> _lookUpWord(TranslateState state, int offset) async {
    if (_lookingUpWord) return;
    _lookingUpWord = true;
    try {
      await lookUpWordAt(
        context,
        text: state.output,
        offset: offset,
        language: state.target,
        into: wordLookupInto(state),
      );
    } finally {
      _lookingUpWord = false;
    }
  }

  /// The plain translation ([_PlainOutputText]): the changed words of a
  /// refinement lit up (fading), the sentences the on-device engine is
  /// unsure about with a dotted underline and a tooltip, the [spoken] word
  /// highlighted; a tap on a word calls [onWordTap] with its offset.
  Widget _plainText(
    BuildContext context,
    TranslateState state,
    TextStyle? style,
    TextDirection? direction,
    Locale? locale, {
    TextRange? spoken,
    ValueChanged<int>? onWordTap,
  }) {
    final output = state.output;
    final flash = _flashText == output ? _flash : const <TextRange>[];
    return _PlainOutputText(
      text: output,
      style: style,
      textDirection: direction,
      locale: locale,
      flash: flash,
      flashStrength: flash.isEmpty ? null : _flashFade,
      strengthOf: _flashStrength,
      uncertain: [
        for (final span in state.lowConfidenceSentences)
          if (span.targetStart >= 0 &&
              span.targetEnd <= output.length &&
              span.targetEnd > span.targetStart)
            TextRange(start: span.targetStart, end: span.targetEnd),
      ],
      contextMenuBuilder: (context, editable) =>
          _contextMenu(context, editable, state),
      spoken: spoken,
      onWordTap: onWordTap,
    );
  }

  /// "The on-device engine is unsure about 2 sentences" and "Compare with
  /// another engine" (when there is one).
  Widget _uncertainNote(BuildContext context, TranslateState state, int count) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = AppPalette.of(context).secondaryText;
    return Padding(
      key: const Key('translate_uncertain_note'),
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  Icons.help_outline,
                  size: 18,
                  color: theme.colorScheme.tertiary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.translateUncertainNote(count),
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            ],
          ),
          if (state.engines.length > 1)
            TextButton.icon(
              key: const Key('translate_uncertain_compare'),
              icon: const Icon(Icons.difference_outlined),
              label: Text(l10n.translateUncertainCompare),
              onPressed: _compareWithAnotherEngine,
            ),
        ],
      ),
    );
  }

  /// Whether alternatives can be requested for a part of the translation.
  static bool _offersSpanAlternatives(TranslateState state) =>
      state.hasExtras &&
      state.status == TranslateStatus.success &&
      (state.result?.isComplete ?? false) &&
      !state.isResultStale;

  /// Most words of a selection offered for a word card ("Look up").
  static const _maxLookUpWords = 3;

  /// Whether the selected [text] of [state]'s translation can be looked up
  /// on a word card: one to [_maxLookUpWords] words of a finished
  /// translation into a known language.
  static bool _offersWordLookUp(TranslateState state, String text) {
    final words = text.trim();
    return (state.result?.isComplete ?? false) &&
        !state.target.isCustom &&
        !state.target.isAuto &&
        words.isNotEmpty &&
        words.length <= WordLookupCubit.maxWordLength &&
        words.split(RegExp(r'\s+')).length <= _maxLookUpWords;
  }

  /// The platform's selection toolbar plus "Alternatives" for the selected
  /// part of a finished translation, and "Look up" (its word card) for a
  /// selection of a few words: the word card's way for keyboards and
  /// screen readers, which select text rather than tap a word.
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
    if (selection.isValid &&
        !selection.isCollapsed &&
        _offersWordLookUp(state, selection.textInside(value.text))) {
      items.add(
        ContextMenuButtonItem(
          label: context.l10n.dictionaryLookUp,
          onPressed: () {
            editable.hideToolbar();
            _lookUpSelection(state, value);
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

  /// Opens the word card of the selected text (trimmed), with its sentence.
  void _lookUpSelection(TranslateState state, TextEditingValue value) {
    final selection = value.selection;
    final raw = selection.textInside(value.text);
    final word = raw.trim();
    final start = selection.start + raw.length - raw.trimLeft().length;
    unawaited(
      showWordLookupSheet(
        context,
        word: word,
        language: state.target,
        into: wordLookupInto(state),
        sentence: WordSegmenter.sentenceAround(
          value.text,
          TextWord(start, start + word.length, word),
        ),
      ),
    );
  }

  /// Whether [state]'s engine is on-device AI.
  static bool _onDeviceAi(TranslateState state) {
    final engine = state.engine;
    return engine != null && isOnDeviceAiEngine(engine);
  }

  Widget _insightsStatus(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final child = switch (state.insightsStatus) {
      ExtraStatus.loading => OnDeviceAiExtraLoading(
        engine: state.assistEngine,
        child: LinearProgressIndicator(
          key: const Key('translate_insights_progress'),
          semanticsLabel: l10n.translateLoading,
        ),
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
    return Padding(padding: const EdgeInsets.only(top: 12), child: child);
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
      ExtraStatus.loading => OnDeviceAiExtraLoading(
        engine: state.assistEngine,
        child: LinearProgressIndicator(
          key: const Key('translate_alignment_progress'),
          semanticsLabel: l10n.translateAlignmentLoading,
        ),
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
    return Padding(padding: const EdgeInsets.only(top: 12), child: child);
  }

  /// The everyday actions, clustered at the start edge (48 dp targets, 8 dp
  /// apart): copy, listen, favourite (a heart), share and show full screen.
  Widget _actions(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final palette = AppPalette.of(context);
    // The terminal look frames each action as a small square button.
    final terminal = AppLook.of(context).isTerminal;
    return Wrap(
      key: const Key('translate_output_actions'),
      spacing: terminal ? 2 : 8,
      runSpacing: terminal ? 2 : 0,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final action in _actionButtons(context, state, l10n, palette))
          if (terminal) TerminalFrame(child: action) else action,
      ],
    );
  }

  /// The buttons of [_actions].
  List<Widget> _actionButtons(
    BuildContext context,
    TranslateState state,
    AppLocalizations l10n,
    AppPalette palette,
  ) {
    final output = state.output;
    final complete = state.result?.isComplete ?? true;
    final target = state.target;
    return [
      CopyActionButton(
        key: const Key('translate_copy_button'),
        text: output,
        quiet: true,
      ),
      ListenButton(
        id: translateOutputSpeechId,
        text: output,
        languageCode: target.isCustom ? null : target.code,
        quiet: true,
      ),
      BlocBuilder<HistoryCubit, HistoryState>(
        builder: (context, history) {
          final entry = findHistoryEntry(
            history.entries,
            state.resultInput ?? state.input,
            output,
          );
          final favorite = entry?.isFavorite ?? false;
          return XActionButton(
            key: const Key('translate_favorite_button'),
            tooltip: favorite
                ? l10n.translateUnfavorite
                : l10n.translateFavorite,
            active: favorite,
            icon: Icons.favorite_border,
            activeIcon: Icons.favorite,
            activeColor: palette.like,
            onPressed: complete ? () => _toggleFavorite(state, entry) : null,
          );
        },
      ),
      // Beside the heart: into a phrasebook collection (where the app
      // has one).
      if (maybePhrasebookRepository(context) != null)
        AddToPhrasebookButton(
          draft: complete ? translationPhraseDraft(state) : null,
        ),
      Builder(
        builder: (buttonContext) => XActionButton(
          key: const Key('translate_share_button'),
          tooltip: l10n.commonShare,
          icon: Icons.ios_share,
          onPressed: () => unawaited(_share(buttonContext, output)),
        ),
      ),
      XActionButton(
        key: const Key('translate_show_button'),
        tooltip: l10n.translateShowMode,
        icon: Icons.fullscreen,
        onPressed: () => unawaited(
          showTranslationFullScreen(
            context,
            text: output,
            textDirection: outputTextDirection(state),
            locale: localeForLanguage(target),
          ),
        ),
      ),
    ];
  }

  /// Whether the refinement chips show under the actions: an AI engine with
  /// extras and a translation (they are disabled until it is finished and
  /// current, see [_refinements]).
  static bool _showsRefinements(TranslateState state) =>
      state.isAiEngine &&
      state.hasExtras &&
      state.output.trim().isNotEmpty &&
      state.status != TranslateStatus.failure;

  /// The refinement chips, always in view under the actions of an AI
  /// translation; inactive (faded) while the translation is not finished or
  /// out of date.
  Widget _refinements(BuildContext context, TranslateState state) {
    final enabled =
        state.status == TranslateStatus.success &&
        (state.result?.isComplete ?? false) &&
        !state.isResultStale;
    return Padding(
      key: const Key('translate_output_refinements'),
      padding: const EdgeInsetsDirectional.only(top: 4, end: 12),
      child: IgnorePointer(
        ignoring: !enabled,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.5,
          duration: TranslateLayout.motion(context),
          child: RefinementChips(state: state),
        ),
      ),
    );
  }

  /// "Check meaning" (on demand only), on while a check is shown.
  Widget _meaningButton(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final shown = state.meaningStatus != ExtraStatus.idle;
    return TranslateToolRow(
      key: const Key('translate_meaning_button'),
      focusNode: widget.meaningButtonFocusNode,
      icon: Icons.fact_check_outlined,
      label: l10n.translateMeaningCheck,
      selected: shown,
      onPressed: shown
          ? context.read<TranslateCubit>().clearMeaningCheck
          : state.canCheckMeaning
          ? () => unawaited(checkMeaningIn(context))
          : null,
    );
  }

  /// The "Tools" toggle and, while it is open, the analysis tools as rows
  /// ([_toolRows]).
  Widget _tools(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final more = _more(context);
    return ListenableBuilder(
      listenable: more,
      builder: (context, _) {
        final rows = more.expanded
            ? _toolRows(context, state)
            : const <Widget>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TranslateMoreToggle(controller: more),
            ),
            AnimatedSize(
              duration: TranslateLayout.motion(context),
              curve: Curves.easeOutCubic,
              alignment: AlignmentDirectional.topStart,
              child: rows.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        0,
                        0,
                        12,
                        8,
                      ),
                      child: Semantics(
                        key: const Key('translate_output_tools'),
                        container: true,
                        explicitChildNodes: true,
                        label: l10n.translateToolsLabel,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: rows,
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// The rows of the "Tools" area: check meaning, insights (AI extras),
  /// romanization and matching phrases (alignment), each on or off, then
  /// "Compare engines" (several engines).
  List<Widget> _toolRows(BuildContext context, TranslateState state) {
    final l10n = context.l10n;
    final complete = state.result?.isComplete ?? true;
    final romanizationShown = _romanizationShown(
      state,
      context.read<SettingsCubit>().state,
    );
    return [
      _meaningButton(context, state),
      if (state.hasExtras)
        TranslateToolRow(
          key: const Key('translate_insights_button'),
          icon: Icons.lightbulb_outline,
          label: l10n.translateInsights,
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
      if (state.alignmentEngine != null)
        TranslateToolRow(
          key: const Key('translate_alignment_button'),
          icon: Icons.sync_alt,
          label: l10n.translateToolAlignment,
          selected: _showAlignment,
          // Can always be turned off; turned on for a finished, current
          // translation.
          onPressed: _showAlignment || state.canAlign
              ? () => _toggleAlignment(state)
              : null,
        ),
      if (state.engines.length > 1)
        TranslateToolRow(
          key: const Key('translate_compare_toggle'),
          icon: Icons.difference_outlined,
          label: l10n.translateCompareModeEnter,
          opens: true,
          onPressed: () =>
              context.read<TranslateCubit>().setCompareMode(enabled: true),
        ),
    ];
  }
}

/// "More formal ×" in the output header: a refinement in the translation;
/// the × undoes it (`TranslateCubit.applySuggestion` toggles it off, with
/// every refinement applied after it).
class _RefinementTag extends StatelessWidget {
  const new({required this.suggestion, super.key});

  final RefinementSuggestion suggestion;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final label = refinementLabel(l10n, suggestion);
    // A plain chip with a delete button: an InputChip without onPressed
    // reads as disabled to screen readers.
    return Chip(
      avatar: Icon(
        refinementIcon(suggestion.icon),
        size: 16,
        color: theme.colorScheme.primary,
      ),
      label: Text(label),
      labelStyle: theme.textTheme.labelMedium,
      visualDensity: VisualDensity.compact,
      deleteIcon: const Icon(Icons.close, size: 16),
      deleteButtonTooltipMessage: l10n.translateRefinementUndo(label),
      onDeleted: () =>
          unawaited(context.read<TranslateCubit>().applySuggestion(suggestion)),
    );
  }
}

/// The plain translation [text]: the [flash] ranges (what a refinement
/// changed) with a background that fades with [flashStrength] (its
/// strength from [strengthOf]), and the [uncertain] ranges (sentences the
/// on-device engine is unsure about) with a dotted underline, a help
/// cursor and a tooltip shown on hover or tap. The [spoken] range (the
/// word Listen reads) is highlighted ([spokenWordStyle]); while text is
/// selected it holds still, as a new highlight would clear the selection.
/// With [onWordTap], a tap on the text reports where it placed the caret
/// ([WordTapTracker]: not a double tap, a long press or a drag).
class _PlainOutputText extends StatefulWidget {
  const new({
    required this.text,
    required this.flash,
    required this.uncertain,
    required this.strengthOf,
    required this.contextMenuBuilder,
    this.flashStrength,
    this.style,
    this.textDirection,
    this.locale,
    this.spoken,
    this.onWordTap,
  });

  final String text;
  final List<TextRange> flash;
  final List<TextRange> uncertain;
  final Animation<double>? flashStrength;
  final double Function(BuildContext context) strengthOf;
  final EditableTextContextMenuBuilder contextMenuBuilder;
  final TextStyle? style;
  final TextDirection? textDirection;
  final Locale? locale;
  final TextRange? spoken;
  final ValueChanged<int>? onWordTap;

  @override
  State<_PlainOutputText> createState() => _PlainOutputTextState();
}

class _PlainOutputTextState extends State<_PlainOutputText> {
  final _tooltip = GlobalKey<TooltipState>();

  late final TapGestureRecognizer _tap = TapGestureRecognizer()
    ..onTap = _showTooltip;

  late final WordTapTracker _words = WordTapTracker(
    onWordTap: (offset) {
      if (mounted) widget.onWordTap?.call(offset);
    },
  );

  /// The spoken range drawn last (held while text is selected).
  TextRange? _shownSpoken;

  @override
  void didUpdateWidget(_PlainOutputText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text || widget.onWordTap == null) {
      _words.cancel();
    }
  }

  @override
  void dispose() {
    _tap.dispose();
    _words.dispose();
    super.dispose();
  }

  void _onTextTap() => _words.onTap(context);

  /// Tells the tap tracker; once a selection is cleared, the spoken range
  /// held for it catches up.
  void _onSelectionChanged(
    TextSelection selection,
    SelectionChangedCause? cause,
  ) {
    _words.onSelectionChanged(selection, cause);
    if (!_words.hasSelection && _shownSpoken != widget.spoken) {
      setState(() {});
    }
  }

  /// The spoken range to draw: [_PlainOutputText.spoken], or the one drawn
  /// last while text is selected.
  TextRange? _spoken() {
    final spoken = _words.hasSelection ? _shownSpoken : widget.spoken;
    final text = widget.text;
    return _shownSpoken = spoken != null && spoken.end <= text.length
        ? spoken
        : null;
  }

  void _showTooltip() => _tooltip.currentState?.ensureTooltipVisible();

  @override
  Widget build(BuildContext context) {
    final flash = widget.flash;
    final uncertain = widget.uncertain;
    final animation = widget.flashStrength;
    final text = animation == null || flash.isEmpty
        ? _text(context)
        : AnimatedBuilder(
            animation: animation,
            builder: (context, _) => _text(context),
          );
    if (uncertain.isEmpty) return text;
    return Tooltip(
      key: _tooltip,
      message: context.l10n.translateUncertainHint,
      triggerMode: TooltipTriggerMode.manual,
      // The note under the text says it to screen readers.
      excludeFromSemantics: true,
      child: text,
    );
  }

  Widget _text(BuildContext context) {
    final text = widget.text;
    final flash = widget.flash;
    final uncertain = widget.uncertain;
    final spoken = _spoken();
    final onTap = widget.onWordTap == null ? null : _onTextTap;
    if (flash.isEmpty && uncertain.isEmpty && spoken == null) {
      return SelectableText.rich(
        TextSpan(text: text, locale: widget.locale),
        key: const Key('translate_output_text'),
        style: widget.style,
        textDirection: widget.textDirection,
        contextMenuBuilder: widget.contextMenuBuilder,
        focusNode: _words.focusNode,
        onSelectionChanged: _onSelectionChanged,
        onTap: onTap,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final strength = flash.isEmpty ? 0.0 : widget.strengthOf(context);
    final flashStyle = TextStyle(
      backgroundColor: scheme.tertiaryContainer.withValues(
        alpha: 0.9 * strength,
      ),
    );
    final unsureStyle = TextStyle(
      decoration: TextDecoration.underline,
      decorationStyle: TextDecorationStyle.dotted,
      decorationColor: scheme.tertiary,
      decorationThickness: 2,
    );
    final spokenStyle = spokenWordStyle(scheme);
    final cuts = {
      0,
      text.length,
      for (final range in [...flash, ...uncertain, ?spoken]) ...[
        range.start,
        range.end,
      ],
    }.where((offset) => offset >= 0 && offset <= text.length).toList()..sort();
    bool covers(List<TextRange> ranges, int start, int end) =>
        ranges.any((range) => range.start <= start && end <= range.end);
    return SelectableText.rich(
      TextSpan(
        locale: widget.locale,
        children: [
          for (var i = 0; i + 1 < cuts.length; i++)
            if (cuts[i] < cuts[i + 1])
              _segment(
                text.substring(cuts[i], cuts[i + 1]),
                unsure: covers(uncertain, cuts[i], cuts[i + 1]),
                flashed: strength > 0 && covers(flash, cuts[i], cuts[i + 1]),
                spoken:
                    spoken != null && covers([spoken], cuts[i], cuts[i + 1]),
                unsureStyle: unsureStyle,
                flashStyle: flashStyle,
                spokenStyle: spokenStyle,
              ),
        ],
      ),
      key: const Key('translate_output_text'),
      style: widget.style,
      textDirection: widget.textDirection,
      contextMenuBuilder: widget.contextMenuBuilder,
      focusNode: _words.focusNode,
      onSelectionChanged: _onSelectionChanged,
      onTap: onTap,
    );
  }

  TextSpan _segment(
    String text, {
    required bool unsure,
    required bool flashed,
    required bool spoken,
    required TextStyle unsureStyle,
    required TextStyle flashStyle,
    required TextStyle spokenStyle,
  }) {
    var style = unsure ? unsureStyle : null;
    if (flashed) style = (style ?? const TextStyle()).merge(flashStyle);
    if (spoken) style = (style ?? const TextStyle()).merge(spokenStyle);
    if (!unsure) return TextSpan(text: text, style: style);
    return TextSpan(
      text: text,
      style: style,
      mouseCursor: SystemMouseCursors.help,
      onEnter: (_) => _showTooltip(),
      onExit: (_) => Tooltip.dismissAllToolTips(),
      recognizer: _tap,
    );
  }
}
