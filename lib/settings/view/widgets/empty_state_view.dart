import 'package:material_ui/material_ui.dart';

/// Tone of an [EmptyStateView]'s illustration.
enum EmptyStateTone {
  /// Friendly, primary-tinted (nothing here yet).
  neutral,

  /// Error-tinted (something failed).
  error,
}

/// A calm empty or error state shared by the app's screens: an icon in a
/// tinted circle, a short title, an optional body and an optional primary
/// [action].
class EmptyStateView extends StatelessWidget {
  const new({
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.tone = EmptyStateTone.neutral,
    this.announce = false,
    this.compact = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? body;

  /// Usually a [FilledButton] or [FilledButton.tonal].
  final Widget? action;
  final EmptyStateTone tone;

  /// Whether the title and body form a live region (WCAG 4.1.3).
  final bool announce;

  /// A smaller illustration, for states shown beside other content.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (background, foreground) = switch (tone) {
      EmptyStateTone.neutral => (
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      EmptyStateTone.error => (colors.errorContainer, colors.onErrorContainer),
    };
    final circle = compact ? 64.0 : 88.0;
    final body = this.body;
    final action = this.action;
    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(32, compact ? 16 : 24, 32, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: SizedBox.square(
                  dimension: circle,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: background,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: circle / 2, color: foreground),
                  ),
                ),
              ),
              SizedBox(height: compact ? 16 : 20),
              Semantics(
                container: announce,
                liveRegion: announce,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: compact
                            ? theme.textTheme.titleMedium
                            : theme.textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (body != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        body,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
              if (action != null) ...[const SizedBox(height: 24), action],
            ],
          ),
        ),
      ),
    );
  }
}
