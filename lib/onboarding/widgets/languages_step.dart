import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/view/offline_models_page.dart'
    show MeteredDownloadDialog, offlineOutcomeMessage;
import 'package:mozhi/offline/widgets/offline_language_tile.dart'
    show confirmDeleteOfflineLanguage;
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';
import 'package:mozhi/onboarding/widgets/onboarding_language_picker.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:translation_repository/translation_repository.dart';

/// The offline engine's code for [language] among [languages] (null for
/// auto, custom and unsupported languages). A Traditional Chinese
/// [isTarget] is never mapped onto a Simplified model.
String? offlineCodeFor(
  Language language,
  List<OfflineLanguage> languages, {
  bool isTarget = false,
}) {
  if (language.isAuto || language.isCustom || languages.isEmpty) return null;
  final match = LanguageMatcher.match(language, [
    for (final offline in languages)
      Language(
        code: offline.code,
        name: offline.name,
        nativeName: offline.nativeName,
      ),
  ]);
  if (match == null) return null;
  final wanted = LanguageMatcher.normalize(language.code);
  if (isTarget &&
      wanted == 'zh-TW' &&
      LanguageMatcher.normalize(match.code) != wanted) {
    return null;
  }
  return match.code;
}

/// Step 3: "Pick your languages": the default source and target languages
/// and, where the device translates on its own, their offline downloads
/// (with sizes, progress and the Wi-Fi only choice; a metered network asks
/// first).
///
/// Expects an [OnboardingCubit] and an [OfflineModelsCubit] above it.
class LanguagesStep extends StatelessWidget {
  const new({super.key});

  Future<void> _onOutcome(
    BuildContext context,
    OfflineModelOutcome outcome,
  ) async {
    final cubit = context.read<OfflineModelsCubit>();
    if (outcome.needsMeteredConsent) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => MeteredDownloadDialog(
          language: outcome.language,
          size: cubit.state.downloadSizeOf(outcome.language.code),
        ),
      );
      if (confirmed ?? false) {
        await cubit.download(outcome.language.code, overMeteredNetwork: true);
      }
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(offlineOutcomeMessage(context.l10n, outcome))),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final source = context.select<SettingsCubit, Language>(
      (c) => c.state.source,
    );
    final target = context.select<SettingsCubit, Language>(
      (c) => c.state.target,
    );
    return BlocListener<OfflineModelsCubit, OfflineModelsState>(
      listenWhen: (previous, current) =>
          current.outcome != null && previous.outcome != current.outcome,
      listener: (context, state) =>
          unawaited(_onOutcome(context, state.outcome!)),
      child: OnboardingStepLayout(
        icon: Icons.translate,
        title: l10n.onboardingLanguagesTitle,
        subtitle: l10n.onboardingLanguagesBody,
        children: [
          _LanguageField(
            key: const Key('onboarding_source_language'),
            label: l10n.onboardingLanguagesFrom,
            language: source,
            source: true,
          ),
          const SizedBox(height: 12),
          _LanguageField(
            key: const Key('onboarding_target_language'),
            label: l10n.onboardingLanguagesInto,
            language: target,
            source: false,
          ),
          const SizedBox(height: 24),
          _OfflineDownloads(source: source, target: target),
        ],
      ),
    );
  }
}

/// A language choice: a bordered row with the language's avatar, the
/// [label] and the language; opens the picker.
class _LanguageField extends StatelessWidget {
  const new({
    required this.label,
    required this.language,
    required this.source,
    super.key,
  });

  final String label;
  final Language language;
  final bool source;

