import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/bidi.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/aligned_text.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// The English name of the UI language of [locale], for text the model
/// writes for the user (the problems a meaning check lists).
String translateUiLanguage(Locale locale) {
  if (locale.languageCode == 'en') return 'English';
  return LanguageCatalog.byCode(locale.languageCode)?.name ?? 'English';
}

/// Starts `TranslateCubit.checkMeaning` with the UI language of [context].
Future<void> checkMeaningIn(BuildContext context) =>
    context.read<TranslateCubit>().checkMeaning(
      uiLanguage: translateUiLanguage(Localizations.localeOf(context)),
    );

/// The output range of the highlighted meaning check issue
/// (`TranslateState.focusedMeaningIssue`) while the check belongs to the
/// shown output, else null.
TextRange? outputMeaningHighlight(TranslateState state) {
  final issue = state.focusedMeaningIssue;
  final result = state.result;
  if (issue == null ||
      !issue.hasTranslationRange ||
      result == null ||
      !result.isComplete ||
      state.isResultStale ||
      state.meaningStatus != ExtraStatus.ready) {
    return null;
  }
  final range = TextRange(
    start: issue.translationStart!,
    end: issue.translationEnd!,
  );
  return range.end <= result.text.length ? range : null;
}

/// The input range of the highlighted meaning check issue while the check
/// belongs to [text] (the input field's current text), else null.
TextRange? inputMeaningHighlight(TranslateState state, String text) {
  final issue = state.focusedMeaningIssue;
  if (issue == null ||
      !issue.hasSourceRange ||
      state.input != text ||
      state.isResultStale ||
      state.meaningStatus != ExtraStatus.ready) {
    return null;
  }
  final range = TextRange(start: issue.sourceStart!, end: issue.sourceEnd!);
  return range.end <= text.length ? range : null;
}

/// [text] with [highlight] drawn like a focused alignment phrase
/// ([AlignedText.focusStyle]); the whole text in [locale].
TextSpan highlightedTextSpan(
  String text,
  TextRange highlight,
  ColorScheme scheme, {
  Locale? locale,
}) => TextSpan(
  locale: locale,
  children: [
    if (highlight.start > 0) TextSpan(text: highlight.textBefore(text)),
    TextSpan(
      text: highlight.textInside(text),
      style: AlignedText.focusStyle(scheme),
    ),
    if (highlight.end < text.length) TextSpan(text: highlight.textAfter(text)),
  ],
);

/// [message] built around [value]: the value keeps its own [locale] (so
/// screen readers read it with a matching voice) and is bidi-isolated.
TextSpan _messageWith(
  String Function(String value) message,
  String value, {
  Locale? locale,
  TextStyle? valueStyle,
}) {
  const marker = '\u{FFFC}';
  final template = message(marker);
  final at = template.indexOf(marker);
  if (at < 0) return TextSpan(text: message(bidiIsolate(value)));
  return TextSpan(
    children: [
      TextSpan(text: template.substring(0, at)),
      TextSpan(text: bidiIsolate(value), locale: locale, style: valueStyle),
      TextSpan(text: template.substring(at + marker.length)),
    ],
  );
}

/// The code of the input's language (chosen or detected), or null when it
/// is unknown or a custom language.
String? _inputLanguageCode(TranslateState state) =>
    state.source.isCustom ? null : state.effectiveSourceCode;

/// The result of `TranslateCubit.checkMeaning` under the translation,
/// shown while a check is loading, failed or ready (hidden otherwise).
///
/// An AI check shows its verdict (icon and text), the back-translation (in
/// the input's language and direction) and the differences it found;
/// tapping a difference highlights it in the input and the translation
/// (`TranslateCubit.focusMeaningIssue`), tapping it again removes the
/// highlight. Engines without AI extras show the back-translation only.
/// The verdict (or "Back-translation ready") is announced to screen
/// readers when it arrives.
///
/// A verdict of differences whose places could not be found in the texts
/// says so (and points to the back-translation) instead of listing them.
/// Each difference that can be highlighted shows a highlight icon and
/// tells screen readers where it is highlighted; the others are drawn
/// filled, without an outline.
///
/// The close button hides the panel; when the focus was in the panel
/// (keyboard) or a screen reader is on, the focus moves to
/// [returnFocusNode] (the output card's "Check meaning" button) instead of
/// getting lost with the panel.
class MeaningCheckPanel extends StatelessWidget {
  const new({this.returnFocusNode, super.key});

  /// Where the focus goes when the close button hides the panel.
  final FocusNode? returnFocusNode;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.meaningStatus != current.meaningStatus ||
          previous.meaningCheck != current.meaningCheck ||
          previous.backTranslation != current.backTranslation ||
          previous.meaningFocus != current.meaningFocus ||
          previous.meaningError != current.meaningError ||
          previous.source != current.source ||
          previous.target != current.target ||
          previous.result != current.result ||
          previous.engine != current.engine,
      builder: (context, state) {
        if (state.meaningStatus == ExtraStatus.idle) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: TranslateLayout.gap),
          child: _MeaningCard(state: state, returnFocusNode: returnFocusNode),
        );
      },
    );
  }
}

