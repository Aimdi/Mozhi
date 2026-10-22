import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Something that takes a few seconds ([label]): a spinner (an hourglass
/// when animations are off), the label and "This can take a few seconds",
/// announced to screen readers.
class BackupProgressView extends StatelessWidget {
  const new({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
        child: Column(
          children: [
            SizedBox.square(
              dimension: 48,
              child: still
                  ? Icon(
                      Icons.hourglass_top,
                      size: 40,
                      color: theme.colorScheme.primary,
                    )
                  : const CircularProgressIndicator(),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              context.l10n.backupWorkingHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The end of a backup or restore: an [icon], a [title] and what
/// happened ([children]), announced to screen readers.
class BackupOutcomeView extends StatelessWidget {
  const new({
    required this.icon,
    required this.title,
    this.children = const [],
    this.error = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  /// Whether it is about a failure (drawn in the error colour).
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppSpacing.lg),
          Icon(icon, size: 48, color: error ? colors.error : colors.primary),
          const SizedBox(height: AppSpacing.lg),
          // Announced with what follows (one live region); the dialog's
          // title is the heading.
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.md),
          ...children,
        ],
      ),
    );
  }
}

/// A warning in an error-container card (e.g. what including API keys
/// means).
class BackupWarningCard extends StatelessWidget {
  const new({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: colors.errorContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: AppRadius.cardBorderRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: colors.onErrorContainer),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onErrorContainer,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An error message with an icon, announced to screen readers.
class BackupErrorText extends StatelessWidget {
  const new(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(Icons.error_outline, color: colors.error, size: 20),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
            ),
          ),
        ],
      ),
    );
  }
}
