import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart' show AppLook;
import 'package:mozhi/core/haptics.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/cubit/translate_cubit.dart';
import 'package:mozhi/translate/widgets/detection_chips.dart';
import 'package:mozhi/translate/widgets/go_button.dart';
import 'package:mozhi/translate/widgets/language_picker_sheet.dart';
import 'package:mozhi/translate/widgets/options_sheet.dart';
import 'package:mozhi/translate/widgets/recent_pairs_sheet.dart';
import 'package:mozhi/translate/widgets/terminal_chrome.dart';
import 'package:mozhi/translate/widgets/translate_layout.dart';
import 'package:translation_repository/translation_repository.dart';

/// Opens the language picker for the source ([source]) or target language
/// and applies the choice. [autofocusSearch] focuses the search field
/// (type to filter, Enter picks the first match); by default it does on
/// large screens and after keyboard use (see [showLanguagePicker]).
///
/// Below the [TranslateLanguageAnchors] of the large-screen layout the
/// picker drops down under that side's language button
/// ([LanguagePaneHeader]), wherever it was opened from (the button, a
/// keyboard shortcut, the detected language chip).
Future<void> pickTranslateLanguage(
  BuildContext context, {
  required bool source,
  bool? autofocusSearch,
}) async {
  final cubit = context.read<TranslateCubit>();
  final anchor = TranslateLanguageAnchors.maybeOf(context)
      ?.rectOf(source: source);
  final picked = await showLanguagePicker(
    context,
    source: source,
    autofocusSearch: autofocusSearch,
    anchor: anchor,
  );
  if (picked == null) return;
  if (source) {
    cubit.setSource(picked);
  } else {
    cubit.setTarget(picked);
  }
}

/// Scripts used by essentially one language, so even a single word in them
/// is detected reliably (Hangul, kana, Thai, Greek, Georgian, Armenian,
/// Indic scripts other than Devanagari and Bengali, Sinhala, Myanmar, Khmer,
/// Lao, Tibetan, Ethiopic).
final _distinctiveScript = RegExp(
  '[Ͱ-Ͽ԰-֏਀-෿฀-໿ༀ-࿿'
  'က-႟Ⴀ-ჿᄀ-ᇿሀ-፿ក-៿'
  '぀-ヿ가-힯]',
);

/// Longest single word whose detected language is flagged as uncertain.
const uncertainDetectionMaxLength = 12;

/// Whether the detected source language may well be wrong: the source is
/// "Detect language" and the input is a single short word in a script that
/// several languages share (detectors often misjudge "Hallo", "Gift" or
/// "Bank").
bool detectionIsUncertain(TranslateState state) {
  if (!state.source.isAuto) return false;
  final detected = state.result?.detectedSource;
  if (detected == null || detected.isEmpty) return false;
  final text = state.input.trim();
  if (text.isEmpty || _distinctiveScript.hasMatch(text)) return false;
  return !text.contains(RegExp(r'\s')) &&
      text.characters.length <= uncertainDetectionMaxLength;
}

/// The language bar, like Kagi Translate's: one hairline-outlined pill
/// ([ComposerBar]) with the options button ([OptionsButton]) at the
/// start, the source button, the swap button and the target button, and
/// the go button ([TranslateGoButton]) at the end; thin dividers set the
/// options and go buttons off.
///
/// The source and target buttons share the space between the dividers:
/// half each while both names fit (the swap button then sits in the
/// middle, over the line between the panes of the wide layout); otherwise
/// the shorter name keeps its width and the longer one gets the rest.
///
/// A detection that may be wrong ([detectionLooksUncertain]: the engine
/// says so, or a single short word) reads "Detected: Dutch?" with a help
/// icon, like the chip under the translation.
///
/// Long-pressing the swap button opens the recent language pairs
/// ([showRecentPairsSheet]; also in the "More tools" menu for keyboard and
/// screen reader users).
///
/// Swapping ticks (a selection haptic) and turns the swap icon; a new
/// language name slides in along the bar's axis (the source's from the
/// target side, the target's from the source side) while the old one fades
/// out, like Material's shared-axis motion. A swap
/// ([translateLanguagesSwapped]) makes the two names trade places: each
/// slides all the way across to the other side while it cross-fades into
/// the other one's form ([languageSwapMotion]). No motion with reduced
/// motion.
///
/// Phones and narrow windows only: the large-screen layout puts the
/// languages above its panes ([LanguagePaneHeader]).
///
/// In the terminal look ([AppLook.isTerminal]) it is one hairline box of
/// three cells, `--from <source>` | `↔` | `--to <target>` (the source and
/// target halves of it each, the language by name or code as space
/// allows); the options and go buttons are in the input box there
/// (`InputCard`). Same buttons, labels, semantics and motion.
class LanguageBar extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    if (AppLook.of(context).isTerminal) {
      return const _TerminalLanguageBox(
        key: Key('translate_language_bar'),
        panes: false,
      );
    }
    // The shared composer bar (Dictionary and Proofread use it too).
    return const ComposerBar(
      key: Key('translate_language_bar'),
      children: [
        OptionsButton(),
        Expanded(child: _LanguagePair(panes: false)),
        TranslateGoButton(),
      ],
    );
  }
}

