import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';

/// Maximum width of the onboarding content on large screens.
const onboardingMaxContentWidth = 640.0;

/// Side padding of the onboarding's content column in a [width] wide
/// window: a 24 dp gutter (32 dp from 600 dp), more once the column
/// reaches [onboardingMaxContentWidth]. The steps and the bottom bar use
/// it, so the buttons are exactly as wide as the content.
double onboardingContentPadding(double width) {
  final gutter = width >= 600 ? 32.0 : 24.0;
  return math.max(gutter, (width - onboardingMaxContentWidth) / 2);
}

/// The scrollable layout of every onboarding step, in the style of X's
/// sign-up: an accent icon, a big bold left-aligned headline (a semantic
/// header), an optional secondary intro and the step [children].
class OnboardingStepLayout extends StatelessWidget {
  const new({
    required this.icon,
    required this.title,
    required this.children,
    this.subtitle,
    this.titleTrailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// Shown next to the title (e.g. an "Optional" badge).
  final Widget? titleTrailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = onboardingContentPadding(constraints.maxWidth);
        return ListView(
          padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 32),
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ExcludeSemantics(
                child: Icon(icon, size: 36, color: colors.primary),
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      height: 1.15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: colors.onSurface,
                    ),
                  ),
                ),
                ?titleTrailing,
              ],
            ),
            if (subtitle case final subtitle?) ...[
              const SizedBox(height: 12),
              Text(
                subtitle,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: AppPalette.of(context).secondaryText,
                ),
              ),
            ],
            const SizedBox(height: 24),
            ...children,
          ],
        );
      },
    );
  }
}

/// A titled group inside a step (semantic header + content).
class OnboardingSection extends StatelessWidget {
  const new({required this.title, required this.child, super.key});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// An icon + text row used for feature lists and notes.
class OnboardingInfoRow extends StatelessWidget {
  const new({
    required this.icon,
    required this.text,
    this.title,
    this.color,
    super.key,
  });

  final IconData icon;
  final String? title;
  final String text;

  /// Icon colour (default: primary).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color ?? colors.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title case final title?) ...[
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                  ],
                  Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A note box (privacy hints, results): a flat hairline box, or filled
/// with [background] when given.
class OnboardingNote extends StatelessWidget {
  const new({
    required this.icon,
    required this.text,
    this.background,
    this.foreground,
    super.key,
  });

  final IconData icon;
  final String text;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fg = foreground ?? colors.onSurfaceVariant;
    return MergeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background ?? colors.surface,
          borderRadius: AppRadius.cardBorderRadius,
          border: background == null
              ? Border.all(color: AppPalette.of(context).hairline)
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: fg, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps a [PageView] page (and its text fields) alive while off screen.
class OnboardingKeepAlive extends StatefulWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  State<OnboardingKeepAlive> createState() => _OnboardingKeepAliveState();
}

class _OnboardingKeepAliveState extends State<OnboardingKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
