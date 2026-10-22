import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/view/top_level_actions.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/fold_aware_split.dart';
import 'package:mozhi/core/widgets/tab_hero.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';
import 'package:mozhi/proofread/widgets/widgets.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/usage/usage.dart';
import 'package:translation_repository/translation_repository.dart';

/// Kagi-style proofreading. Uses the AI engines known to [TranslateCubit]
/// (defaulting to its assist engine).
///
/// [initialText] (from a link such as `/proofread?text=…`) is put into the
/// input, cut to [maxLinkTextLength]; it is never proofread without the
/// user asking. A different [initialText] later (another link while the
/// tab is alive) replaces the input again.
class ProofreadPage extends StatelessWidget {
  const new({this.initialText, super.key});

  /// Text handed over by a link; null or blank leaves the input alone.
  final String? initialText;

  /// Longest text a link may put into the input (the limit for text from
  /// outside the app, [TranslateCubit.maxExternalInputLength]).
  static const int maxLinkTextLength = TranslateCubit.maxExternalInputLength;

  @override
  Widget build(BuildContext context) {
    final uiLanguage = proofreadUiLanguage(Localizations.localeOf(context));
    return BlocProvider(
      create: (context) {
        final translate = context.read<TranslateCubit>().state;
        return ProofreadCubit(
          repository: context.read<TranslationRepository>(),
          engines: translate.engines,
          engine: translate.assistEngine,
          uiLanguage: uiLanguage,
          usageTracker: _usageTracker(context),
        );
      },
      child: _LinkedText(text: initialText, child: const ProofreadView()),
    );
  }
}

/// Puts link text into the [ProofreadCubit]'s input when it first arrives
/// and whenever it changes.
class _LinkedText extends StatefulWidget {
  const new({required this.text, required this.child});

  final String? text;
  final Widget child;

  @override
  State<_LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<_LinkedText> {
  @override
  void initState() {
    super.initState();
    _apply(widget.text);
  }

  @override
  void didUpdateWidget(_LinkedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) _apply(widget.text);
  }

  void _apply(String? text) {
    if (text == null || text.trim().isEmpty) return;
    context.read<ProofreadCubit>().setInput(
      _cut(text, ProofreadPage.maxLinkTextLength),
    );
  }

