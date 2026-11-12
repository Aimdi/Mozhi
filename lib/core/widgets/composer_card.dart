import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/focus_ring.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/terminal_chrome.dart';
import 'package:translation_repository/translation_repository.dart';

/// The fill of a [ComposerCard] on [scheme]'s page: a shade off the page
/// (`surfaceContainerLow`) while quiet text ([secondaryText]) keeps its
/// contrast on it (WCAG 1.4.3), else the page itself. The translate
/// composer is filled the same way.
Color composerFill(ColorScheme scheme, Color secondaryText) {
  final fill = scheme.surfaceContainerLow;
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  return contrast(secondaryText, fill) >= 4.5 ? fill : scheme.surface;
}

/// The style of a composer's small icon tools in the terminal look (the
/// card's [ComposerCard.actions], the options button): a square in the
/// hairline of the translate screen's framed tools ([TerminalFrame]), a
/// 40 dp box in a 48 dp target at any density, in the text colour.
/// [framed] false leaves the hairline out (a tool inside a [ComposerBar]
/// cell, which its outline and dividers already frame).
ButtonStyle composerTerminalToolStyle(
  BuildContext context, {
  bool framed = true,
}) {
  final scheme = Theme.of(context).colorScheme;
  final palette = AppPalette.of(context);
  return IconButton.styleFrom(
    foregroundColor: scheme.onSurface,
    disabledForegroundColor: palette.secondaryText,
    shape: const RoundedRectangleBorder(),
    side: framed ? BorderSide(color: palette.hairline) : null,
    minimumSize: const Size.square(ComposerGoButton.visualSize),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.padded,
  );
}

/// Duration of the composer's motion (the card's outline fading, the
/// greeting giving way); zero with reduced motion.
Duration composerMotion(BuildContext context) =>
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
    ? Duration.zero
    : const Duration(milliseconds: 200);

/// The composer of an empty screen, like the translate tab's (and Kagi
/// Translate's): a card with a hairline outline and a quiet fill
/// ([composerFill]), rounded like the app's large surfaces
/// ([AppRadius.sheet]; square in the terminal look). It holds the text
/// field ([child]), accent [actions] at its top end (microphone, paste,
/// clear) and a [bar] at the bottom (usually a [ComposerBar]).
///
/// [outlined] false fades the outline and the fill away, so the same
/// tree turns into a flat screen (the field keeps its focus, text and
/// keyboard); with [expand] the field's row then fills the height it is
/// given (e.g. a scroll view of the input and its result) and the bar
/// sits at the bottom with [flatBarPadding] around it.
///
/// Taps on the card's empty space call [onTap] (focus the field), also
/// taps on its [margin] (animated like the outline).
///
/// In the terminal look ([AppLook.isTerminal]) it is the translate
/// screen's `stdin` box ([TerminalPanel]): square, a hairline border on
/// the raised panel colour, the `stdin` label (while [outlined]), an
/// accent `>` prompt before [child] and the [actions] as framed square
/// tools. Same tree, focus and semantics in both looks.
class ComposerCard extends StatelessWidget {
  const new({
    required this.child,
    this.actions = const [],
    this.bar,
    this.outlined = true,
    this.expand = false,
    this.onTap,
    this.flatBarPadding = const EdgeInsets.fromLTRB(16, 8, 16, 8),
    this.margin = EdgeInsets.zero,
    super.key,
  });

  /// Corner radius of the card in the classic look ([AppRadius.sheet],
  /// like the translate composer); the card follows [AppLook.sheet] (0 in
  /// the terminal look).
  static const double radius = AppRadius.sheet;

  /// Space between the outline and what is inside it.
  static const double padding = 6;

  /// Space above the terminal look's `>` prompt, so it sits on about the
  /// first line of the field's text.
  static const double promptTop = 10;

  /// The text field, or the region holding it.
  final Widget child;

  /// Accent buttons at the top end, beside [child].
  final List<Widget> actions;

  /// The bar at the bottom of the card.
  final Widget? bar;

  /// Whether the card shows its outline and fill.
  final bool outlined;

