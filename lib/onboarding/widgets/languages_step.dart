import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/offline/view/offline_models_page.dart'
    show MeteredDownloadDialog, offlineOutcomeMessage;
import 'package:mozhi/offline/widgets/offline_language_tile.dart'
    show OfflineCancelDownloadButton, confirmDeleteOfflineLanguage;
import 'package:mozhi/onboarding/cubit/onboarding_cubit.dart';
import 'package:mozhi/onboarding/widgets/onboarding_language_picker.dart';
import 'package:mozhi/onboarding/widgets/step_layout.dart';
import 'package:mozhi/platform/free_space.dart' show requiredFreeSpace;
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

/// A source language to suggest while the source is "Detect language": the
/// first of [deviceLanguages] (the phone's languages, BCP 47 tags) that is
/// in the catalogue and is not [target]'s language; when there is none
/// (the phone speaks the target only), the source the user [picked] before
/// (unless it is "Detect language", custom or the target's language). Null
/// otherwise: no language is made up.
Language? suggestedSourceLanguage(
  List<String> deviceLanguages, {
  required Language target,
  Language? picked,
}) {
  String primary(String code) =>
      LanguageMatcher.normalize(code).split('-').first.toLowerCase();
  final into = primary(target.code);
  for (final tag in deviceLanguages) {
    if (tag.trim().isEmpty) continue;
    final language = LanguageMatcher.match(
      Language(code: tag, name: tag),
      LanguageCatalog.all,
    );
    if (language == null || language.isAuto || language.isCustom) continue;
    if (primary(language.code) == into) continue;
    return language;
  }
  if (picked == null ||
      picked.isAuto ||
      picked.isCustom ||
      primary(picked.code) == into) {
    return null;
  }
  return picked;
}

/// The offline rows of the languages step for [source] (while detecting:
/// [suggested], when the engine has it) and [target] among [languages]:
/// the engine's codes, and the picked languages it has no model for.
({List<String> codes, List<Language> unsupported}) onboardingOfflinePair({
  required Language source,
  required Language target,
  required List<OfflineLanguage> languages,
  Language? suggested,
}) {
  final picks = [
    if (!source.isAuto)
      (source, false)
    else if (suggested != null && offlineCodeFor(suggested, languages) != null)
      (suggested, false),
    (target, true),
  ];
  final codes = <String>[];
  final unsupported = <Language>[];
  for (final (language, isTarget) in picks) {
    final code = offlineCodeFor(language, languages, isTarget: isTarget);
    if (code == null) {
      unsupported.add(language);
    } else if (!codes.contains(code)) {
      codes.add(code);
    }
  }
  return (codes: codes, unsupported: unsupported);
}

/// Whether the languages step offers [code] as a checkbox (download on
/// Next): not on the device yet, nothing running for it, not built in and
/// not an update (which keeps its button).
bool onboardingCanCheckDownload(OfflineModelsState offline, String code) =>
    !offline.isDownloaded(code) &&
    !offline.isBuiltIn(code) &&
    !offline.isOutdated(code) &&
    !offline.pending.containsKey(code);

/// The languages of [codes] to download when the user taps Next: those
/// they checked; those they did not answer for are checked for them when
/// [OnboardingState.preselectDownloads] and the phone has room for all of
/// them ([OnboardingState.freeBytes], with the margin of
/// [requiredFreeSpace]).
Set<String> onboardingCheckedDownloads(
  OnboardingState onboarding,
  OfflineModelsState offline,
  Iterable<String> codes,
) {
  final open = [
    for (final code in codes)
      if (onboardingCanCheckDownload(offline, code)) code,
  ];
  final bytes = open.fold<int>(
    0,
    (sum, code) => sum + (offline.downloadSizeOf(code) ?? 0),
  );
  final free = onboarding.freeBytes;
  final preselect =
      onboarding.preselectDownloads &&
      free != null &&
      free >= requiredFreeSpace(bytes);
  return {
    for (final code in open)
      if (onboarding.downloadChoices[code] ?? preselect) code,
  };
}

