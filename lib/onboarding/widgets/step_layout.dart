import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Maximum width of the onboarding content on large screens.
const onboardingMaxContentWidth = 640.0;

/// The scrollable, centred layout of every onboarding step: a large icon,
/// a title (a semantic header), an optional intro and the step [children].
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
        final gutter = constraints.maxWidth >= 600 ? 32.0 : 24.0;
        final horizontal = math.max(
          gutter,
          (constraints.maxWidth - onboardingMaxContentWidth) / 2,
        );
        return ListView(
          padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 32),
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Icon(
                      icon,
                      size: 40,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: theme.textTheme.headlineMedium),
                ),
                ?titleTrailing,
              ],
            ),
            if (subtitle case final subtitle?) ...[
              const SizedBox(height: 12),
              Text(
                subtitle,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.onSurfaceVariant,
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
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
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

/// A calm, tinted note card (privacy hints, results).
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
          color: background ?? colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
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
