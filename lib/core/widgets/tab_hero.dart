import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';

/// The greeting of an empty tab (Dictionary, Proofread, Conversation), in
/// the style of the translate screen's start screen: a decorative accent
/// [icon], a big bold centred [title], an optional quieter [body] and an
/// optional [child] below (e.g. a large button).
///
/// The title is a semantic header; the icon is left out of semantics.
class TabHero extends StatelessWidget {
  const new({required this.title, this.icon, this.body, this.child, super.key});

  final String title;
  final IconData? icon;
  final String? body;
  final Widget? child;

  /// Size of the [icon].
  static const double iconSize = 52;

  /// The headline style (the translate screen's greeting).
  static TextStyle? titleStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.headlineMedium?.copyWith(
      color: theme.colorScheme.onSurface,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
      height: 1.15,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = this.icon;
    final body = this.body;
    final child = this.child;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          ExcludeSemantics(
            child: Icon(icon, size: iconSize, color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 12),
        ],
        Semantics(
          header: true,
          child: Text(
            title,
            style: titleStyle(context),
            textAlign: TextAlign.center,
          ),
        ),
        if (body != null) ...[
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: AppPalette.of(context).secondaryText,
            ),
          ),
        ],
        if (child != null) ...[const SizedBox(height: 24), child],
      ],
    );
  }
}
