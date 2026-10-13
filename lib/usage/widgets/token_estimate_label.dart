import 'package:material_ui/material_ui.dart';
import 'package:mozhi/usage/token_estimate.dart';
import 'package:mozhi/usage/widgets/usage_format.dart';

/// Shows "≈ N tokens" for [text] once it has at least [minCharacters]
/// characters (and nothing for shorter texts), e.g. under the input field
/// when an AI provider is selected.
class TokenEstimateLabel extends StatelessWidget {
  const TokenEstimateLabel({
    required this.text,
    this.minCharacters = defaultMinCharacters,
    this.style,
    super.key,
  });

  /// Texts shorter than this are not worth an estimate.
  static const defaultMinCharacters = 500;

  final String text;
  final int minCharacters;

  /// Defaults to `labelSmall` in `onSurfaceVariant`.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final estimate = TokenEstimate.of(text);
    if (estimate.characters < minCharacters || estimate.characters == 0) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Text(
      context.usageTokens(estimate.tokens),
      style:
          style ??
          theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
    );
  }
}