/// The languages of the large-screen layout, above its two panes (like
/// Google's and DeepL's): the source button over the input pane, the
/// target button over the output pane and the swap button between them,
/// over the line between the panes. The buttons are the [LanguageBar]'s
/// (same labels, forms, semantics and motion); the options and go buttons
/// sit under the input pane there.
///
/// Its buttons are the anchors of [TranslateLanguageAnchors] when one is
/// above (the picker drops down under them).
class LanguagePaneHeader extends StatelessWidget {
  const new({super.key});

  /// Height of the header.
  static const double height = 56;

  @override
  Widget build(BuildContext context) {
    if (AppLook.of(context).isTerminal) {
      return const _TerminalLanguageBox(
        key: Key('translate_language_header'),
        panes: true,
      );
    }
    return const SizedBox(
      key: Key('translate_language_header'),
      height: height,
      child: _LanguagePair(panes: true),
    );
  }
}

/// The terminal look's language bar: one hairline box around the
/// [_LanguagePair] ([LanguageBar], or with [panes] the
/// [LanguagePaneHeader], whose buttons are the picker anchors).
class _TerminalLanguageBox extends StatelessWidget {
  const new({required this.panes, super.key});

  final bool panes;

  /// Height of the cells at the normal text size.
  static const double height = 48;

  /// Height of the cells for [scaler]: [height], or a line of 15 dp text
  /// with room around it when larger text needs more.
  static double heightFor(TextScaler scaler) =>
      math.max(height, scaler.scale(15) * 1.4 + 12);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: AppPalette.of(context).hairline),
      ),
      child: SizedBox(
        height: heightFor(MediaQuery.textScalerOf(context)),
        child: _LanguagePair(panes: panes),
      ),
    );
  }
}

/// The global keys of the language buttons above the panes of the
/// large-screen layout ([LanguagePaneHeader]), so a language picker opened
/// from anywhere below (a keyboard shortcut, the detected language chip)
/// drops down under the right button ([pickTranslateLanguage]).
class TranslateLanguageAnchors extends InheritedWidget {
  const new({
    required this.source,
    required this.target,
    required super.child,
    super.key,
  });

  /// The key of the source language button.
  final GlobalKey source;

  /// The key of the target language button.
  final GlobalKey target;

  /// The nearest anchors above [context], if any.
  static TranslateLanguageAnchors? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TranslateLanguageAnchors>();

  /// The key of the source ([source]) or target button.
  GlobalKey keyOf({required bool source}) => source ? this.source : target;

