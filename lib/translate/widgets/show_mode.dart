import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/translate/widgets/copy_action_button.dart';

/// Shows [text] (a translation) full screen in large type ([ShowModeView]),
/// to show it to someone: a waiter, a taxi driver. On the root navigator,
/// so it also covers the navigation bar. Fades in (at once with reduced
/// motion); completes when it is closed.
Future<void> showTranslationFullScreen(
  BuildContext context, {
  required String text,
  TextDirection? textDirection,
  Locale? locale,
}) {
  final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final duration = reduceMotion
      ? Duration.zero
      : const Duration(milliseconds: 200);
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      fullscreenDialog: true,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      pageBuilder: (context, animation, secondaryAnimation) => ShowModeView(
        text: text,
        textDirection: textDirection,
        locale: locale,
      ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

/// "Show mode": [text] as large as it fits ([fitFontSize]), black on
/// white (white on black in the dark theme) for the highest contrast, in
/// the text's own [textDirection] and [locale] (so the right script and
/// glyphs are used). Rotating the device lays it out again for the new
/// shape.
///
/// A tap anywhere, Back or Escape closes it; the close button and a copy
/// button ([CopyActionButton]) sit at the top end. Text too long to fit
/// even at [minFontSize] scrolls.
class ShowModeView extends StatelessWidget {
  const new({required this.text, this.textDirection, this.locale, super.key});

  /// The largest font size tried.
  static const double maxFontSize = 160;

  /// The smallest font size used; longer texts scroll.
  static const double minFontSize = 20;

  final String text;
  final TextDirection? textDirection;
  final Locale? locale;

  /// The largest font size from [minFontSize] to [maxFontSize] at which
  /// [text] (with [style]) fits into [size] without breaking a word; null
  /// when it does not fit even at [minFontSize].
  static double? fitFontSize(
    String text,
    Size size, {
    required TextStyle style,
    required TextDirection textDirection,
    Locale? locale,
  }) {
    bool fits(double fontSize) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          locale: locale,
          style: style.copyWith(fontSize: fontSize),
        ),
        textAlign: TextAlign.center,
        textDirection: textDirection,
      )..layout(maxWidth: size.width);
      final fitted =
          painter.height <= size.height &&
          painter.minIntrinsicWidth <= size.width;
      painter.dispose();
      return fitted;
    }

    if (!fits(minFontSize)) return null;
    var low = minFontSize;
    var high = maxFontSize;
    if (fits(high)) return high;
    // Within half a point is close enough.
    while (high - low > 0.5) {
      final middle = (low + high) / 2;
      if (fits(middle)) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return low.floorToDouble();
  }

  void _close(BuildContext context) => Navigator.maybePop(context);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final background = dark ? Colors.black : Colors.white;
    final foreground = dark ? Colors.white : Colors.black;
    final direction = textDirection ?? Directionality.of(context);
    final style = (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
      color: foreground,
      fontWeight: FontWeight.w600,
      height: 1.25,
      letterSpacing: 0,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        key: const Key('translate_show_mode'),
        backgroundColor: background,
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                _close(context),
          },
          child: Focus(
            autofocus: true,
            child: Semantics(
              scopesRoute: true,
              namesRoute: true,
              explicitChildNodes: true,
              label: l10n.translateShowModeTitle,
              child: SafeArea(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        key: const Key('translate_show_mode_area'),
                        behavior: HitTestBehavior.opaque,
                        // The close button does it for screen readers.
                        excludeFromSemantics: true,
                        onTap: () => _close(context),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 64, 24, 40),
                          child: LayoutBuilder(
                            builder: (context, constraints) =>
                                _text(constraints.biggest, style, direction),
                          ),
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      top: 8,
                      end: 8,
                      child: IconButtonTheme(
                        data: IconButtonThemeData(
                          style: IconButton.styleFrom(
                            foregroundColor: foreground,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CopyActionButton(
                              key: const Key('translate_show_mode_copy'),
                              text: text,
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              key: const Key('translate_show_mode_close'),
                              tooltip: l10n.commonClose,
                              icon: const Icon(Icons.close),
                              onPressed: () => _close(context),
                            ),
                          ],
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      start: 16,
                      end: 16,
                      bottom: 12,
                      child: ExcludeSemantics(
                        child: Text(
                          l10n.translateShowModeHint,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: foreground.withValues(alpha: 0.7),
                          ),
                        ),
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

  Widget _text(Size size, TextStyle style, TextDirection direction) {
    final fontSize = fitFontSize(
      text,
      size,
      style: style,
      textDirection: direction,
      locale: locale,
    );
    final widget = Text.rich(
      TextSpan(text: text, locale: locale),
      key: const Key('translate_show_mode_text'),
      textAlign: TextAlign.center,
      textDirection: direction,
      // The size is already the largest that fits.
      textScaler: TextScaler.noScaling,
      style: style.copyWith(fontSize: fontSize ?? minFontSize),
    );
    if (fontSize == null) return SingleChildScrollView(child: widget);
    return Center(child: widget);
  }
}
