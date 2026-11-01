import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:llama_engine/llama_engine.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/on_device_ai/cubit/on_device_ai_settings_cubit.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';
import 'package:mozhi/on_device_ai/data/on_device_models.dart';
import 'package:mozhi/on_device_ai/view/model_size.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/platform/engine_build_text.dart';
import 'package:mozhi/platform/free_space.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// The "On-device AI" settings (`/settings/on-device-ai`): what on-device
/// AI is, then the translation model and the assistant models with their
/// size, licence, languages and how they suit this phone's memory
/// (download with progress and cancel, delete, the one in use), import
/// from files and the download links.
///
/// Reads [OnDeviceModels] from context; without it (the web app, a device
/// that cannot run the engine) the page says why there is nothing to set.
class OnDeviceAiPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    OnDeviceModels? models;
    try {
      models = context.read<OnDeviceModels>();
    } on ProviderNotFoundException {
      models = null;
    }
    OnDeviceAi? ai;
    try {
      ai = context.read<OnDeviceAi>();
    } on ProviderNotFoundException {
      ai = null;
    }
    return BlocProvider(
      create: (_) {
        final cubit = OnDeviceAiSettingsCubit(
          models: models,
          engineBuild: () => ai?.engineBuild,
        );
        unawaited(cubit.load());
        return cubit;
      },
      child: const OnDeviceAiView(),
    );
  }
}

