import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/bidi.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/language_text.dart';
import 'package:mozhi/translate/widgets/listen_button.dart';
import 'package:mozhi/translate/widgets/output_card.dart'
    show copyToClipboard, staleOutputOpacity;
import 'package:mozhi/translate/widgets/status_announcer.dart';
import 'package:mozhi/translate/widgets/translate_error.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens the sheet that picks the extra target languages
/// ([ExtraTargetsSheet]).
Future<void> showExtraTargetsSheet(BuildContext context) {
  final translate = context.read<TranslateCubit>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        BlocProvider.value(value: translate, child: const ExtraTargetsSheet()),
  );
}

/// "Also translate into…" under the translation: a button that picks up to
/// `TranslateCubit.maxExtraTargets` additional target languages (it lists
/// the chosen ones), and a card per language with its translation of the
/// input ([ExtraTargetCard]) while there is input.
///
/// The extra targets are translated with the main translation (same engine
/// and options, a request each); see `TranslateCubit.setExtraTargets`.
/// Screen readers hear once which of them arrived (and which failed) when
/// none is in flight any more.
class ExtraTargetsSection extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.extraTargets != current.extraTargets ||
          previous.extraTranslations != current.extraTranslations ||
          previous.input != current.input ||
          previous.source != current.source ||
          previous.target != current.target ||
          previous.targetLanguages != current.targetLanguages ||
          previous.engine != current.engine,
      builder: (context, state) {
        if (state.engine == null) return const SizedBox.shrink();
        final active = state.activeExtraTargets;
        final names = [
          for (final language in active) bidiIsolate(language.name),
        ];
        final column = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: TranslateLayout.gap),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const Key('translate_extra_targets_button'),
                icon: const Icon(Icons.add),
                label: Text(
                  names.isEmpty
                      ? l10n.translateExtraTargetsAdd
                      : l10n.translateExtraTargetsSelected(
                          names.join(l10n.translateExtraTargetsListSeparator),
                        ),
                ),
                onPressed: () => unawaited(showExtraTargetsSheet(context)),
              ),
            ),
            if (state.input.trim().isNotEmpty)
              for (final target in active)
                Padding(
                  padding: const EdgeInsets.only(top: TranslateLayout.gap),
                  child: ExtraTargetCard(
                    key: ValueKey('translate_extra_target_${target.code}'),
                    state: state,
                    target: target,
                  ),
                ),
          ],
        );
        return _ExtraTargetsAnnouncer(
          state: state,
          active: active,
          child: column,
        );
      },
    );
  }
}

/// Announces the translations into the extra targets [active] once none is
/// in flight any more: the languages translated and the ones that failed
/// (for the current input). Removing a language announces nothing.
class _ExtraTargetsAnnouncer extends StatefulWidget {
  const new({required this.state, required this.active, required this.child});

  final TranslateState state;
  final List<Language> active;
  final Widget child;

  @override
  State<_ExtraTargetsAnnouncer> createState() => _ExtraTargetsAnnouncerState();
}

class _ExtraTargetsAnnouncerState extends State<_ExtraTargetsAnnouncer> {
  /// Names of the languages of the last finished round.
  ({List<String> ready, List<String> failed})? _summary;

  /// Counts the rounds, so an identical summary is announced again.
  int _round = 0;

  static bool _translating(TranslateState state, List<Language> active) =>
      active.any(
        (target) =>
            state.extraTranslationFor(target)?.status ==
            TranslateStatus.translating,
      );

  @override
  void didUpdateWidget(_ExtraTargetsAnnouncer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final state = widget.state;
    if (!_translating(oldWidget.state, oldWidget.active) ||
        _translating(state, widget.active)) {
      return;
    }
    final ready = <String>[];
    final failed = <String>[];
    for (final target in widget.active) {
      final translation = state.extraTranslationFor(target);
      if (translation == null || translation.request?.text != state.input) {
        continue;
      }
      if (translation.status == TranslateStatus.failure) {
        failed.add(target.name);
      } else if (translation.status == TranslateStatus.success &&
          (translation.result?.isComplete ?? false)) {
        ready.add(target.name);
      }
    }
    if (ready.isEmpty && failed.isEmpty) return;
    _summary = (ready: ready, failed: failed);
    _round++;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    String names(List<String> languages) =>
        [for (final language in languages) bidiIsolate(language)]
            .join(l10n.translateExtraTargetsListSeparator);
    final summary = _summary;
    final message = summary == null
        ? null
        : [
            if (summary.ready.isNotEmpty)
              l10n.translateExtraTargetsAnnounceReady(names(summary.ready)),
            if (summary.failed.isNotEmpty)
              l10n.translateExtraTargetsAnnounceFailed(names(summary.failed)),
          ].join(' ');
    return StatusAnnouncer(
      message: message,
      announcementId: _round,
      child: widget.child,
    );
  }
}