  /// Where the source ([source]) or target button is, in global
  /// coordinates; null while it is not on the screen.
  Rect? rectOf({required bool source}) {
    final box = keyOf(source: source).currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  bool updateShouldNotify(TranslateLanguageAnchors oldWidget) =>
      source != oldWidget.source || target != oldWidget.target;
}

/// Whether [current] swapped the languages of [previous]
/// (`TranslateCubit.swap`): the new source is the old target and the new
/// target the old source (the detected language while it was "Detect
/// language"), matched like everywhere else ([LanguageMatcher]).
bool translateLanguagesSwapped(
  TranslateState previous,
  TranslateState current,
) {
  if (previous.source == current.source && previous.target == current.target) {
    return false;
  }
  bool same(Language language, Language other) =>
      LanguageMatcher.match(language, [other]) != null;
  if (!same(current.source, previous.target)) return false;
  if (!previous.source.isAuto) return same(current.target, previous.source);
  final detected = previous.result?.detectedSource;
  if (detected == null || detected.isEmpty) return false;
  return same(current.target, Language(code: detected, name: detected));
}

/// Source button, swap button and target button of the [LanguageBar]
/// ([panes] false: laid out by [_LanguagePairRow]) or of the
/// [LanguagePaneHeader] ([panes]: half the width each, the swap button in
/// the middle).
class _LanguagePair extends StatefulWidget {
  const new({required this.panes});

  final bool panes;

  @override
  State<_LanguagePair> createState() => _LanguagePairState();
}

class _LanguagePairState extends State<_LanguagePair> {
  /// The state of the last build.
  TranslateState? _last;

  /// Whether the last change of the languages was a swap.
  bool _swapped = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocBuilder<TranslateCubit, TranslateState>(
      buildWhen: (previous, current) =>
          previous.source != current.source ||
          previous.target != current.target ||
          previous.result?.detectedSource != current.result?.detectedSource ||
          detectionLooksUncertain(previous) !=
              detectionLooksUncertain(current) ||
          previous.sourceLanguages != current.sourceLanguages ||
          previous.canSwap != current.canSwap,
      builder: (context, state) {
        final last = _last;
        if (!identical(last, state)) {
          // Kept until the languages change again, so a rebuild in the
          // middle of the motion does not change its course.
          if (last == null ||
              last.source != state.source ||
              last.target != state.target) {
            _swapped = last != null && translateLanguagesSwapped(last, state);
          }
          _last = state;
        }
        final detected = state.result?.detectedSource;
        final uncertain = detectionLooksUncertain(state);
        final String sourceDescription;
        final List<LanguageLabelForm> sourceForms;
        var sourceTooltip = '';
        if (!state.source.isAuto) {
          sourceDescription = state.source.name;
          sourceForms = languageLabelForms(state.source);
        } else if (detected != null) {
          // The sparkle icon marks it as detected; keep the label short.
          final name = languageNameFor(detected, state.sourceLanguages);
          sourceDescription = uncertain
              ? l10n.translateDetectedLanguageUncertain(name)
              : l10n.translateDetectedLanguage(name);
          if (uncertain) {
            sourceTooltip =
                '$sourceDescription\n${l10n.translateDetectionUncertainHint}';
          }
          sourceForms = languageLabelForms(
            Language(code: detected, name: name),
            icon: uncertain ? Icons.help_outline : Icons.auto_awesome_outlined,
          );
        } else {
          sourceDescription = l10n.translateDetectLanguage;
          sourceForms = [
            (icon: null, text: sourceDescription),
            (
              icon: Icons.auto_awesome_outlined,
              text: l10n.translateDetectLanguageShort,
            ),
            (icon: Icons.auto_awesome_outlined, text: null),
          ];
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            // A swap carries each name across to the other button: about
            // half the row away (the buttons share it around the swap
            // button).
            final travel = _swapped && constraints.hasBoundedWidth
                ? constraints.maxWidth / 2
                : null;
            final sourceButton = _LanguageButton(
              key: const Key('translate_source_button'),
              forms: sourceForms,
              slideFrom: AxisDirection.right,
              travel: travel,
              semanticLabel: l10n.translateSourceLanguage(sourceDescription),
              tooltip: sourceTooltip.isEmpty
                  ? sourceDescription
                  : sourceTooltip,
              onPressed: () => pickTranslateLanguage(context, source: true),
            );
            final swap = _SwapButton(enabled: state.canSwap);
            final targetButton = _LanguageButton(
              key: const Key('translate_target_button'),
              forms: languageLabelForms(state.target),
              slideFrom: AxisDirection.left,
              travel: travel,
              semanticLabel: l10n.translateTargetLanguage(state.target.name),
              tooltip: state.target.name,
              target: true,
              onPressed: () => pickTranslateLanguage(context, source: false),
            );
            final anchors = TranslateLanguageAnchors.maybeOf(context);
            if (AppLook.of(context).isTerminal) {
              // Three cells: the halves and the swap between them.
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: KeyedSubtree(
                      key: widget.panes ? anchors?.source : null,
                      child: sourceButton,
                    ),
                  ),
                  swap,
                  Expanded(
                    child: KeyedSubtree(
                      key: widget.panes ? anchors?.target : null,
                      child: targetButton,
                    ),
                  ),
                ],
              );
            }
            if (!widget.panes) {
              return _LanguagePairRow(
                children: [sourceButton, swap, targetButton],
              );
            }
            Widget half(Widget button, GlobalKey? anchor) => Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: KeyedSubtree(key: anchor, child: button),
              ),
            );
            return Row(
              children: [
                half(sourceButton, anchors?.source),
                swap,
                half(targetButton, anchors?.target),
              ],
            );
          },
        );
      },
    );
  }
}

