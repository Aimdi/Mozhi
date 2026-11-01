import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/quick_translate/cubit/quick_translate_state.dart';
import 'package:mozhi/quick_translate/models/quick_languages.dart';
import 'package:mozhi/translate/widgets/offline_offer.dart'
    show offlineDownloadLabel, offlineDownloadName;
import 'package:mozhi/translate/widgets/translate_error.dart'
    show describeTranslateError;
import 'package:mozhi/translate/widgets/translate_layout.dart'
    show TranslateLayout;
import 'package:translation_repository/translation_repository.dart'
    show ConsentRequiredException;

/// The translation area: progress while loading / translating, the
/// (streaming) translation, or an error with a retry button.
///
/// Offline only, it explains why nothing was translated: no on-device
/// engine, a language to download ("Download German (25 MB)", which calls
/// [onOpenOfflineModels]; no button without it) or a pair the on-device
/// engine cannot translate.
class QuickResultView extends StatelessWidget {
  const new({
    required this.state,
    required this.onRetry,
    this.onOpenOfflineModels,
    super.key,
  });

  final QuickTranslateState state;
  final VoidCallback onRetry;

  /// Opens the offline languages ([QuickTranslateStatus.offlineModelsMissing]).
  final VoidCallback? onOpenOfflineModels;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AppPalette.of(context);

    final Widget child = switch (state.status) {
      QuickTranslateStatus.loading => _Progress(
        key: const ValueKey('loading'),
        label: l10n.translateLoadingEngines,
      ),
      QuickTranslateStatus.translating when state.result == null => _Progress(
        key: const ValueKey('translating'),
        label: l10n.quickTranslateTranslatingTo(
          context.languageName(state.target),
        ),
      ),
      QuickTranslateStatus.failure
          when state.error is ConsentRequiredException =>
        ConsentInlinePrompt(
          key: const Key('quick_translate_consent'),
          consent: state.error! as ConsentRequiredException,
          onGranted: onRetry,
        ),
      QuickTranslateStatus.failure => _Message(
        key: const ValueKey('failure'),
        icon: Icons.error_outline,
        color: scheme.error,
        message: describeTranslateError(l10n, state.error).message,
        action: FilledButton.icon(
          key: const Key('quick_translate_retry'),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.commonRetry),
        ),
      ),
      QuickTranslateStatus.chooseEngine => _Message(
        key: const ValueKey('chooseEngine'),
        icon: Icons.alt_route,
        color: palette.secondaryText,
        title: l10n.translateChooseEngineTitle,
        message: l10n.translateChooseEngineBody,
      ),
      QuickTranslateStatus.noEngines => _Message(
        key: const ValueKey('noEngines'),
        icon: Icons.cloud_off_outlined,
        color: palette.secondaryText,
        title: l10n.translateNoEnginesTitle,
        message: l10n.quickTranslateNoEngines,
      ),
      QuickTranslateStatus.offlineUnavailable => _Message(
        key: const ValueKey('offlineUnavailable'),
        icon: Icons.mobile_off_outlined,
        color: palette.secondaryText,
        title: l10n.quickTranslateOfflineUnavailableTitle,
        message: l10n.quickTranslateOfflineUnavailableBody,
      ),
      QuickTranslateStatus.offlineModelsMissing => _Message(
        key: const ValueKey('offlineModelsMissing'),
        icon: Icons.download_for_offline_outlined,
        color: palette.secondaryText,
        title: l10n.quickTranslateOfflineMissingTitle,
        message: l10n.quickTranslateOfflineMissingBody(
          [
            for (final download in state.offlineDownloads)
              offlineDownloadName(l10n, download),
          ].join(', '),
        ),
        action: onOpenOfflineModels == null
            ? null
            : FilledButton.icon(
                key: const Key('quick_translate_offline_download'),
                onPressed: onOpenOfflineModels,
                icon: const Icon(Icons.download_for_offline_outlined),
                label: Text(offlineDownloadLabel(l10n, state.offlineDownloads)),
              ),
      ),
      QuickTranslateStatus.offlineUnsupported => _Message(
        key: const ValueKey('offlineUnsupported'),
        icon: Icons.translate_outlined,
        color: palette.secondaryText,
        title: l10n.quickTranslateOfflineUnsupportedTitle,
        message: switch (state.detectedSource) {
          final source? => l10n.quickTranslateOfflineUnsupported(
            context.languageNameOf(source),
            context.languageName(state.target),
          ),
          null => l10n.quickTranslateOfflineUndetected,
        },
      ),
      _ when state.translation.trim().isEmpty => _Message(
        key: const ValueKey('empty'),
        icon: Icons.info_outline,
        color: palette.secondaryText,
        message: l10n.quickTranslateEmpty,
      ),
      _ => _Translation(key: const ValueKey('result'), state: state),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      layoutBuilder: (current, previous) =>
          Stack(children: [...previous, ?current]),
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
    final text = state.translation;
    // The translate screen's text: large for short translations, smaller
    // for long ones; body text, not the bold heading style.
    final style = TranslateLayout.outputTextStyle(context, text.length);
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
              borderRadius: BorderRadius.circular(
                AppLook.of(context).controlRadius(4),
              ),
            ),
          ),
        // Offline only, the "On device" chip is next to the target already.
        if (state.result?.destination case final destination?
            when state.hasTranslation && !state.offlineOnly)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: DestinationChip(
              key: const Key('quick_translate_destination'),
              destination: destination,
              engineId: state.result?.engineId,
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
            borderRadius: BorderRadius.circular(
              AppLook.of(context).controlRadius(4),
            ),
          ),
          const SizedBox(height: 12),
          ExcludeSemantics(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.of(context).secondaryText,
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