  Future<void> _pick(BuildContext context) async {
    final cubit = context.read<OnboardingCubit>();
    final offline = context.read<OfflineModelsCubit>().state;
    final picked = await showOnboardingLanguagePicker(
      context,
      source: source,
      selected: language,
      isOffline: offline.isAvailable
          ? (language) =>
                offlineCodeFor(
                  language,
                  offline.languages,
                  isTarget: !source,
                ) !=
                null
          : null,
    );
    if (picked == null) return;
    if (source) {
      cubit.setSourceLanguage(picked);
    } else {
      cubit.setTargetLanguage(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minVerticalPadding: 12,
        leading: language.isAuto
            ? Icon(
                Icons.auto_awesome_outlined,
                color: theme.colorScheme.primary,
              )
            : LanguageAvatar(code: language.code),
        title: Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: palette.secondaryText,
          ),
        ),
        subtitle: Text(
          language.name,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        trailing: const Icon(Icons.expand_more),
        onTap: () => unawaited(_pick(context)),
      ),
    );
  }
}

/// "Use them offline": the picked languages' downloads, or why there are
/// none on this device.
class _OfflineDownloads extends StatelessWidget {
  const new({required this.source, required this.target});

  final Language source;
  final Language target;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final state = context.watch<OfflineModelsCubit>().state;
    switch (state.status) {
      case OfflineModelsStatus.initial || OfflineModelsStatus.loading:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: CircularProgressIndicator(
              semanticsLabel: l10n.onboardingLanguagesLoading,
            ),
          ),
        );
      case OfflineModelsStatus.failure:
      case OfflineModelsStatus.ready when !state.isAvailable:
        return OnboardingNote(
          icon: Icons.cloud_outlined,
          text: l10n.onboardingLanguagesNoOffline,
        );
      case OfflineModelsStatus.ready:
        break;
    }
    final picks = [if (!source.isAuto) (source, false), (target, true)];
    final codes = <String>[];
    final unsupported = <Language>[];
    for (final (language, isTarget) in picks) {
      final code = offlineCodeFor(
        language,
        state.languages,
        isTarget: isTarget,
      );
      if (code == null) {
        unsupported.add(language);
      } else if (!codes.contains(code)) {
        codes.add(code);
      }
    }
    final cubit = context.read<OfflineModelsCubit>();
    final byCode = {
      for (final language in state.languages) language.code: language,
    };
    return OnboardingSection(
      title: l10n.onboardingLanguagesOfflineTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.onboardingLanguagesOfflineBody,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.secondaryText,
            ),
          ),
          const SizedBox(height: 8),
          for (final code in codes)
            OnboardingOfflineLanguageRow(
              key: ValueKey('onboarding_offline_$code'),
              language: byCode[code]!,
              downloaded: state.isDownloaded(code),
              pending: state.pending[code],
              progress: state.progress[code],
              downloadSize: state.downloadSizeOf(code),
              installedSize: state.installedSizeOf(code),
              outdated: state.isOutdated(code),
              builtIn: state.isBuiltIn(code),
              onDownload: () => unawaited(cubit.download(code)),
              onDelete: () => unawaited(cubit.delete(code)),
            ),
          for (final language in unsupported)
            OnboardingInfoRow(
              icon: Icons.cloud_outlined,
              color: palette.secondaryText,
              text: l10n.onboardingLanguagesOfflineUnsupported(language.name),
            ),
          if (source.isAuto)
            OnboardingInfoRow(
              icon: Icons.auto_awesome_outlined,
              color: palette.secondaryText,
              text: l10n.onboardingLanguagesOfflineAuto,
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const Key('onboarding_offline_wifi_only'),
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.wifi),
            title: Text(l10n.offlineWifiOnly),
            subtitle: Text(l10n.offlineWifiOnlyAsk),
            value: state.wifiOnly,
            onChanged: (enabled) =>
                unawaited(cubit.setWifiOnly(enabled: enabled)),
          ),
        ],
      ),
    );
  }
}

/// One picked language's offline model: its avatar, name and size (or
/// what is happening) and the action (Download, Update, Delete; nothing
/// for built-in English). The action sits next to the name, or below it on
/// narrow rows and with large text.
class OnboardingOfflineLanguageRow extends StatelessWidget {
  const new({
    required this.language,
    required this.downloaded,
    required this.onDownload,
    required this.onDelete,
    this.pending,
    this.progress,
    this.downloadSize,
    this.installedSize,
    this.outdated = false,
    this.builtIn = false,
    super.key,
  });