class _MeaningCard extends StatefulWidget {
  const new({required this.state, this.returnFocusNode});

  final TranslateState state;
  final FocusNode? returnFocusNode;

  @override
  State<_MeaningCard> createState() => _MeaningCardState();
}

class _MeaningCardState extends State<_MeaningCard> {
  /// Tells whether the focus is in the panel (never focused itself).
  final _panelFocus = FocusNode(
    debugLabel: 'translate_meaning_panel',
    canRequestFocus: false,
    skipTraversal: true,
  );

  TranslateState get state => widget.state;

  @override
  void dispose() {
    _panelFocus.dispose();
    super.dispose();
  }

  void _close() {
    final moveFocus =
        _panelFocus.hasFocus || MediaQuery.accessibleNavigationOf(context);
    context.read<TranslateCubit>().clearMeaningCheck();
    if (moveFocus) widget.returnFocusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _panelFocus,
      includeSemantics: false,
      child: _card(context),
    );
  }

  Widget _card(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final backTranslationOnly =
        state.backTranslation != null ||
        (state.meaningCheck == null && !state.meaningUsesAi);
    return Card(
      key: const Key('translate_meaning_panel'),
      margin: EdgeInsets.zero,
      // Separate nodes for the title, the texts and each difference.
      semanticContainer: false,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: TranslateLayout.cardBorderRadius,
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 4, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.fact_check_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      backTranslationOnly
                          ? l10n.translateMeaningBackTranslationTitle
                          : l10n.translateMeaningTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('translate_meaning_close'),
                  tooltip: l10n.translateMeaningCheckHide,
                  icon: const Icon(Icons.close),
                  onPressed: _close,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 16),
              child: _body(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = context.l10n;
    switch (state.meaningStatus) {
      case ExtraStatus.idle:
        return const SizedBox.shrink();
      case ExtraStatus.loading:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: LinearProgressIndicator(
            key: const Key('translate_meaning_progress'),
            semanticsLabel: l10n.translateMeaningChecking,
          ),
        );
      case ExtraStatus.failure:
        return TranslateErrorView(
          key: const Key('translate_meaning_error'),
          error: state.meaningError,
          dense: true,
          onRetry: () => unawaited(checkMeaningIn(context)),
        );
      case ExtraStatus.ready:
        final check = state.meaningCheck;
        if (check != null) return _CheckResult(state: state, check: check);
        return _BackTranslation(state: state);
    }
  }
}

/// The back-translation in the input's language (and its direction).
class _BackTranslationText extends StatelessWidget {
  const new({required this.state, required this.text});

  final TranslateState state;
  final String text;

  @override
  Widget build(BuildContext context) {
    final code = _inputLanguageCode(state);
    // Selectable text can be long-pressed: at least a 48 dp target.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: SelectableText.rich(
        TextSpan(text: text, locale: localeForCode(code)),
        key: const Key('translate_meaning_back_translation'),
        style: Theme.of(context).textTheme.bodyLarge,
        textDirection: textDirectionForCode(code) ?? textDirectionForText(text),
      ),
    );
  }
}

/// Engines without AI extras: the back-translation alone.
class _BackTranslation extends StatelessWidget {
  const new({required this.state});

  final TranslateState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final engine = state.engine?.name ?? state.result?.engineName ?? '';
    return StatusAnnouncer(
      message: l10n.translateMeaningBackTranslationReady,
      announceInitial: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.translateMeaningBackTranslationNote(bidiIsolate(engine)),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          _BackTranslationText(state: state, text: state.backTranslation!),
        ],
      ),
    );
  }
}

/// Verdict, back-translation and differences of an AI check.
class _CheckResult extends StatelessWidget {
  const new({required this.state, required this.check});

  final TranslateState state;
  final MeaningCheck check;