/// The translation of the input into the extra target [target]: progress,
/// the text (in the language's locale and direction; dimmed while it
/// belongs to text the user has since edited), errors with Retry, and
/// actions (copy, listen, use as the input, remove the language), each
/// naming the language for screen readers and voice control.
///
/// "Use as input" (`TranslateCubit.insertExtraTranslation`) replaces the
/// input and may change the source language: a snack bar says so and
/// offers Undo (`TranslateCubit.undoInsertExtraTranslation`).
class ExtraTargetCard extends StatelessWidget {
  const new({required this.state, required this.target, super.key});

  final TranslateState state;
  final Language target;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<TranslateCubit>();
    final translation = state.extraTranslationFor(target);
    final status = translation?.status ?? TranslateStatus.idle;
    final translating = status == TranslateStatus.translating;
    final output = translation?.output ?? '';
    final complete = translation?.result?.isComplete ?? false;
    final name = bidiIsolate(target.name);
    return Card(
      margin: EdgeInsets.zero,
      // The labelled container below groups the card's nodes.
      semanticContainer: false,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: TranslateLayout.cardBorderRadius,
      ),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: l10n.translateExtraTargetLabel(target.name),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 3,
              child: translating
                  ? LinearProgressIndicator(
                      minHeight: 3,
                      semanticsLabel: l10n.translateTranslating,
                    )
                  : null,
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          target.name,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('translate_extra_target_remove'),
                        tooltip: l10n.translateExtraTargetRemove(name),
                        icon: const Icon(Icons.close),
                        onPressed: () => cubit.toggleExtraTarget(target),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 12),
                    child: _content(context, translation),
                  ),
                  if (output.trim().isNotEmpty)
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        IconButton(
                          key: const Key('translate_extra_target_copy'),
                          tooltip: l10n.translateExtraTargetCopy(name),
                          icon: const Icon(Icons.copy_outlined),
                          onPressed: () =>
                              unawaited(copyToClipboard(context, output)),
                        ),
                        ListenButton(
                          id: 'extra:${target.code}',
                          text: output,
                          languageCode: target.isCustom ? null : target.code,
                          tooltip: l10n.translateExtraTargetListen(name),
                          stopTooltip: l10n.translateExtraTargetStopListening(
                            name,
                          ),
                        ),
                        IconButton(
                          key: const Key('translate_extra_target_insert'),
                          tooltip: l10n.translateExtraTargetUseAsInput(name),
                          icon: const Icon(Icons.input),
                          onPressed: complete
                              ? () => _useAsInput(context)
                              : null,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Uses the translation as the input and offers Undo in a snack bar
  /// that also names the new source language. It stays until dismissed:
  /// keyboard and screen-reader users need time to reach Undo.
  void _useAsInput(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<TranslateCubit>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final before = cubit.state;
    cubit.insertExtraTranslation(target);
    final after = cubit.state;
    if (after.input == before.input && after.source == before.source) return;
    final language = bidiIsolate(target.name);
    final source = after.source;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('translate_extra_target_used_as_input'),
          content: Text(
            source != before.source && !source.isAuto
                ? l10n.translateExtraTargetUsedAsInputSource(
                    language,
                    bidiIsolate(source.name),
                  )
                : l10n.translateExtraTargetUsedAsInput(language),
          ),
          persist: true,
          showCloseIcon: true,
          action: SnackBarAction(
            label: l10n.commonUndo,
            onPressed: cubit.undoInsertExtraTranslation,
          ),
        ),
      );
  }

  Widget _content(BuildContext context, ExtraTranslation? translation) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final output = translation?.output ?? '';
    if (translation?.status == TranslateStatus.failure) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TranslateErrorView(
          error: translation!.error,
          dense: true,
          retrySemanticsLabel: l10n.translateExtraTargetRetry(
            bidiIsolate(target.name),
          ),
          onRetry: () => unawaited(
            context.read<TranslateCubit>().retryExtraTarget(target),
          ),
        ),
      );
    }
    if (output.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          translation?.status == TranslateStatus.translating
              ? l10n.translateTranslating
              : l10n.translateExtraTargetPending,
          style: muted,
        ),
      );
    }
    final stale = translation!.isStaleFor(state.input);
    return Semantics(
      hint: stale && translation.status != TranslateStatus.translating
          ? l10n.translateResultStaleHint
          : null,
      child: Opacity(
        opacity: stale ? staleOutputOpacity : 1,
        // Selectable text can be long-pressed: at least a 48 dp target.
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: double.infinity,
            minHeight: 48,
          ),
          child: SelectableText.rich(
            TextSpan(text: output, locale: localeForLanguage(target)),
            key: const Key('translate_extra_target_text'),
            style: theme.textTheme.bodyLarge?.copyWith(fontSize: 18),
            textDirection:
                textDirectionForLanguage(target) ??
                textDirectionForText(output),
          ),
        ),
      ),
    );
  }
}