/// What a language button of the [LanguageBar] may show: an `icon` and/or
/// a `text` (both null: only the chevron).
typedef LanguageLabelForm = ({IconData? icon, String? text});

/// Short forms of the language [code] for a narrow [LanguageBar], longest
/// first: the code in upper case ("PT-BR") and, for a code with a region
/// or script, its language subtag ("PT"). Unlike the avatars' two letters
/// ([LanguageAvatar.initials]), three-letter codes stay whole ("FIL", not
/// "FI", which reads as Finnish).
List<String> languageShortNames(String code) {
  final upper = code.trim().toUpperCase();
  if (upper.isEmpty) return const [];
  final base = upper.split(RegExp('[-_ ]')).first;
  return [upper, if (base.isNotEmpty && base != upper) base];
}

/// What the [LanguageBar] shows for [language], in order of preference:
/// the name, then its short forms ([languageShortNames]; none for custom
/// languages), then only [icon] (custom languages: the sparkle) or nothing
/// but the chevron. With an [icon] (a detection), the short forms are also
/// tried without it before the icon alone: the language tells more than
/// the marker. Each form also goes without the chevron before the next one
/// is tried (see [_LanguageButton]).
List<LanguageLabelForm> languageLabelForms(
  Language language, {
  IconData? icon,
}) {
  final marker = icon ?? (language.isCustom ? Icons.auto_awesome : null);
  final shorts = language.isCustom
      ? const <String>[]
      : languageShortNames(language.code);
  return [
    (icon: marker, text: language.name),
    for (final short in shorts) (icon: marker, text: short),
    if (marker != null)
      for (final short in shorts) (icon: null, text: short),
    (icon: marker, text: null),
  ];
}

/// Widths of two language buttons sharing [width], whose own (maximum
/// intrinsic) widths are [start] and [end]: half each while both fit in
/// half; otherwise the narrower one keeps its own width (when it fits in
/// half) and the wider one gets the rest; half each when neither fits in
/// half.
(double, double) languagePairSplit(double width, double start, double end) {
  final available = math.max(0, width).toDouble();
  final half = available / 2;
  if (start <= half && end <= half) return (half, half);
  if (start <= half) return (start, available - start);
  if (end <= half) return (available - end, end);
  return (half, half);
}

/// Lays out three children in a row, in reading order: two language
/// buttons with a swap button between them. The swap button keeps its own
/// width; the language buttons share the rest ([languagePairSplit]).
/// Children are centred vertically, and the row is as tall as the tallest
/// of them.
class _LanguagePairRow extends MultiChildRenderObjectWidget {
  const new({required super.children})
    : assert(children.length == 3, 'source, swap and target');

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLanguagePair(textDirection: Directionality.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLanguagePair renderObject,
  ) {
    renderObject.textDirection = Directionality.of(context);
  }
}

class _PairParentData extends ContainerBoxParentData<RenderBox>;

/// The render object of [_LanguagePairRow].
class _RenderLanguagePair extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PairParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PairParentData> {
  new({required this._textDirection});