  /// [text] cut to [length] UTF-16 units without splitting a surrogate
  /// pair.
  static String _cut(String text, int length) {
    if (text.length <= length) return text;
    var end = length;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return text.substring(0, end);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// English name of the UI language, used for edit explanations.
String proofreadUiLanguage(Locale locale) {
  if (locale.languageCode == 'en') return 'English';
  return LanguageCatalog.byCode(locale.languageCode)?.name ?? 'English';
}

/// The proofreading screen, like Kagi Translate's.
///
/// Empty (no text, nothing checked, the field without focus): the
/// greeting ([ProofreadHero]) above the composer docked at the bottom, a
/// [ComposerCard] with the text field (paste and the microphone at its
/// top end) and the bar [options | go | language]
/// ([ProofreadComposerBar]). Options holds the correction level, style,
/// formality, reading level, region, model and context; the language
/// button picks the regional variety ("Detect language" keeps the
/// author's).
///
/// Active (the field has focus or text, or there is a result): like the
/// translate tab, the card's outline fades and it fills the screen: the
/// input with its toolbar above the result (the corrected text with its
/// diff and "Copy corrected text", the summary, the writing statistics and
/// the suggested edits, each with accept and reject buttons), side by side
/// from
/// [wideBreakpoint], with the bar docked at the bottom (above the
/// keyboard while it is open). It is one tree in both, so the field keeps
/// its focus, text and keyboard. Once there is a result the input shrinks
/// to its text. At a vertical hinge or half-opened fold the input and the
/// result are split at it, with the bar under the input.
///
/// The app bar shows the AI model in use ([ProofreadEngineChip]: beside
/// the title on large screens, instead of it on phones), like the
/// translate screen's engine.
class ProofreadView extends StatelessWidget {
  const new({super.key});

  /// Width from which input and result are shown side by side (also at
  /// any width on either side of a vertical hinge or half-opened fold).
  static const double wideBreakpoint = ComposerLayout.wideBreakpoint;

  @override
  Widget build(BuildContext context) {
    final hasEngines = context.select<ProofreadCubit, bool>(
      (cubit) => cubit.state.availableEngines.isNotEmpty,
    );
    final enginesStatus = context.select<TranslateCubit, EnginesStatus>(
      (cubit) => cubit.state.enginesStatus,
    );

    final Widget body;
    if (hasEngines) {
      body = LayoutBuilder(
        builder: (context, constraints) => _ProofreadBody(
          wide: constraints.maxWidth >= wideBreakpoint,
          fold: FoldAwareSplit.featureDirectionOf(context) == Axis.horizontal,
          height: constraints.maxHeight,
        ),
      );
    } else if (enginesStatus == EnginesStatus.loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (enginesStatus == EnginesStatus.failure) {
      // Loading failed, which says nothing about configured AI providers.
      body = ProofreadEnginesError(
        onRetry: () => unawaited(
          context.read<TranslateCubit>().loadEngines(refresh: true),
        ),
      );
    } else {
      body = const ProofreadEmptyState();
    }

    return BlocListener<TranslateCubit, TranslateState>(
      // Engine equality ignores details such as the model, so compare
      // instances to pick up edited providers.
      listenWhen: (previous, current) =>
          !identical(previous.engines, current.engines) ||
          !identical(previous.assistEngine, current.assistEngine),
      listener: (context, state) => context.read<ProofreadCubit>().setEngines(
        state.engines,
        preferred: state.assistEngine,
      ),
      child: Scaffold(
        appBar: AppBar(
          title: ComposerAppBarTitle(
            title: context.l10n.proofreadTitle,
            chip: hasEngines ? const ProofreadEngineChip() : null,
          ),
          actions: const [TopLevelActions(), SizedBox(width: 4)],
        ),
        body: SafeArea(top: false, child: body),
      ),
    );
  }
}

/// "Check your writing" with what proofreading does, above the docked
/// composer while there is nothing to check yet.
class ProofreadHero extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('proofread_hero'),
    padding: const EdgeInsets.all(24),
    child: TabHero(
      icon: Icons.spellcheck_rounded,
      title: context.l10n.proofreadHeroPrompt,
      body: context.l10n.proofreadHeroSubtitle,
    ),
  );
}

/// Whether [state] has nothing to show but the greeting and the composer:
/// no text, nothing checked or being checked, no error.
bool proofreadComposerIsIdle(ProofreadState state) =>
    state.input.isEmpty &&
    state.status == ProofreadStatus.idle &&
    state.result == null;

/// The proofreading screen below the app bar (see [ProofreadView]).
class _ProofreadBody extends StatefulWidget {
  const new({required this.wide, required this.fold, required this.height});

  final bool wide;

  /// Whether a vertical hinge or half-opened fold splits the screen.
  final bool fold;

  /// Height of the screen's content (without the keyboard).
  final double height;

  @override
  State<_ProofreadBody> createState() => _ProofreadBodyState();
}

class _ProofreadBodyState extends State<_ProofreadBody> {
  final _inputFocus = FocusNode(debugLabel: 'proofread_input');

  /// Whether the field had focus last time the screen counted it.
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _inputFocus
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    final focused = _inputFocus.hasFocus;
    if (focused == _focused) return;
    // A sheet or menu over the screen holds the focus for a while: keep
    // the layout under it (the focus comes back when it closes).
    if (!focused && !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fold) return _FoldLayout(focusNode: _inputFocus);
    final idle = context.select<ProofreadCubit, bool>(
      (cubit) => proofreadComposerIsIdle(cubit.state),
    );
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final hero =
        idle &&
        !_focused &&
        widget.height >= ComposerLayout.heroMinHeight(textScale);
    final wide = widget.wide;
    return ComposerLayout(
      docked: hero,
      wide: wide,
      hero: const ProofreadHero(),
      composer: ComposerCard(
        key: const Key('proofread_composer'),
        outlined: hero,
        expand: !hero,
        onTap: hero ? _inputFocus.requestFocus : null,
        flatBarPadding: wide
            ? const EdgeInsets.symmetric(vertical: 8)
            : const EdgeInsets.fromLTRB(16, 8, 16, 8),
        bar: const ProofreadComposerBar(),
        child: wide
            ? _WideRegion(hero: hero, focusNode: _inputFocus)
            : _NarrowRegion(hero: hero, focusNode: _inputFocus),
      ),
    );
  }
}