  /// Icon, icon colour and label of [verdict]: never told by colour alone.
  static (IconData, Color, String) verdictStyle(
    BuildContext context,
    MeaningVerdict verdict,
  ) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return switch (verdict) {
      MeaningVerdict.same => (
        Icons.check_circle_outline,
        scheme.primary,
        l10n.translateMeaningVerdictSame,
      ),
      MeaningVerdict.minor => (
        Icons.info_outline,
        scheme.tertiary,
        l10n.translateMeaningVerdictMinor,
      ),
      MeaningVerdict.major => (
        Icons.error_outline,
        scheme.error,
        l10n.translateMeaningVerdictMajor,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final label = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final (icon, color, verdict) = verdictStyle(context, check.verdict);
    final issues = check.issues;
    return StatusAnnouncer(
      message: l10n.translateMeaningAnnounce(verdict, issues.length),
      announceInitial: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              key: const Key('translate_meaning_verdict'),
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(verdict, style: theme.textTheme.titleSmall),
                ),
              ],
            ),
          ),
          if (check.isPartial)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.translateMeaningPartial,
                key: const Key('translate_meaning_partial'),
                style: muted,
              ),
            ),
          if (check.backTranslation.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(l10n.translateMeaningBackTranslationTitle, style: label),
            const SizedBox(height: 4),
            _BackTranslationText(state: state, text: check.backTranslation),
          ],
          const SizedBox(height: 12),
          if (issues.isEmpty && check.isSame)
            Text(
              l10n.translateMeaningNoIssues,
              key: const Key('translate_meaning_no_issues'),
              style: muted,
            )
          else if (issues.isEmpty)
            // Differences the model named but that could not be found in
            // the texts.
            Text(
              l10n.translateMeaningIssuesUnlocated,
              key: const Key('translate_meaning_issues_unlocated'),
              style: muted,
            )
          else ...[
            Semantics(
              header: true,
              child: Text(l10n.translateMeaningIssuesTitle, style: label),
            ),
            const SizedBox(height: 4),
            for (final (index, issue) in issues.indexed)
              _IssueTile(
                key: ValueKey('translate_meaning_issue_$index'),
                state: state,
                issue: issue,
                index: index,
              ),
          ],
        ],
      ),
    );
  }
}

/// One difference: its kind, the problem (in the UI language), where it is
/// in both texts and a suggested wording (each in its own language).
class _IssueTile extends StatelessWidget {
  const new({
    required this.state,
    required this.issue,
    required this.index,
    super.key,
  });

  final TranslateState state;
  final MeaningIssue issue;
  final int index;

  static String typeLabel(AppLocalizations l10n, MeaningIssueType type) =>
      switch (type) {
        MeaningIssueType.omission => l10n.translateMeaningTypeOmission,
        MeaningIssueType.addition => l10n.translateMeaningTypeAddition,
        MeaningIssueType.negation => l10n.translateMeaningTypeNegation,
        MeaningIssueType.number => l10n.translateMeaningTypeNumber,
        MeaningIssueType.tense => l10n.translateMeaningTypeTense,
        MeaningIssueType.mistranslation =>
          l10n.translateMeaningTypeMistranslation,
        MeaningIssueType.other => l10n.translateMeaningTypeOther,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final focused = state.meaningFocus == index;
    final located = issue.hasSourceRange || issue.hasTranslationRange;
    final tapHint = !located
        ? null
        : focused
        ? l10n.translateMeaningIssueUnhighlight
        : issue.hasSourceRange && issue.hasTranslationRange
        ? l10n.translateMeaningIssueHighlight
        : issue.hasSourceRange
        ? l10n.translateMeaningIssueHighlightSource
        : l10n.translateMeaningIssueHighlightTranslation;
    final foreground = focused ? scheme.onSecondaryContainer : null;
    final detail = theme.textTheme.bodyMedium?.copyWith(color: foreground);
    final cubit = context.read<TranslateCubit>();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Semantics(
        container: true,
        selected: focused,
        onTapHint: tapHint,
        child: Material(
          // Differences that can be highlighted are outlined (with a
          // highlight icon); the others are filled.
          color: focused
              ? scheme.secondaryContainer
              : located
              ? Colors.transparent
              : scheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            side: located
                ? BorderSide(
                    color: focused ? scheme.secondary : scheme.outlineVariant,
                  )
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: located
                ? () => cubit.focusMeaningIssue(focused ? null : index)
                : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _details(context, foreground, detail)),
                    if (located)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 8),
                        child: Icon(
                          focused ? Icons.highlight_off : Icons.highlight,
                          key: const Key('translate_meaning_issue_highlight'),
                          size: 20,
                          color: foreground ?? scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Kind, problem, where it is and the suggested wording.
  Widget _details(BuildContext context, Color? foreground, TextStyle? detail) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sourceLocale = localeForCode(_inputLanguageCode(state));
    final targetLocale = localeForLanguage(state.target);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          typeLabel(l10n, issue.type),
          style: theme.textTheme.labelMedium?.copyWith(
            color: foreground ?? scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          issue.problem,
          style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
        ),
        if (issue.sourceSpan.trim().isNotEmpty)
          Text.rich(
            _messageWith(
              l10n.translateMeaningInOriginal,
              issue.sourceSpan,
              locale: sourceLocale,
            ),
            style: detail,
          ),
        if (issue.translationSpan.trim().isNotEmpty)
          Text.rich(
            _messageWith(
              l10n.translateMeaningInTranslation,
              issue.translationSpan,
              locale: targetLocale,
            ),
            style: detail,
          ),
        if (issue.suggestion.trim().isNotEmpty)
          Text.rich(
            _messageWith(
              l10n.translateMeaningSuggestion,
              issue.suggestion,
              locale: targetLocale,
              valueStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
            style: detail,
          ),
      ],
    );
  }
}