  TextDirection _textDirection;

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PairParentData) {
      child.parentData = _PairParentData();
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) => getChildrenAsList().fold(
    0,
    (sum, child) => sum + child.getMinIntrinsicWidth(height),
  );

  @override
  double computeMaxIntrinsicWidth(double height) => getChildrenAsList().fold(
    0,
    (sum, child) => sum + child.getMaxIntrinsicWidth(height),
  );

  @override
  double computeMinIntrinsicHeight(double width) => getChildrenAsList().fold(
    0,
    (tallest, child) =>
        math.max(tallest, child.getMinIntrinsicHeight(double.infinity)),
  );

  @override
  double computeMaxIntrinsicHeight(double width) => getChildrenAsList().fold(
    0,
    (tallest, child) =>
        math.max(tallest, child.getMaxIntrinsicHeight(double.infinity)),
  );

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, ChildLayoutHelper.dryLayoutChild).size;

  @override
  void performLayout() {
    final (:size, :widths) = _layout(
      constraints,
      ChildLayoutHelper.layoutChild,
    );
    this.size = size;
    final children = getChildrenAsList();
    final ordered = _textDirection == TextDirection.rtl
        ? children.reversed.toList()
        : children;
    final orderedWidths = _textDirection == TextDirection.rtl
        ? widths.reversed.toList()
        : widths;
    var x = 0.0;
    for (final (index, child) in ordered.indexed) {
      (child.parentData! as _PairParentData).offset = Offset(
        x,
        (size.height - child.size.height) / 2,
      );
      x += orderedWidths[index];
    }
  }

  /// Lays out (or dry lays out, with [layoutChild]) the children for
  /// [constraints]: the size of the row and the widths of the children.
  ({Size size, List<double> widths}) _layout(
    BoxConstraints constraints,
    ChildLayouter layoutChild,
  ) {
    final children = getChildrenAsList();
    assert(children.length == 3, '_LanguagePairRow needs three children');
    final [start, swap, end] = children;
    final swapWidth = swap.getMaxIntrinsicWidth(double.infinity);
    final startWidth = start.getMaxIntrinsicWidth(double.infinity);
    final endWidth = end.getMaxIntrinsicWidth(double.infinity);
    final (double, double) shared;
    if (constraints.hasBoundedWidth) {
      shared = languagePairSplit(
        constraints.maxWidth - swapWidth,
        startWidth,
        endWidth,
      );
    } else {
      shared = (startWidth, endWidth);
    }
    final widths = [shared.$1, swapWidth, shared.$2];
    var height = 0.0;
    for (final (index, child) in children.indexed) {
      final size = layoutChild(
        child,
        BoxConstraints.tightFor(width: widths[index])
            .copyWith(maxHeight: constraints.maxHeight),
      );
      height = math.max(height, size.height);
    }
    final size = constraints.constrain(
      Size(widths.fold(0, (sum, width) => sum + width), height),
    );
    return (size: size, widths: widths);
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Swaps the languages (a selection haptic, the icon turns half a turn); a
/// long press opens the recent language pairs.
class _SwapButton extends StatefulWidget {
  const new({required this.enabled});

  final bool enabled;

  @override
  State<_SwapButton> createState() => _SwapButtonState();
}

class _SwapButtonState extends State<_SwapButton> {
  /// Turns of the icon: half a turn per swap.
  double _turns = 0;

  void _swap() {
    Haptics.selection(context);
    setState(() => _turns += 0.5);
    context.read<TranslateCubit>().swap();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = widget.enabled;
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final terminal = AppLook.of(context).isTerminal;
    void showPairs() => unawaited(showRecentPairsSheet(context));
    // The tooltip shows on hover and focus only: a long press opens the
    // recent pairs instead.
    Widget button = MergeSemantics(
      child: Semantics(
        onLongPressHint: l10n.translateRecentPairsShow,
        child: Tooltip(
          message: l10n.translateSwapLanguages,
          triggerMode: TooltipTriggerMode.manual,
          child: IconButton(
            key: const Key('translate_swap_button'),
            style: terminal
                ? IconButton.styleFrom(
                    foregroundColor: accent,
                    shape: const RoundedRectangleBorder(),
                    minimumSize: const Size(_terminalWidth - 2, 48),
                  )
                : IconButton.styleFrom(foregroundColor: accent),
            icon: AnimatedRotation(
              turns: _turns,
              duration: languageSwapMotion(context),
              curve: Curves.easeInOutCubic,
              // The terminal look's glyph is decoration, like the icon
              // (`↔`: the bundled font has no `⇄`, and a missing glyph
              // would make the web app fetch a fallback font).
              child: terminal
                  ? TerminalGlyph(
                      '↔',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: enabled
                            ? accent
                            : AppPalette.of(context).secondaryText,
                      ),
                    )
                  : const Icon(Icons.swap_horiz),
            ),
            onPressed: enabled ? _swap : null,
            onLongPress: showPairs,
          ),
        ),
      ),
    );
    if (terminal) {
      // The middle cell, set off by hairlines on both sides.
      final side = BorderSide(color: AppPalette.of(context).hairline);
      button = DecoratedBox(
        decoration: BoxDecoration(
          border: BorderDirectional(start: side, end: side),
        ),
        child: SizedBox(
          width: _terminalWidth,
          child: Center(child: button),
        ),
      );
    }
    if (enabled) return button;
    // A disabled button ignores long presses; the pairs stay reachable.
    return GestureDetector(
      excludeFromSemantics: true,
      onLongPress: showPairs,
      child: button,
    );
  }

  /// Width of the swap cell of the terminal look's language box.
  static const double _terminalWidth = 52;
}

