import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/quick_translate/cubit/quick_translate_state.dart';
import 'package:mozhi/quick_translate/models/quick_languages.dart';
import 'package:mozhi/translate/widgets/translate_error.dart'
    show describeTranslateError;

/// The translation area: progress while loading / translating, the
/// (streaming) translation, or an error with a retry button.
class QuickResultView extends StatelessWidget {
  const new({required this.state, required this.onRetry, super.key});

  final QuickTranslateState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final Widget child = switch (state.status) {
      QuickTranslateStatus.loading => _Progress(
        key: const ValueKey('loading'),
        label: l10n.translateLoadingEngines,
      ),
      QuickTranslateStatus.translating when state.result == null => _Progress(
        key: const ValueKey('translating'),
        label: l10n.quickTranslateTranslatingTo(state.target.name),
      ),
      QuickTranslateStatus.failure => _Message(
        key: const ValueKey('failure'),
        icon: Icons.error_outline,
        color: scheme.error,
        message: describeTranslateError(l10n, state.error).message,
        action: FilledButton.tonalIcon(
          key: const Key('quick_translate_retry'),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.commonRetry),
        ),
      ),
      QuickTranslateStatus.noEngines => _Message(
        key: const ValueKey('noEngines'),
        icon: Icons.cloud_off_outlined,
        color: scheme.onSurfaceVariant,
        title: l10n.translateNoEnginesTitle,
        message: l10n.quickTranslateNoEngines,
      ),
      _ when state.translation.trim().isEmpty => _Message(
        key: const ValueKey('empty'),
        icon: Icons.info_outline,
        color: scheme.onSurfaceVariant,
        message: l10n.quickTranslateEmpty,
      ),
      _ => _Translation(key: const ValueKey('result'), state: state),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      layoutBuilder: (current, previous) => Stack(
        children: [...previous, ?current],
      ),
      child: child,
    );
  }
}

class _Translation extends StatelessWidget {
  const new({required this.state, super.key});

  final QuickTranslateState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final text = state.translation;
    final style = text.length <= 120
        ? theme.textTheme.titleLarge
        : theme.textTheme.bodyLarge;
    final target = state.target;
    final direction = target.isCustom
        ? null
        : (isRtlLanguage(target.code) ? TextDirection.rtl : TextDirection.ltr);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          liveRegion: state.hasTranslation,
          label: l10n.translateOutputLabel,
          child: SelectableText(
            text,
            key: const Key('quick_translate_translation'),
            textDirection: direction,
            style: style,
          ),
        ),
        if (state.isStreaming)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(
              key: const Key('quick_translate_streaming'),
              semanticsLabel: l10n.translateTranslating,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const new({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            key: const Key('quick_translate_progress'),
            semanticsLabel: label,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 12),
          ExcludeSemantics(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const new({
    required this.icon,
    required this.color,
    required this.message,
    this.title,
    this.action,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String? title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title case final String title) ...[
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                    ],
                    Text(
                      message,
                      style: theme.textTheme.bodyLarge?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (action case final Widget action) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 36),
              child: action,
            ),
          ],
        ],
      ),
    );
  }
}