/// Step 3: "Pick your languages": the default source and target languages
/// and, where the device translates on its own, their offline downloads
/// (with sizes, progress and the Wi-Fi only choice; a metered network asks
/// first).
///
/// While the source is "Detect language", a source language from the
/// phone's languages is suggested ([suggestedSourceLanguage]: "Translate
/// from French"), or, when the phone speaks the target only, the source the
/// user picked before ([OnboardingState.pickedSource]), and its download
/// offered with the target's. The downloads
/// of the pair are checkboxes, checked for the user on Android when the
/// phone has room ([onboardingCheckedDownloads]); they start when the user
/// taps Next (the flow moves on to the service step), never by themselves.
///
/// Expects an [OnboardingCubit] and an [OfflineModelsCubit] above it.
class LanguagesStep extends StatelessWidget {
  const new({super.key});

  /// The suggested source for [source] and [target] (only while
  /// detecting).
  static Language? _suggested(
    OnboardingState onboarding, {
    required Language source,
    required Language target,
  }) => source.isAuto
      ? suggestedSourceLanguage(
          onboarding.deviceLanguages,
          target: target,
          picked: onboarding.pickedSource,
        )
      : null;

  /// Starts the checked downloads: the user tapped Next.
  static void _downloadChecked(BuildContext context, OnboardingState state) {
    final settings = context.read<SettingsCubit>().state;
    final cubit = context.read<OfflineModelsCubit>();
    final offline = cubit.state;
    if (offline.status != OfflineModelsStatus.ready || !offline.isAvailable) {
      return;
    }
    final pair = onboardingOfflinePair(
      source: settings.source,
      target: settings.target,
      languages: offline.languages,
      suggested: _suggested(
        state,
        source: settings.source,
        target: settings.target,
      ),
    );
    for (final code in onboardingCheckedDownloads(state, offline, pair.codes)) {
      unawaited(cubit.download(code));
    }
  }

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
    final onboarding = context.watch<OnboardingCubit>().state;
    final suggested = _suggested(onboarding, source: source, target: target);
    // From the phone's languages, or the source picked before.
    final fromPhone =
        suggested != null &&
        suggestedSourceLanguage(onboarding.deviceLanguages, target: target) ==
            suggested;
    return MultiBlocListener(
      listeners: [
        BlocListener<OfflineModelsCubit, OfflineModelsState>(
          listenWhen: (previous, current) =>
              current.outcome != null && previous.outcome != current.outcome,
          listener: (context, state) =>
              unawaited(_onOutcome(context, state.outcome!)),
        ),
        // Next: from this step on to the service step.
        BlocListener<OnboardingCubit, OnboardingState>(
          listenWhen: (previous, current) =>
              previous.step == OnboardingStep.languages &&
              current.step == OnboardingStep.service,
          listener: _downloadChecked,
        ),
      ],
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
          if (suggested != null)
            _SourceSuggestion(language: suggested, fromPhone: fromPhone),
          const SizedBox(height: 12),
          _LanguageField(
            key: const Key('onboarding_target_language'),
            label: l10n.onboardingLanguagesInto,
            language: target,
            source: false,
          ),
          const SizedBox(height: 24),
          _OfflineDownloads(
            source: source,
            target: target,
            suggested: suggested,
          ),
        ],
      ),
    );
  }
}

/// "French is one of your phone's languages." (or, not [fromPhone], "You
/// picked French before.") with "Translate from French" (makes it the
/// source language).
class _SourceSuggestion extends StatelessWidget {
  const new({required this.language, required this.fromPhone});

  final Language language;