/// The input region on phones: the input and, once active, the result
/// below it, in one scroll view.
class _NarrowRegion extends StatelessWidget {
  const new({required this.hero, required this.focusNode});

  final bool hero;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final hasResult = context.select<ProofreadCubit, bool>(
      (cubit) => cubit.state.result != null,
    );
    return SingleChildScrollView(
      key: const Key('proofread_narrow_layout'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: hero ? const NeverScrollableScrollPhysics() : null,
      // In the card the text lines up with the translate composer's.
      padding: hero
          ? const EdgeInsetsDirectional.only(start: ComposerCard.padding)
          : const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: ComposerLayout.maxColumnWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              ProofreadInputCard(
                focusNode: focusNode,
                compact: hero,
                // Once there is a result the input fits its text.
                minLines: hero
                    ? 3
                    : hasResult
                    ? 1
                    : 6,
              ),
              if (!hero) const ProofreadResultSection(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The input region on large screens: the input pane and, once active, a
/// hairline and the result pane beside it.
class _WideRegion extends StatelessWidget {
  const new({required this.hero, required this.focusNode});

  final bool hero;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final hasResult = context.select<ProofreadCubit, bool>(
      (cubit) => cubit.state.result != null,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final result = hero ? 0.0 : (constraints.maxWidth - 1) / 2;
        return Row(
          key: const Key('proofread_wide_layout'),
          crossAxisAlignment: hero
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                key: const Key('proofread_input_pane'),
                physics: hero ? const NeverScrollableScrollPhysics() : null,
                padding: hero
                    ? const EdgeInsetsDirectional.only(
                        start: ComposerCard.padding,
                      )
                    : const EdgeInsetsDirectional.only(
                        top: 8,
                        end: 24,
                        bottom: 32,
                      ),
                child: ProofreadInputCard(
                  focusNode: focusNode,
                  compact: hero,
                  // Once there is a result the input fits its text.
                  minLines: hero
                      ? 3
                      : hasResult
                      ? 1
                      : 8,
                ),
              ),
            ),
            SizedBox(
              width: hero ? 0 : 1,
              child: hero ? null : const Hairline(vertical: true),
            ),
            SizedBox(
              width: result,
              child: hero
                  ? null
                  : const SingleChildScrollView(
                      key: Key('proofread_result_pane'),
                      padding: EdgeInsetsDirectional.only(
                        top: 8,
                        start: 24,
                        bottom: 32,
                      ),
                      child: ProofreadResultSection(showPlaceholder: true),
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// At a vertical hinge or half-opened fold: the input with the bar under
/// it and the result, split exactly at the fold.
class _FoldLayout extends StatelessWidget {
  const new({required this.focusNode});

  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return FoldAwareSplit(
      // The panes are divided by a hairline, not boxed.
      gap: 1,
      divider: const Hairline(vertical: true),
      foldDirections: const {Axis.horizontal},
      first: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: const Key('proofread_input_pane'),
              padding: const EdgeInsets.fromLTRB(24, 8, 12, 24),
              child: ProofreadInputCard(focusNode: focusNode, minLines: 8),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 12, 8),
            child: ProofreadComposerBar(),
          ),
        ],
      ),
      second: const SingleChildScrollView(
        key: Key('proofread_result_pane'),
        padding: EdgeInsets.fromLTRB(12, 8, 24, 24),
        child: ProofreadResultSection(showPlaceholder: true),
      ),
    );
  }
}

/// The app's usage tracker, or null when none is provided (e.g. in tests).
UsageTracker? _usageTracker(BuildContext context) {
  try {
    return context.read<UsageTracker>();
  } on ProviderNotFoundException {
    return null;
  }
}