class OnDeviceAiView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<OnDeviceAiSettingsCubit>().state;
    final ready = state.status == OnDeviceAiSettingsStatus.ready;
    final translation = state.ofRole(LlamaModelRole.translation);
    final assistants = state.ofRole(LlamaModelRole.assistant);
    final children = <Widget>[
      const _Intro(),
      if (!ready)
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (!state.supported)
        _Note(
          key: const Key('on_device_ai_unavailable'),
          icon: Icons.info_outline,
          text: kIsWeb
              ? l10n.onDeviceAiWebUnavailable
              : l10n.onDeviceAiDeviceUnavailable,
        )
      else if (state.models.isEmpty)
        _Note(
          key: const Key('on_device_ai_no_models'),
          icon: Icons.info_outline,
          text: l10n.onDeviceAiNoModels,
        )
      else ...[
        if (translation.isNotEmpty)
          SettingsSection(
            title: l10n.onDeviceAiTranslationSection,
            children: [
              _SectionDescription(l10n.onDeviceAiTranslationDescription),
              for (final model in translation) _ModelTile(model: model),
            ],
          ),
        if (assistants.isNotEmpty)
          SettingsSection(
            title: l10n.onDeviceAiAssistantSection,
            children: [
              _SectionDescription(l10n.onDeviceAiAssistantDescription),
              for (final model in assistants) _ModelTile(model: model),
            ],
          ),
        SettingsSection(
          divider: false,
          children: [
            _ImportTile(importing: state.importing),
            _CopyLinksTile(models: state.models),
            if (state.engineBuild case final build?)
              _Note(
                key: const Key('on_device_ai_engine_build'),
                icon: Icons.developer_board_outlined,
                text: engineBuildText(
                  l10n,
                  build.variant.name,
                  skipped: build.skipped.firstOrNull?.name,
                ),
              ),
          ],
        ),
      ],
    ];
    return MultiBlocListener(
      listeners: [
        BlocListener<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
          listenWhen: (previous, current) =>
              current.outcome != null && current.outcome != previous.outcome,
          listener: (context, state) => _onOutcome(context, state.outcome!),
        ),
        BlocListener<OnDeviceAiSettingsCubit, OnDeviceAiSettingsState>(
          listenWhen: (previous, current) =>
              current.importOutcome != null &&
              current.importOutcome != previous.importOutcome,
          listener: (context, state) =>
              _showSnackBar(context, _importMessage(context, state)),
        ),
      ],
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.onDeviceAiTitle)),
        body: LayoutBuilder(
          builder: (context, constraints) => ListView(
            padding: centeredPadding(constraints.maxWidth),
            children: children,
          ),
        ),
      ),
    );
  }

  Future<void> _onOutcome(
    BuildContext context,
    OnDeviceModelOutcome outcome,
  ) async {
    final l10n = context.l10n;
    final cubit = context.read<OnDeviceAiSettingsCubit>();
    final model = cubit.state.model(outcome.model)?.model;
    final name = model?.displayName ?? outcome.model;
    if (outcome.needsMeteredConsent) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => _MeteredDialog(
          body: l10n.onDeviceAiMeteredBody(
            name,
            formatModelSize(l10n, model?.size ?? 0),
          ),
        ),
      );
      if ((confirmed ?? false) && !cubit.isClosed) {
        await cubit.download(outcome.model, overMeteredNetwork: true);
      }
      return;
    }
    if (!context.mounted) return;
    final error = outcome.error;
    final message = switch (outcome.operation) {
      OnDeviceModelOperation.download when outcome.succeeded =>
        l10n.onDeviceAiDownloadDone(name),
      OnDeviceModelOperation.delete when outcome.succeeded =>
        l10n.onDeviceAiDeleteDone(name),
      OnDeviceModelOperation.delete => l10n.onDeviceAiDeleteFailed(name),
      OnDeviceModelOperation.download => switch ((error?.kind, error?.mirror)) {
        (OnDeviceModelErrorKind.cancelled, _) => l10n.onDeviceAiDownloadStopped(
          name,
        ),
        (OnDeviceModelErrorKind.tooBig, _) => l10n.onDeviceAiErrorTooBig(name),
        (OnDeviceModelErrorKind.checksum, final String mirror) =>
          l10n.onDeviceAiErrorChecksumMirror(name, mirror),
        (OnDeviceModelErrorKind.checksum, _) => l10n.onDeviceAiErrorChecksum(
          name,
        ),
        (OnDeviceModelErrorKind.server, final String mirror) =>
          l10n.onDeviceAiErrorServerMirror(
            name,
            mirror,
            error?.statusCode ?? 0,
          ),
        (OnDeviceModelErrorKind.server, _) => l10n.onDeviceAiErrorServer(
          name,
          error?.statusCode ?? 0,
        ),
        (OnDeviceModelErrorKind.storage, _) => l10n.onDeviceAiErrorStorage(
          name,
        ),
        (OnDeviceModelErrorKind.space, _) => switch (error?.space) {
          final space? => _notEnoughSpace(l10n, name, space),
          null => l10n.onDeviceAiErrorStorage(name),
        },
        (OnDeviceModelErrorKind.network, final String mirror) =>
          l10n.onDeviceAiErrorNetworkMirror(name, mirror),
        (OnDeviceModelErrorKind.network, _) => l10n.onDeviceAiErrorNetwork(
          name,
        ),
        _ => l10n.onDeviceAiErrorUnknown(name),
      },
    };
    _showSnackBar(context, message);
  }

  static String _importMessage(
    BuildContext context,
    OnDeviceAiSettingsState state,
  ) {
    final l10n = context.l10n;
    final outcome = state.importOutcome!;
    if (outcome.failed) return l10n.onDeviceAiImportFailed;
    if (outcome.models.isEmpty) return l10n.onDeviceAiImportNothing;
    String name(String id) => state.model(id)?.model.displayName ?? id;
    return [
      for (final MapEntry(key: id, value: status) in outcome.models.entries)
        switch (status) {
          LlamaImportStatus.installed when outcome.tooBig.contains(id) =>
            '${l10n.onDeviceAiImportInstalled(name(id))}. '
                '${l10n.onDeviceAiImportTooBig(name(id))}',
          LlamaImportStatus.installed => l10n.onDeviceAiImportInstalled(
            name(id),
          ),
          LlamaImportStatus.alreadyInstalled =>
            l10n.onDeviceAiImportAlreadyInstalled(name(id)),
          LlamaImportStatus.checksumMismatch => l10n.onDeviceAiImportDamaged(
            name(id),
          ),
          LlamaImportStatus.failed => switch (outcome.space) {
            final space? => _notEnoughSpace(l10n, name(id), space),
            null => l10n.onDeviceAiImportFailed,
          },
        },
    ].join('\n');
  }

  /// "Not enough free space for Hy-MT2 1.8B: needs 1.2 GB, 300 MB free."
  static String _notEnoughSpace(
    AppLocalizations l10n,
    String name,
    SpaceShortfall space,
  ) => l10n.commonNotEnoughSpaceFor(
    name,
    formatStorageSize(l10n, space.requiredBytes),
    formatStorageSize(l10n, space.availableBytes),
  );

  static void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// What on-device AI is: private, offline, big downloads, memory and
/// battery.
class _Intro extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) =>
      _Note(icon: Icons.memory, text: context.l10n.onDeviceAiIntro);
}