/// Duration of the swap motion (the swap icon's turn, the names trading
/// places); zero with reduced motion.
Duration languageSwapMotion(BuildContext context) =>
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
    ? Duration.zero
    : const Duration(milliseconds: 200);

/// A language button of the [LanguageBar]: an optional icon, the name (the
/// target's a little bolder) and a chevron, on the bar without an outline
/// of its own.
///
/// It shows the first of [forms] that fits whole, never a cut name: the
/// name, then the short forms ("DE", or the sparkle and "Auto" for "Detect
/// language"), each first with the chevron and then without it (the
/// chevron only decorates; the whole button opens the picker); the text
/// is left out only when no form fits. The full name stays in [tooltip]
/// and, for screen readers, in [semanticLabel], which replaces the visible
/// content (the button keeps its own semantics: tap action, enabled state,
/// focus). A new name slides in from [slideFrom] (mirrored in right-to-left
/// layouts), from [travel] logical pixels away when given (a swap).
class _LanguageButton extends StatelessWidget {
  const new({
    required this.forms,
    required this.semanticLabel,
    required this.tooltip,
    required this.onPressed,
    required this.slideFrom,
    this.travel,
    this.target = false,
    super.key,
  });

  /// The side a new label slides in from (in a left-to-right layout).
  final AxisDirection slideFrom;

  /// How far (logical pixels) a new label travels, and the old one with
  /// it (see [_SharedAxisSwitcher.travel]); null: a short slide.
  final double? travel;

  /// Whether this is the target language (bolder, like the translation's
  /// header).
  final bool target;

