import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/models/proofread_diff.dart';

/// Colors and text styles for inline diffs, derived from the theme so they
/// work in light and dark mode: removals use the error container, insertions
/// a green container generated for the current brightness.
@immutable
class ProofreadDiffColors {
  const ProofreadDiffColors({
    required this.removedBackground,
    required this.removedForeground,
    required this.insertedBackground,
    required this.insertedForeground,
  });

  factory ProofreadDiffColors.of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final green = _greenSchemes[theme.brightness] ??= ColorScheme.fromSeed(
      seedColor: _green,
      brightness: theme.brightness,
    );
    return ProofreadDiffColors(
      removedBackground: scheme.errorContainer,
      removedForeground: scheme.onErrorContainer,
      insertedBackground: green.primaryContainer,
      insertedForeground: green.onPrimaryContainer,
    );
  }

  static const _green = Color(0xFF2E7D32);
  static final _greenSchemes = <Brightness, ColorScheme>{};

  final Color removedBackground;
  final Color removedForeground;
  final Color insertedBackground;
  final Color insertedForeground;

  TextStyle get removedStyle => TextStyle(
    color: removedForeground,
    backgroundColor: removedBackground,
    decoration: TextDecoration.lineThrough,
    decorationColor: removedForeground,
  );

  TextStyle get insertedStyle =>
      TextStyle(color: insertedForeground, backgroundColor: insertedBackground);

  TextStyle? styleFor(DiffType type) => switch (type) {
    DiffType.unchanged => null,
    DiffType.removed => removedStyle,
    DiffType.inserted => insertedStyle,
  };

  /// Screen-reader label for a segment (null for unchanged text).
  static String? semanticsFor(
    BuildContext context,
    DiffSegment segment,
  ) => switch (segment.type) {
    DiffType.unchanged => null,
    DiffType.removed => context.l10n.proofreadRemovedSemantics(segment.text),
    DiffType.inserted => context.l10n.proofreadInsertedSemantics(segment.text),
  };
}