/// A short text with an icon at the start.
class _Note extends StatelessWidget {
  const new({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(icon, size: 20, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
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

class _SectionDescription extends StatelessWidget {
  const new(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The text of [fit], and its colour.
(String, Color)? _fitLabel(BuildContext context, OnDeviceFit fit) {
  final l10n = context.l10n;
  final colors = Theme.of(context).colorScheme;
  return switch (fit) {
    OnDeviceFit.ok => (l10n.onDeviceAiFitOk, AppPalette.of(context).success),
    OnDeviceFit.slow => (l10n.onDeviceAiFitSlow, colors.tertiary),
    OnDeviceFit.tooBig => (l10n.onDeviceAiFitTooBig, colors.error),
    OnDeviceFit.unknown => null,
  };
}

/// One model: its size, licence, languages and fit; download (with
/// progress and cancel), delete, or tap to use it; an "About" button.
class _ModelTile extends StatelessWidget {
  const new({required this.model});

  final OnDeviceModel model;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<OnDeviceAiSettingsCubit>();
    final state = cubit.state;
    final catalog = model.model;
    final name = catalog.displayName;
    final operation = state.pending[model.id];
    final downloading = operation == OnDeviceModelOperation.download;
    final progress = state.progress[model.id] ?? 0;
    final inUse = model.installed && state.inUse(model.id);
    final percent = (progress * 100).floor();
    final details = [
      formatModelSize(l10n, catalog.size),
      catalog.license,
      if (catalog.languages.isNotEmpty)
        l10n.onDeviceAiLanguages(catalog.languages.length),
    ].join(' · ');
    final fit = _fitLabel(context, model.fit);
    final status = [
      if (downloading)
        l10n.onDeviceAiDownloading(percent)
      else if (!model.installed && model.partialBytes > 0)
        l10n.onDeviceAiPaused(
          (model.partialBytes * 100 / catalog.size).floor(),
        ),
      if (inUse) l10n.onDeviceAiInUse,
    ];
    final subtitle = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(details),
        if (fit case (final label, final color))
          Text(
            label,
            key: Key('on_device_ai_fit_${model.id}'),
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        if (status.isNotEmpty) Text(status.join(' · ')),
        if (downloading)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(
              value: progress > 0 ? progress : null,
              semanticsLabel: l10n.onDeviceAiDownloading(percent),
            ),
          ),
      ],
    );
    final Widget action;
    if (operation == OnDeviceModelOperation.delete) {
      action = const SizedBox.square(
        dimension: 48,
        child: Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else if (downloading) {
      action = IconButton(
        key: Key('on_device_ai_cancel_${model.id}'),
        tooltip: l10n.onDeviceAiCancelTooltip(name),
        icon: const Icon(Icons.close),
        onPressed: () => cubit.cancel(model.id),
      );
    } else if (model.installed) {
      action = IconButton(
        key: Key('on_device_ai_delete_${model.id}'),
        tooltip: l10n.onDeviceAiDeleteTooltip(name),
        icon: const Icon(Icons.delete_outline),
        onPressed: () => unawaited(_confirmDelete(context, cubit, name)),
      );
    } else if (model.fit == OnDeviceFit.tooBig) {
      // Not offered: importing the file stays possible.
      action = const SizedBox.shrink();
    } else {
      action = IconButton(
        key: Key('on_device_ai_download_${model.id}'),
        tooltip: l10n.onDeviceAiDownloadTooltip(name),
        icon: const Icon(Icons.download_outlined),
        onPressed: () => unawaited(cubit.download(model.id)),
      );
    }
    return ListTile(
      key: Key('on_device_ai_model_${model.id}'),
      // In use: read as selected (and drawn in the primary colour).
      selected: inUse,
      isThreeLine: true,
      leading: SettingsIcon(
        inUse
            ? Icons.check_circle
            : switch (model.role) {
                LlamaModelRole.translation => Icons.translate,
                LlamaModelRole.assistant => Icons.auto_awesome_outlined,
              },
        color: inUse ? theme.colorScheme.primary : null,
      ),
      title: Text(name),
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('on_device_ai_about_${model.id}'),
            tooltip: l10n.onDeviceAiAboutTooltip(name),
            icon: const Icon(Icons.info_outline),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => BlocProvider.value(
                value: cubit,
                child: _AboutDialog(model: model),
              ),
            ),
          ),
          action,
        ],
      ),
      onTap: model.installed && !inUse && operation == null
          ? () => unawaited(cubit.select(model.id))
          : null,
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    OnDeviceAiSettingsCubit cubit,
    String name,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.onDeviceAiDeleteTitle(name)),
        content: Text(l10n.onDeviceAiDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            key: const Key('on_device_ai_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if ((confirmed ?? false) && !cubit.isClosed) await cubit.delete(model.id);
  }
}

/// What a model is: parameters, size, memory, licence, source and (for a
/// translation model) its languages; discards a partial download.
class _AboutDialog extends StatelessWidget {
  const new({required this.model});

  final OnDeviceModel model;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final catalog = model.model;
    const mebibyte = 1024 * 1024;
    final fit = _fitLabel(context, model.fit);
    final languages = [
      for (final code in catalog.languages) context.languageNameOf(code),
    ]..sort();
    return AlertDialog(
      title: Text(catalog.displayName),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.onDeviceAiAboutParameters(
              catalog.parameters,
              catalog.quantization,
            ),
          ),
          Text(l10n.onDeviceAiAboutSize(formatModelSize(l10n, catalog.size))),
          Text(
            l10n.onDeviceAiAboutMemory(
              formatModelSize(l10n, catalog.minRamMb * mebibyte),
              formatModelSize(l10n, catalog.recommendedRamMb * mebibyte),
            ),
          ),
          if (fit case (final label, final color))
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          const SizedBox(height: 8),
          _LinkRow(
            key: const Key('on_device_ai_about_license'),
            label: l10n.onDeviceAiAboutLicense(catalog.license),
            url: catalog.licenseUrl,
          ),
          _LinkRow(
            key: const Key('on_device_ai_about_source'),
            label: l10n.onDeviceAiAboutSource,
            url: catalog.sourceUrl,
          ),
          if (languages.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              l10n.onDeviceAiAboutLanguages,
              style: theme.textTheme.titleSmall,
            ),
            Text(languages.join(', ')),
          ],
        ],
      ),
      actions: [
        if (!model.installed && model.partialBytes > 0)
          TextButton(
            key: const Key('on_device_ai_discard'),
            onPressed: () {
              final cubit = context.read<OnDeviceAiSettingsCubit>();
              Navigator.of(context).pop();
              unawaited(cubit.delete(model.id));
            },
            child: Text(l10n.onDeviceAiDiscardAction),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}

/// A link opened in the browser (the user's choice).
class _LinkRow extends StatelessWidget {
  const new({required this.label, required this.url, super.key});

  final String label;
  final Uri url;

  // In a start-aligned column: as wide as its label.
  @override
  Widget build(BuildContext context) => TextButton.icon(
    style: TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size(48, 48),
    ),
    onPressed: () => unawaited(LinkLauncher.open(context, url)),
    icon: const Icon(Icons.open_in_new, size: 18),
    label: Text(label),
  );
}

/// "Import from files": installs models downloaded by hand, offline.
class _ImportTile extends StatelessWidget {
  const new({required this.importing});