  /// What the button may show, in order of preference.
  final List<LanguageLabelForm> forms;
  final String semanticLabel;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);
    final style = theme.textTheme.titleSmall?.copyWith(
      fontWeight: target ? FontWeight.w800 : FontWeight.w700,
    );

    Widget content(LanguageLabelForm form, {required bool chevron}) {
      final (:icon, :text) = form;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) Icon(icon, size: 18, color: scheme.primary),
          if (icon != null && text != null) const SizedBox(width: 6),
          if (text != null)
            _SharedAxisSwitcher(
              slideFrom: slideFrom,
              travel: travel,
              child: Text(
                text,
                key: ValueKey(text),
                maxLines: 1,
                softWrap: false,
                style: style,
              ),
            ),
          if (chevron) ...[
            if (icon != null || text != null) const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 16, color: palette.secondaryText),
          ],
        ],
      );
    }

    if (AppLook.of(context).isTerminal) return _terminal(context);

    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsetsDirectional.only(start: 8, end: 2),
          shape: AppLook.of(context).control,
          foregroundColor: scheme.onSurface,
          backgroundColor: Colors.transparent,
        ),
        onPressed: onPressed,
        child: Semantics(
          label: semanticLabel,
          // Hides only the visible content, not the button's actions.
          excludeSemantics: true,
          child: FirstThatFits(
            children: [
              for (final form in forms) ...[
                content(form, chevron: true),
                // Without anything else, the chevron is all there is.
                if (form.icon != null || form.text != null)
                  content(form, chevron: false),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The terminal look's cell: `--from <language>` (`--to` for the
  /// target) with the first form that fits (the name, else the code),
  /// else the first form that fits without the flag; no chevron, language
  /// codes in lower case (`en`, `pt-br`). Same tooltip, semantics and
  /// motion.
  Widget _terminal(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.titleSmall?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w700,
    );
    final flag = target ? '--to' : '--from';

    Widget content(LanguageLabelForm form, {required bool flagged}) {
      final (:icon, :text) = form;
      // Codes ("EN", "PT-BR") read like the command line's.
      final shown = text == null || text != text.toUpperCase()
          ? text
          : text.toLowerCase();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The space apart from the flag, so it stays between the two in
          // right-to-left layouts too.
          if (flagged) ...[
            TerminalGlyph(flag, style: style),
            TerminalGlyph(' ', style: style),
          ],
          if (icon != null) Icon(icon, size: 18, color: scheme.primary),
          if (icon != null && shown != null) const SizedBox(width: 6),
          if (shown != null)
            _SharedAxisSwitcher(
              slideFrom: slideFrom,
              travel: travel,
              child: Text(
                shown,
                key: ValueKey(shown),
                maxLines: 1,
                softWrap: false,
                style: style,
              ),
            ),
        ],
      );
    }

    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: const RoundedRectangleBorder(),
          foregroundColor: scheme.onSurface,
          backgroundColor: Colors.transparent,
        ),
        onPressed: onPressed,
        child: Semantics(
          label: semanticLabel,
          excludeSemantics: true,
          // With the flag while any form fits with it ("--from en"), then
          // without it.
          child: FirstThatFits(
            children: [
              for (final form in forms)
                if (form.icon != null || form.text != null)
                  content(form, flagged: true),
              for (final form in forms) content(form, flagged: false),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the first of its children that fits the available width whole
/// (by its maximum intrinsic width), or none of them when none fits. As
/// wide as its first child would like to be (its maximum intrinsic width),
/// so that a parent sharing out space (like [languagePairSplit]) plans for
/// the preferred form.
///
/// The other children are laid out at their own width but neither painted,
/// hit-tested, nor visible to semantics or (onstage) test finders.
class FirstThatFits extends MultiChildRenderObjectWidget {
  const new({required super.children, super.key});

  @override
  MultiChildRenderObjectElement createElement() => _FirstThatFitsElement(this);

  @override
  RenderBox createRenderObject(BuildContext context) => _RenderFirstThatFits();
}

class _FirstThatFitsElement extends MultiChildRenderObjectElement {
  new(FirstThatFits super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    // Only the child shown is onstage (like IndexedStack's).
    final shown = (renderObject as _RenderFirstThatFits).shown;
    if (shown != null && shown < children.length) {
      visitor(children.elementAt(shown));
    }
  }
}

class _FirstThatFitsParentData extends ContainerBoxParentData<RenderBox>;

/// The render object of [FirstThatFits].
class _RenderFirstThatFits extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FirstThatFitsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FirstThatFitsParentData> {
  /// Rounding slack when comparing widths.
  static const _tolerance = 1e-6;

  /// Index of the child shown by the last layout (null: none).
  int? get shown => _shown;
  int? _shown;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FirstThatFitsParentData) {
      child.parentData = _FirstThatFitsParentData();
    }
  }

  /// The index of the first child that fits [maxWidth] whole (the first
  /// one when the width is unbounded), or null.
  int? _pick(double maxWidth) {
    final children = getChildrenAsList();
    if (children.isEmpty) return null;
    if (maxWidth.isInfinite) return 0;
    for (final (index, child) in children.indexed) {
      final width = child.getMaxIntrinsicWidth(double.infinity);
      if (width <= maxWidth + _tolerance) return index;
    }
    return null;
  }

  RenderBox? _child(int? index) =>
      index == null ? null : getChildrenAsList()[index];

  /// Children get their own width (a form is only shown when it fits).
  static BoxConstraints _childConstraints(BoxConstraints constraints) =>
      BoxConstraints(maxHeight: constraints.maxHeight);

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      firstChild?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      _child(_pick(width))?.getMinIntrinsicHeight(double.infinity) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _child(_pick(width))?.getMaxIntrinsicHeight(double.infinity) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = _child(_pick(constraints.maxWidth));
    return constraints.constrain(
      child?.getDryLayout(_childConstraints(constraints)) ?? Size.zero,
    );
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final child = _child(_pick(constraints.maxWidth));
    if (child == null) return null;
    final inner = _childConstraints(constraints);
    final size = constraints.constrain(child.getDryLayout(inner));
    final offset = _centered(size, child.getDryLayout(inner));
    final distance = child.getDryBaseline(inner, baseline);
    return distance == null ? null : distance + offset.dy;
  }

  static Offset _centered(Size size, Size child) =>
      Offset((size.width - child.width) / 2, (size.height - child.height) / 2);

  @override
  void performLayout() {
    final inner = _childConstraints(constraints);
    for (final child in getChildrenAsList()) {
      child.layout(inner, parentUsesSize: true);
    }
    _shown = _pick(constraints.maxWidth);
    final shown = _child(_shown);
    size = constraints.constrain(shown?.size ?? Size.zero);
    for (final child in getChildrenAsList()) {
      (child.parentData! as _FirstThatFitsParentData).offset = _centered(
        size,
        child.size,
      );
    }
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final shown = _child(_shown);
    if (shown == null) return null;
    final distance = shown.getDistanceToActualBaseline(baseline);
    final offset = (shown.parentData! as _FirstThatFitsParentData).offset;
    return distance == null ? null : distance + offset.dy;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final shown = _child(_shown);
    if (shown == null) return;
    final childOffset = (shown.parentData! as _FirstThatFitsParentData).offset;
    context.paintChild(shown, offset + childOffset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final shown = _child(_shown);
    if (shown == null) return false;
    final offset = (shown.parentData! as _FirstThatFitsParentData).offset;
    return result.addWithPaintOffset(
      offset: offset,
      position: position,
      hitTest: (result, transformed) =>
          shown.hitTest(result, position: transformed),
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final shown = _child(_shown);
    if (shown != null) visitor(shown);
  }
}

/// Switches [child] (told apart by its key) like Material's horizontal
/// shared-axis transition: the new one slides in from [slideFrom] while
/// fading in, the old one slides out the other way while fading out.
///
/// With a [travel] (a swap) both labels move the same way over that
/// distance instead: the old one on towards the other language button, the
/// new one in from it, so the two names trade places while they
/// cross-fade.
class _SharedAxisSwitcher extends StatelessWidget {
  const new({required this.slideFrom, required this.child, this.travel});

  final AxisDirection slideFrom;
  final Widget child;

  /// How far (logical pixels) the labels travel on a swap; null: a short
  /// shared-axis slide.
  final double? travel;

  /// How far a label travels, as a share of its width.
  static const _travel = 0.3;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final rtl = direction == TextDirection.rtl;
    final fromRight = (slideFrom == AxisDirection.right) != rtl;
    final current = child.key;
    return AnimatedSwitcher(
      duration: languageSwapMotion(context),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      // As big as the new label alone (positioned children do not count):
      // the button picks its form ([FirstThatFits]) and its width for the
      // new name, not for the wider of the two while the old one fades out.
      layoutBuilder: (current, previous) => Stack(
        alignment: AlignmentDirectional.centerStart,
        clipBehavior: Clip.none,
        children: [
          for (final outgoing in previous)
            Positioned.directional(
              textDirection: direction,
              start: 0,
              child: outgoing,
            ),
          ?current,
        ],
      ),
      transitionBuilder: (child, animation) {
        final swap = travel;
        if (swap != null) {
          // Both on [slideFrom]'s side: the incoming label comes from
          // there, the outgoing one (its animation runs backwards) goes
          // there.
          final towards = fromRight ? 1.0 : -1.0;
          return FadeTransition(
            opacity: animation,
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, child) => Transform.translate(
                offset: Offset(towards * swap * (1 - animation.value), 0),
                child: child,
              ),
              child: child,
            ),
          );
        }
        // The incoming label enters from [slideFrom]; the outgoing one
        // (its animation runs backwards) leaves to the opposite side.
        final incoming = child.key == current;
        final sign = (fromRight ? 1.0 : -1.0) * (incoming ? 1 : -1);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(_travel * sign, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