  /// Suggested from the phone's languages, not as the source picked before.
  final bool fromPhone;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    return Padding(
      key: const Key('onboarding_source_suggestion'),
      padding: const EdgeInsetsDirectional.only(top: 8, start: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(top: 2, end: 12),
                child: Icon(
                  Icons.lightbulb_outline,
                  size: 20,
                  color: palette.secondaryText,
                ),
              ),
              Expanded(
                child: Text(
                  fromPhone
                      ? l10n.onboardingLanguagesSuggestion(language.name)
                      : l10n.onboardingLanguagesSuggestionPicked(language.name),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.secondaryText,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 20),
            child: TextButton(
              key: const Key('onboarding_source_suggestion_use'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () =>
                  context.read<OnboardingCubit>().setSourceLanguage(language),
              child: Text(l10n.onboardingLanguagesSuggestionUse(language.name)),
            ),
          ),
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
        borderRadius: AppLook.of(context).cardRadius,
        side: BorderSide(color: theme.colorScheme.outline),
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

/// "Use them offline": the picked languages' downloads (checkboxes,
/// downloaded on Next), or why there are none on this device.
class _OfflineDownloads extends StatelessWidget {
  const new({required this.source, required this.target, this.suggested});

  final Language source;
  final Language target;

  /// The suggested source while detecting.
  final Language? suggested;

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
    final (:codes, :unsupported) = onboardingOfflinePair(
      source: source,
      target: target,
      languages: state.languages,
      suggested: suggested,
    );
    final onboarding = context.watch<OnboardingCubit>();
    final checked = onboardingCheckedDownloads(onboarding.state, state, codes);
    final checkable = codes.any(
      (code) => onboardingCanCheckDownload(state, code),
    );
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
              selected: onboardingCanCheckDownload(state, code)
                  ? checked.contains(code)
                  : null,
              onSelected: (download) =>
                  onboarding.chooseDownload(code, download: download),
              onDownload: () => unawaited(cubit.download(code)),
              onDelete: () => unawaited(cubit.delete(code)),
              onCancel: state.canCancel
                  ? () => unawaited(cubit.cancelDownload(code))
                  : null,
              cancelling: state.cancelling.contains(code),
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
          if (checkable)
            OnboardingInfoRow(
              key: const Key('onboarding_offline_on_next'),
              icon: Icons.download_outlined,
              color: palette.secondaryText,
              text: l10n.onboardingLanguagesDownloadOnNext,
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
/// for built-in English). With [selected] (the languages step) a model
/// that is not on the device has a checkbox instead of Download
/// ([onSelected]: download it when the user taps Next). With [onCancel], a
/// running download or update shows Cancel next to its progress. The
/// action sits next to the name, or below it on narrow rows and with large
/// text.
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
    this.selected,
    this.onSelected,
    this.onCancel,
    this.cancelling = false,
    super.key,
  });

  /// Cancels the running download or update; null: no Cancel.
  final VoidCallback? onCancel;

  /// The running download or update is being cancelled.
  final bool cancelling;

  /// Whether the download is checked (to start on Next); null: a Download
  /// button instead.
  final bool? selected;

  /// The user checked or unchecked the download.
  final ValueChanged<bool>? onSelected;

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
      OfflineModelOperation.download ||
      OfflineModelOperation.update when cancelling => l10n.offlineCancelling,
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
      final ring = SizedBox.square(
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
      if (onCancel == null || pending == OfflineModelOperation.delete) {
        return ring;
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ring,
          OfflineCancelDownloadButton(
            language: language.name,
            onPressed: cancelling ? null : onCancel,
          ),
        ],
      );
    }
    if (builtIn) return null;
    if (selected case final checked? when !downloaded && !outdated) {
      final label = l10n.onboardingLanguagesDownloadCheckbox(language.name);
      return Tooltip(
        message: label,
        child: Checkbox(
          key: ValueKey('onboarding_offline_check_${language.code}'),
          value: checked,
          semanticLabel: label,
          onChanged: (value) => onSelected?.call(value ?? false),
        ),
      );
    }
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