  final bool importing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      key: const Key('on_device_ai_import'),
      leading: const SettingsIcon(Icons.file_open_outlined),
      title: Text(importing ? l10n.offlineImporting : l10n.offlineImportAction),
      subtitle: Text(l10n.onDeviceAiImportSubtitle),
      trailing: importing
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: importing
          ? null
          : () => unawaited(
              context.read<OnDeviceAiSettingsCubit>().importFromFiles(),
            ),
    );
  }
}

/// Copies the download links of the models (to fetch them elsewhere and
/// import them here).
class _CopyLinksTile extends StatelessWidget {
  const new({required this.models});

  final List<OnDeviceModel> models;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      key: const Key('on_device_ai_copy_links'),
      leading: const SettingsIcon(Icons.link),
      title: Text(l10n.voiceModelCopyLinks),
      subtitle: Text(l10n.onDeviceAiCopyLinksSubtitle),
      onTap: () async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        await copyText(
          [for (final model in models) '${model.model.url}'].join('\n'),
        );
        if (systemShowsCopyConfirmation) return;
        messenger
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(l10n.commonCopied)));
      },
    );
  }
}

/// Asks whether to download over a metered network.
class _MeteredDialog extends StatelessWidget {
  const new({required this.body});

  final String body;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      icon: const Icon(Icons.signal_cellular_alt),
      title: Text(l10n.offlineMeteredTitle),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('on_device_ai_metered_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.offlineMeteredDownloadAnyway),
        ),
      ],
    );
  }
}