  final OfflineLanguage language;
  final bool downloaded;
  final OfflineModelOperation? pending;

  /// Fraction (0 to 1) of a running download or update, when known.
  final double? progress;
  final int? downloadSize;
  final int? installedSize;
  final bool outdated;
  final bool builtIn;

  /// Downloads or, when [outdated], updates the language.
  final VoidCallback onDownload;

  /// Deletes the language (after the user confirmed).
  final VoidCallback onDelete;

  /// Rows narrower than this put the action below the name.
  static const compactWidth = 420.0;

  String _details(AppLocalizations l10n) {
    final percent = progress == null ? null : (progress! * 100).floor();
    final status = switch (pending) {
      OfflineModelOperation.download =>
        percent == null
            ? l10n.offlineDownloading
            : l10n.offlineDownloadingProgress(percent),
      OfflineModelOperation.update =>
        percent == null
            ? l10n.offlineUpdating
            : l10n.offlineUpdatingProgress(percent),
      OfflineModelOperation.delete => l10n.offlineDeleting,
      null => switch (this) {
        OnboardingOfflineLanguageRow(builtIn: true) => l10n.offlineBuiltIn,
        OnboardingOfflineLanguageRow(outdated: true, :final downloadSize?) =>
          l10n.offlineUpdateAvailable(formatStoredSize(l10n, downloadSize)),
        OnboardingOfflineLanguageRow(downloaded: true, :final installedSize?) =>
          l10n.offlineInstalledSize(formatStoredSize(l10n, installedSize)),
        OnboardingOfflineLanguageRow(downloaded: true) =>
          l10n.offlineDownloadedBadge,
        OnboardingOfflineLanguageRow(:final downloadSize?)
            when downloadSize > 0 =>
          l10n.offlineDownloadSize(formatStoredSize(l10n, downloadSize)),
        _ => null,
      },
    };
    return [?language.nativeName, ?status].join(' · ');
  }

  Future<void> _confirmDelete(BuildContext context) async {
    if (await confirmDeleteOfflineLanguage(context, language)) onDelete();
  }

  Widget? _action(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    if (pending != null) {
      return SizedBox.square(
        dimension: 48,
        child: Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 2.5,
              backgroundColor: AppPalette.of(context).hairline,
            ),
          ),
        ),
      );
    }
    if (builtIn) return null;
    const minimumSize = Size(64, 48);
    if (!downloaded || outdated) {
      return Tooltip(
        message: outdated
            ? l10n.offlineUpdateTooltip(language.name)
            : l10n.offlineDownloadTooltip(language.name),
        child: FilledButton.tonalIcon(
          style: FilledButton.styleFrom(minimumSize: minimumSize),
          onPressed: onDownload,
          icon: Icon(outdated ? Icons.update : Icons.download_outlined),
          label: Text(
            outdated ? l10n.offlineUpdateAction : l10n.offlineDownloadAction,
          ),
        ),
      );
    }
    return IconButton(
      tooltip: l10n.offlineDeleteTooltip(language.name),
      icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
      onPressed: () => unawaited(_confirmDelete(context)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final details = _details(l10n);
    final busy = pending != null;
    final action = _action(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < compactWidth ||
            MediaQuery.textScalerOf(context).scale(1) > 1.3;
        final text = MergeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                language.name,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (details.isNotEmpty)
                Semantics(
                  liveRegion: busy,
                  child: Text(
                    details,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: busy
                          ? theme.colorScheme.primary
                          : palette.secondaryText,
                    ),
                  ),
                ),
            ],
          ),
        );
        final avatar = Stack(
          clipBehavior: Clip.none,
          children: [
            LanguageAvatar(code: language.code),
            if (downloaded)
              PositionedDirectional(
                end: -4,
                bottom: -4,
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(1.5),
                      child: Icon(
                        Icons.offline_pin,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  avatar,
                  const SizedBox(width: 16),
                  Expanded(child: text),
                  if (!compact && action != null) ...[
                    const SizedBox(width: 8),
                    action,
                  ],
                ],
              ),
              if (compact && action != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 56, top: 4),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: action,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