  /// Whether [child]'s row fills the height the card is given.
  final bool expand;

  /// Called for taps on the card's empty space.
  final VoidCallback? onTap;

  /// Padding around [bar] while the card is not [outlined].
  final EdgeInsetsGeometry flatBarPadding;

  /// Space around the card; changes animate (e.g. a docked card's margin
  /// giving way when it turns flat).
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final motion = composerMotion(context);
    final fill = composerFill(scheme, AppPalette.of(context).secondaryText);
    final accent = scheme.primary;
    final bar = this.bar;
    final corners = AppLook.of(context).sheetRadius;
    final card = AppLook.of(context).isTerminal
        ? _terminal(context, motion)
        : AnimatedContainer(
            duration: motion,
            curve: Curves.easeOutCubic,
            margin: margin,
            padding: EdgeInsets.all(outlined ? padding : 0),
            decoration: BoxDecoration(
              color: outlined ? fill : fill.withValues(alpha: 0),
              // No border at all once flat (a transparent one would still take
              // a pixel).
              border: Border.fromBorderSide(
                // A control's outline (3:1, WCAG 1.4.11), not a hairline.
                outlined ? BorderSide(color: scheme.outline) : BorderSide.none,
              ),
              borderRadius: corners,
            ),
            child: Column(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  flex: expand ? 1 : 0,
                  fit: expand ? FlexFit.tight : FlexFit.loose,
                  child: Row(
                    crossAxisAlignment: expand
                        ? CrossAxisAlignment.stretch
                        : CrossAxisAlignment.start,
                    children: [
                      Expanded(child: child),
                      if (actions.isNotEmpty)
                        Align(
                          alignment: AlignmentDirectional.topEnd,
                          child: IconButtonTheme(
                            data: IconButtonThemeData(
                              style: IconButton.styleFrom(
                                foregroundColor: accent,
                                disabledForegroundColor: accent.withValues(
                                  alpha: 0.38,
                                ),
                              ),
                            ),
                            child: Row(
                              key: const Key('composer_actions'),
                              mainAxisSize: MainAxisSize.min,
                              children: actions,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (bar != null)
                  AnimatedPadding(
                    duration: motion,
                    curve: Curves.easeOutCubic,
                    padding: outlined
                        ? const EdgeInsets.only(top: 4)
                        : flatBarPadding,
                    child: bar,
                  ),
              ],
            ),
          );
    return _tappable(card, corners);
  }

  /// [card] with the taps on its empty space and the focus ring.
  Widget _tappable(Widget card, BorderRadius corners) {
    // Always there (with or without [onTap]), so the tree, and the text
    // field's focus and keyboard with it, stays the same when the card
    // turns flat.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      onTap: onTap,
      // Keyboard focus in the field: an accent ring around the card (the
      // field itself draws no border).
      child: FocusRing.field(
        enabled: outlined,
        margin: margin,
        shape: RoundedRectangleBorder(borderRadius: corners),
        child: card,
      ),
    );
  }

  /// The terminal look's card (see [ComposerCard]): the same structure as
  /// the classic one, so nothing loses its state when the look or
  /// [outlined] changes.
  Widget _terminal(BuildContext context, Duration motion) {
    final scheme = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final fill = scheme.surfaceContainer;
    final bar = this.bar;
    return AnimatedContainer(
      duration: motion,
      curve: Curves.easeOutCubic,
      margin: margin,
      padding: EdgeInsets.all(outlined ? TerminalPanel.padding : 0),
      decoration: BoxDecoration(
        color: outlined ? fill : fill.withValues(alpha: 0),
        border: Border.fromBorderSide(
          outlined ? BorderSide(color: palette.hairline) : BorderSide.none,
        ),
        // Square ([AppLook.sheet] is 0 in the terminal look).
        borderRadius: AppLook.of(context).sheetRadius,
      ),
      child: Column(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Always a first child, so the field's row keeps its place.
          if (outlined)
            Padding(
              padding: const EdgeInsets.only(bottom: TerminalPanel.labelGap),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: TerminalGlyph(
                  'stdin',
                  key: const Key('composer_terminal_label'),
                  style: TerminalStyles.label(context),
                ),
              ),
            )
          else
            const SizedBox.shrink(),
          Flexible(
            flex: expand ? 1 : 0,
            fit: expand ? FlexFit.tight : FlexFit.loose,
            child: Row(
              crossAxisAlignment: expand
                  ? CrossAxisAlignment.stretch
                  : CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: AlignmentDirectional.topStart,
                  child: Padding(
                    // About the first line of the fields' text.
                    padding: const EdgeInsets.only(top: promptTop),
                    child: TerminalGlyph(
                      rtl ? '<' : '>',
                      key: const Key('composer_terminal_prompt'),
                      style: TerminalStyles.prompt(context),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(child: child),
                if (actions.isNotEmpty)
                  Align(
                    alignment: AlignmentDirectional.topEnd,
                    child: IconButtonTheme(
                      data: IconButtonThemeData(
                        style: composerTerminalToolStyle(context),
                      ),
                      child: Row(
                        key: const Key('composer_actions'),
                        mainAxisSize: MainAxisSize.min,
                        spacing: 2,
                        children: actions,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (bar != null)
            AnimatedPadding(
              duration: motion,
              curve: Curves.easeOutCubic,
              padding: outlined
                  ? const EdgeInsets.only(top: 8)
                  : flatBarPadding,
              child: bar,
            ),
        ],
      ),
    );
  }
}

/// An outlined pill holding the controls of a composer, like the
/// translate screen's language bar: [children] in a row with thin
/// vertical dividers ([ComposerBarDivider]) between them. Wrap one child
/// in an [Expanded] to give it the rest of the width (e.g. the language
/// button of `[options | go | language]`). In the terminal look a square
/// box in the hairline of the translate screen's language box.
class ComposerBar extends StatelessWidget {
  const new({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // A control's outline (3:1, WCAG 1.4.11), not a separator hairline;
    // the terminal look's boxes are all drawn in the hairline.
    final outline = AppLook.of(context).isTerminal
        ? AppPalette.of(context).hairline
        : Theme.of(context).colorScheme.outline;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: AppLook.of(context).control
            .copyWith(side: BorderSide(color: outline)),
      ),
      child: Padding(
        // Inside the outline.
        padding: const EdgeInsets.all(1),
        child: Row(
          children: [
            for (final (index, child) in children.indexed) ...[
              if (index > 0) const ComposerBarDivider(),
              child,
            ],
          ],
        ),
      ),
    );
  }
}

/// A short vertical hairline between the parts of a [ComposerBar].
class ComposerBarDivider extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: SizedBox(
        width: 1,
        height: 24,
        child: ColoredBox(color: AppPalette.of(context).hairline),
      ),
    );
  }
}

/// The options button at the start of a [ComposerBar]: an accent "tune"
/// icon with a small dot while the options differ from their defaults
/// ([modified]); a square tool in the text colour in the terminal look
/// (like the translate screen's options tool).
class ComposerOptionsButton extends StatelessWidget {
  const new({
    required this.tooltip,
    required this.onPressed,
    this.modified = false,
    super.key,
  });

  /// Also the button's accessible name.
  final String tooltip;
  final VoidCallback? onPressed;

  /// Whether the options differ from their defaults (a dot on the icon).
  final bool modified;

  @override
  Widget build(BuildContext context) {
    final terminal = AppLook.of(context).isTerminal;
    return IconButton(
      tooltip: tooltip,
      style: terminal
          ? composerTerminalToolStyle(context, framed: false)
          : null,
      color: terminal ? null : Theme.of(context).colorScheme.primary,
      icon: Badge(
        isLabelVisible: modified,
        smallSize: 8,
        child: const Icon(Icons.tune),
      ),
      onPressed: onPressed,
    );
  }
}

/// The go button of a [ComposerBar], at its trailing end on every screen
/// (Translate, Dictionary, Proofread): an accent circle of [visualSize]
/// with a forward arrow (mirrored right to left) inside a [targetSize]
/// touch target, so it always fits the bar. While disabled ([onPressed]
/// null) only a faint arrow is left (no grey disc).
///
/// Its accessible name is [label] ("Look up", "Proofread"); the tooltip
/// shows [tooltip] (e.g. with the keyboard shortcut), else [label]. While
/// [busy] a progress ring turns around it (decorative: the screen
/// announces the progress itself).
///
/// In the terminal look it is the translate screen's `run ⏎`: an accent
/// box (a hairline one with the accent text while busy, its progress ring
/// before the text; the secondary text while disabled). The same name,
/// tooltip and action.
class ComposerGoButton extends StatelessWidget {
  const new({
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.busy = false,
    this.icon = defaultIcon,
    super.key,
  });

  /// The go arrow of every composer.
  static const IconData defaultIcon = Icons.arrow_forward_rounded;

  /// Diameter of the visible circle.
  static const double visualSize = 40;

  /// Side of the touch target around it (and of the button's layout).
  static const double targetSize = 48;

  /// Diameter of the progress ring while [busy].
  static const double ringSize = 44;

  /// The style of a go button on [scheme]: filled with the accent, or
  /// [tonal] (a stop button); disabled, only a faint icon. A
  /// [visualSize] circle in a [targetSize] target at any density.
  static ButtonStyle styleOf(ColorScheme scheme, {bool tonal = false}) =>
      IconButton.styleFrom(
        fixedSize: const Size.square(visualSize),
        minimumSize: const Size.square(visualSize),
        maximumSize: const Size.square(visualSize),
        padding: EdgeInsets.zero,
        iconSize: 22,
        tapTargetSize: MaterialTapTargetSize.padded,
        visualDensity: VisualDensity.standard,
        backgroundColor: tonal ? scheme.secondaryContainer : scheme.primary,
        foregroundColor: tonal ? scheme.onSecondaryContainer : scheme.onPrimary,
        disabledBackgroundColor: Colors.transparent,
        disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
      );

  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (AppLook.of(context).isTerminal) return _terminal(context);
    return SizedBox.square(
      dimension: targetSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Its own node, so the button keeps exactly [label] as its name.
          Semantics(
            container: true,
            child: Tooltip(
              message: tooltip ?? label,
              excludeFromSemantics: true,
              child: IconButton(
                style: styleOf(scheme),
                onPressed: onPressed,
                icon: Icon(icon, semanticLabel: label),
              ),
            ),
          ),
          if (busy)
            const IgnorePointer(
              child: ExcludeSemantics(
                child: SizedBox.square(
                  dimension: ringSize,
                  child: CircularProgressIndicator(
                    key: Key('composer_go_progress'),
                    strokeWidth: 2.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The terminal look's `run ⏎` (see [ComposerGoButton]).
  Widget _terminal(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);
    final filled = onPressed != null && !busy;
    return Semantics(
      container: true,
      child: Tooltip(
        message: tooltip ?? label,
        excludeFromSemantics: true,
        child: TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(64, visualSize),
            tapTargetSize: MaterialTapTargetSize.padded,
            visualDensity: VisualDensity.standard,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: filled ? scheme.primary : palette.hairline,
              ),
            ),
            backgroundColor: filled ? scheme.primary : Colors.transparent,
            foregroundColor: filled ? scheme.onPrimary : scheme.primary,
            disabledBackgroundColor: Colors.transparent,
            disabledForegroundColor: palette.secondaryText,
            textStyle: theme.textTheme.labelLarge?.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          onPressed: onPressed,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy) ...[
                const ExcludeSemantics(
                  child: SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      key: Key('composer_go_progress'),
                      strokeWidth: 2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Semantics(
                  label: label,
                  excludeSemantics: true,
                  child: const TerminalGlyph('run ⏎'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The AI model a composer screen uses (Dictionary, Proofread), as a
/// small outlined pill for its app bar in the look of the translate
/// screen's engine selector: an icon, the model's name and (while it fits,
/// up to 130 % text) its subtitle, e.g. the model id.
///
/// Tapping it opens a menu of [engines] (the current one checked) that
/// picks one with [onSelected], and, with [onManage], "AI providers" (the
/// provider settings). Screen readers hear "AI model: Claude".
///
/// In the terminal look it is the translate screen's engine selector:
/// `● <name>` and a chevron, no outline, icon or subtitle (the subtitle,
/// e.g. the model id, is in the tooltip). The same name, menu and action.
class ComposerEngineChip extends StatelessWidget {
  const new({
    required this.engine,
    this.engines = const [],
    this.onSelected,
    this.onManage,
    super.key,
  });

  /// Above this text scale the subtitle is left out, so the chip still
  /// fits the app bar.
  static const double subtitleMaxTextScale = 1.3;

  /// The model in use.
  final TranslationEngine engine;

  /// The models to choose from (the menu lists them when there are two or
  /// more, or one that is not [engine]).
  final List<TranslationEngine> engines;

  final ValueChanged<TranslationEngine>? onSelected;

  /// Opens the AI provider settings.
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final largeText =
        MediaQuery.textScalerOf(context).scale(1) > subtitleMaxTextScale;
    final subtitle = largeText ? null : engine.subtitle?.trim();
    final onSelected = this.onSelected;
    final onManage = this.onManage;
    final choices = onSelected == null ? const <TranslationEngine>[] : engines;
    final showChoices =
        choices.length > 1 || choices.any((e) => e.id != engine.id);
    final terminal = AppLook.of(context).isTerminal;
    return MenuAnchor(
      menuChildren: [
        if (showChoices)
          for (final option in choices)
            MenuItemButton(
              key: ValueKey('composer_engine:${option.id}'),
              leadingIcon: Icon(
                Icons.check,
                color: option.id == engine.id ? null : Colors.transparent,
              ),
              onPressed: () => onSelected?.call(option),
              // The check mark is decorative: expose the choice as state.
              child: Semantics(
                selected: option.id == engine.id,
                inMutuallyExclusiveGroup: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(option.name),
                    if (option.subtitle case final sub? when sub.isNotEmpty)
                      Text(
                        sub,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.secondaryText,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        if (showChoices && onManage != null) const Divider(height: 1),
        if (onManage != null)
          MenuItemButton(
            key: const Key('composer_engine_manage'),
            leadingIcon: const Icon(Icons.tune),
            onPressed: onManage,
            child: Text(l10n.translateProvidersAction),
          ),
      ],
      builder: (context, controller, _) => terminal
          ? _terminal(
              context,
              onPressed: showChoices || onManage != null
                  ? () => controller.isOpen
                        ? controller.close()
                        : controller.open()
                  : null,
            )
          : Tooltip(
              message: l10n.commonAiModelChipTooltip,
              excludeFromSemantics: true,
              child: TextButton(
                key: const Key('composer_engine_chip'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsetsDirectional.only(start: 10, end: 6),
                  shape: AppLook.of(context).control.copyWith(
                    side: BorderSide(color: theme.colorScheme.outline),
                  ),
                  foregroundColor: theme.colorScheme.onSurface,
                ),
                onPressed: showChoices || onManage != null
                    ? () => controller.isOpen
                          ? controller.close()
                          : controller.open()
                    : null,
                child: Semantics(
                  label: l10n.commonAiModelChip(engine.name),
                  excludeSemantics: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        engine.isLocal
                            ? Icons.memory
                            : Icons.auto_awesome_outlined,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              engine.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (subtitle != null && subtitle.isNotEmpty)
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: palette.secondaryText,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.expand_more,
                        size: 18,
                        color: palette.secondaryText,
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  /// The terminal look's chip (see [ComposerEngineChip]).
  Widget _terminal(BuildContext context, {required VoidCallback? onPressed}) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = AppPalette.of(context).secondaryText;
    final subtitle = engine.subtitle?.trim() ?? '';
    return Tooltip(
      message: subtitle.isEmpty
          ? l10n.commonAiModelChipTooltip
          : '${l10n.commonAiModelChipTooltip}\n$subtitle',
      excludeFromSemantics: true,
      child: TextButton(
        key: const Key('composer_engine_chip'),
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsetsDirectional.only(start: 4, end: 4),
          shape: const RoundedRectangleBorder(),
          backgroundColor: Colors.transparent,
          foregroundColor: scheme.onSurface,
        ),
        onPressed: onPressed,
        child: Semantics(
          label: l10n.commonAiModelChip(engine.name),
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TerminalGlyphDot(color: scheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  engine.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more, size: 16, color: muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// A screen title with its [ComposerEngineChip] ([chip]): both side by
/// side from [compactBreakpoint], only the chip on phones (the tab's name
/// is on the navigation bar), like the translate and conversation
/// screens. Without a [chip], just the [title].
class ComposerAppBarTitle extends StatelessWidget {
  const new({required this.title, this.chip, super.key});

  /// Below this window width only the chip is shown.
  static const double compactBreakpoint = 600;

  final String title;
  final Widget? chip;

  @override
  Widget build(BuildContext context) {
    final chip = this.chip;
    if (chip == null) return Text(title);
    if (MediaQuery.sizeOf(context).width < compactBreakpoint) {
      return Align(alignment: AlignmentDirectional.centerStart, child: chip);
    }
    return Row(
      children: [
        Flexible(
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 16),
        Flexible(child: chip),
      ],
    );
  }
}

/// An empty screen with a [ComposerCard]: while [docked], a greeting
/// ([hero]) fills the space above the composer, which sits at the bottom
/// (on large screens, [wide], the greeting sits right above the card,
/// which is centred and at most [maxColumnWidth] wide); otherwise the
/// greeting's slot collapses and the composer fills the screen (give it
/// `outlined: false` and `expand: true`).
///
/// It is one tree in both states, so a text field inside the composer
/// keeps its focus, text and keyboard when the screen switches. The
/// greeting scrolls when the window is too low for it.
class ComposerLayout extends StatelessWidget {
  const new({
    required this.hero,
    required this.composer,
    this.docked = true,
    this.wide = false,
    super.key,
  });

  /// Width from which the composer and the greeting use the large-screen
  /// layout.
  static const double wideBreakpoint = kExpandedBreakpoint;

  /// Max width of the docked composer.
  static const double maxColumnWidth = 760;

  /// Max width of the composer once it fills the screen on large screens.
  static const double maxWideWidth = 1440;

  /// Space around the docked composer on phones.
  static const double margin = 12;

  /// Side padding of the large-screen layout.
  static const double wideSide = 24;

  /// The lowest content height that shows a greeting above a docked
  /// composer at [textScale] (as on the translate screen).
  static double heroMinHeight(double textScale) =>
      300 + 120 * textScale.clamp(1, 2);

  final Widget hero;
  final Widget composer;
  final bool docked;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final motion = composerMotion(context);
    return Column(
      children: [
        Flexible(
          flex: docked ? (wide ? 3 : 1) : 0,
          fit: FlexFit.tight,
          child: docked
              ? Align(
                  alignment: wide ? Alignment.bottomCenter : Alignment.center,
                  child: SingleChildScrollView(child: hero),
                )
              : const SizedBox(width: double.infinity),
        ),
        Flexible(
          flex: docked ? 0 : 1,
          fit: docked ? FlexFit.loose : FlexFit.tight,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: docked || !wide
                    ? maxColumnWidth + 2 * (wide ? wideSide : margin)
                    : maxWideWidth,
              ),
              child: AnimatedPadding(
                duration: motion,
                curve: Curves.easeOutCubic,
                padding: wide
                    ? const EdgeInsets.symmetric(horizontal: wideSide)
                    : docked
                    ? const EdgeInsets.fromLTRB(margin, 8, margin, margin)
                    : EdgeInsets.zero,
                child: composer,
              ),
            ),
          ),
        ),
        Flexible(
          flex: docked && wide ? 2 : 0,
          fit: FlexFit.tight,
          child: const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