/// Picks the extra target languages: the engine's target languages (not
/// the main target), searchable by name, native name and code, at most
/// `TranslateCubit.maxExtraTargets`. Changes apply at once
/// (`TranslateCubit.toggleExtraTarget`).
///
/// Picks the engine does not offer
/// (`TranslateState.unavailableExtraTargets`, e.g. a language picked with
/// another engine) are listed too, checked, after the other picks: the
/// subtitle says they are kept for an engine that offers them, they count
/// towards the limit, and unchecking one removes it. "Remove all" removes
/// them as well.
///
/// The title, actions, hint and search field scroll with the list, so the
/// languages stay reachable at any text size and on short screens; the
/// title and actions share a line while they fit. Once the most languages
/// are picked, the other rows are disabled and a note under the list (also
/// the rows' screen-reader hint, and announced) says why.
class ExtraTargetsSheet extends StatefulWidget {
  const new({super.key});

  @override
  State<ExtraTargetsSheet> createState() => _ExtraTargetsSheetState();
}

class _ExtraTargetsSheetState extends State<ExtraTargetsSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The engine's target languages other than the main target and the
  /// picks it does not offer, filtered by [_query]: the engine's chosen
  /// ones first, then the picks it does not offer, then the others.
  List<Language> _languages(TranslateState state) {
    final query = _query.trim().toLowerCase();
    bool matches(Language language) =>
        query.isEmpty ||
        language.name.toLowerCase().contains(query) ||
        (language.nativeName?.toLowerCase().contains(query) ?? false) ||
        language.code.toLowerCase() == query;
    final main = LanguageMatcher.normalize(state.target.code);
    final offered = [
      for (final language in state.targetLanguages)
        if (!language.isAuto &&
            !language.isCustom &&
            LanguageMatcher.normalize(language.code) != main &&
            matches(language))
          language,
    ];
    return [
      ...offered.where(state.isExtraTarget),
      ...state.unavailableExtraTargets.where(matches),
      ...offered.where((language) => !state.isExtraTarget(language)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<TranslateCubit>().state;
    final cubit = context.read<TranslateCubit>();
    // Picks the engine does not offer count too (they are listed).
    final full = state.extraTargets.length >= TranslateCubit.maxExtraTargets;
    final languages = _languages(state);
    final unavailable = state.unavailableExtraTargets;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The actions move under the title when both do not fit on one
          // line (large text, narrow screens).
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 0),
                child: Semantics(
                  header: true,
                  child: Text(
                    l10n.translateExtraTargetsTitle,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ),
              Wrap(
                children: [
                  if (state.extraTargets.isNotEmpty)
                    TextButton(
                      key: const Key('translate_extra_targets_clear'),
                      onPressed: () => cubit.setExtraTargets(const []),
                      child: Text(l10n.translateExtraTargetsClearAll),
                    ),
                  TextButton(
                    key: const Key('translate_extra_targets_done'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.translateExtraTargetsDone),
                  ),
                ],
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: Text(
              l10n.translateExtraTargetsHint(TranslateCubit.maxExtraTargets),
              key: const Key('translate_extra_targets_hint'),
              style: muted,
            ),
          ),
          Semantics(
            label: l10n.commonSearch,
            child: TextField(
              key: const Key('translate_extra_targets_search'),
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: l10n.translatePickerSearchHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l10n.commonClear,
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
                filled: true,
                border: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(28)),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    Widget row(Language language) {
      final kept = unavailable.contains(language);
      final checked = kept || state.isExtraTarget(language);
      final enabled = checked || !full;
      final native = language.nativeName;
      return CheckboxListTile(
        key: ValueKey('translate_extra_targets_${language.code}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 24),
        value: checked,
        title: Semantics(
          // Why the row is disabled (merged into the row).
          hint: enabled ? null : l10n.translateExtraTargetsLimitReached,
          child: Text(language.name),
        ),
        subtitle: kept
            ? Text(l10n.translateExtraTargetsKept)
            : native == null || native == language.name
            ? null
            : Text(
                native,
                locale: localeForLanguage(language),
                textDirection: textDirectionForLanguage(language),
              ),
        onChanged: enabled ? (_) => cubit.toggleExtraTarget(language) : null,
      );
    }

    final limit = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(24, 12, 24, 12 + keyboard),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.translateExtraTargetsLimitReached,
                key: const Key('translate_extra_targets_limit'),
                style: muted,
              ),
            ),
          ],
        ),
      ),
    );

    return StatusAnnouncer(
      message: full ? l10n.translateExtraTargetsLimitReached : null,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.4,
        builder: (context, controller) => Column(
          children: [
            Expanded(
              child: CustomScrollView(
                key: const Key('translate_extra_targets_list'),
                controller: controller,
                slivers: [
                  SliverToBoxAdapter(child: header),
                  if (languages.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            l10n.translatePickerNoResults(_query.trim()),
                            key: const Key(
                              'translate_extra_targets_no_results',
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                  else
                    SliverList.builder(
                      itemCount: languages.length,
                      itemBuilder: (context, index) => row(languages[index]),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.only(
                      bottom: 24 + (full ? 0 : keyboard),
                    ),
                  ),
                ],
              ),
            ),
            if (full) limit,
          ],
        ),
      ),
    );
  }
}
