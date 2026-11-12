import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/offline/data/mirror_hosting.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/settings/view/widgets/model_source_dialog.dart'
    show pickModelSource;

/// How to mirror the downloads on the web app's server.
final Uri mirrorHostingHelpUrl = Uri.parse(
  'https://github.com/Aimdi/Mozhi/blob/main/docs/self-hosting-mozhi.md'
  '#mirror-the-on-device-models',
);

/// Builds [builder] with whether downloads of [kind] cannot work here
/// ([MirrorHostingProbe.downloadBlock] with the settings' model source,
/// else [ModelSource.current]): false until the probe first answers, asked
/// again when the model source or [kind] changes. The reason
/// ([blockOf]) is there for the [MirrorNotHostedBanner] below.
class MirrorHostingBuilder extends StatefulWidget {
  const new({required this.kind, required this.builder, super.key, this.probe});

  /// Why the downloads of the nearest [MirrorHostingBuilder] above
  /// [context] cannot work, or null (none above, or they may).
  static DownloadBlock? blockOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DownloadBlockScope>()?.block;

  final MirrorDataKind kind;

  /// Default: [MirrorHostingProbe.instance].
  final MirrorHostingProbe? probe;

  final Widget Function(BuildContext context, {required bool blocked}) builder;

  @override
  State<MirrorHostingBuilder> createState() => _MirrorHostingBuilderState();
}

class _MirrorHostingBuilderState extends State<MirrorHostingBuilder> {
  (ModelSource, MirrorDataKind)? _asked;
  DownloadBlock? _block;

  void _probe((ModelSource, MirrorDataKind) question) {
    final (source, kind) = question;
    final probe = widget.probe ?? MirrorHostingProbe.instance;
    unawaited(
      probe.downloadBlock(kind, source).then((block) {
        if (mounted && _asked == question && block != _block) {
          setState(() => _block = block);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final question = (_modelSource(context), widget.kind);
    if (question != _asked) {
      _asked = question;
      _probe(question);
    }
    return _DownloadBlockScope(
      block: _block,
      child: Builder(
        builder: (context) => widget.builder(context, blocked: _block != null),
      ),
    );
  }
}

class _DownloadBlockScope extends InheritedWidget {
  const new({required this.block, required super.child});

  final DownloadBlock? block;

  @override
  bool updateShouldNotify(_DownloadBlockScope oldWidget) =>
      block != oldWidget.block;
}

/// The model source in use: the settings' (rebuilding when it changes),
/// else [ModelSource.current].
ModelSource _modelSource(BuildContext context) {
  try {
    return context.select<SettingsCubit, ModelSource>(
      (cubit) => cubit.state.modelSource,
    );
  } on ProviderNotFoundException {
    return ModelSource.current;
  }
}

/// This screen's downloads cannot work in the web app ([block], default
/// the reason of the [MirrorHostingBuilder] above, else
/// [DownloadBlock.notHosted]): says why once, before any download fails.
///
/// * [DownloadBlock.notHosted]: the web app's server does not host them,
///   with a link to how to mirror them ([mirrorHostingHelpUrl]).
/// * [DownloadBlock.browserRefused]: the original publishers do not let a
///   web page download them, with "Change the model source" (when a
///   [SettingsCubit] is above) and the same link.
///
/// Both offer "Import from files" ([onImport]; none when null).
class MirrorNotHostedBanner extends StatelessWidget {
  const new({this.onImport, this.importing = false, this.block, super.key});

  final VoidCallback? onImport;

  /// An import is running ([onImport] is disabled).
  final bool importing;

  /// Why the downloads cannot work (default: see the class).
  final DownloadBlock? block;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final onImport = this.onImport;
    final refused =
        (block ??
            MirrorHostingBuilder.blockOf(context) ??
            DownloadBlock.notHosted) ==
        DownloadBlock.browserRefused;
    final settings = _maybeSettings(context);
    return Padding(
      key: const Key('mirror_not_hosted'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: palette.hairline),
          borderRadius: AppLook.of(context).cardRadius,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Icon(
                refused ? Icons.public_off_outlined : Icons.cloud_off_outlined,
                color: theme.colorScheme.primary,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        refused
                            ? l10n.offlineBrowserRefusedTitle
                            : l10n.offlineMirrorNotHostedTitle,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      refused
                          ? l10n.offlineBrowserRefusedBody
                          : l10n.offlineMirrorNotHostedBody,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.secondaryText,
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (onImport != null)
                          FilledButton.tonalIcon(
                            key: const Key('mirror_not_hosted_import'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: importing ? null : onImport,
                            icon: const Icon(Icons.file_open_outlined),
                            label: Text(l10n.offlineImportAction),
                          ),
                        if (refused && settings != null)
                          TextButton.icon(
                            key: const Key('mirror_not_hosted_source'),
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: () =>
                                unawaited(pickModelSource(context, settings)),
                            icon: const Icon(Icons.cloud_download_outlined),
                            label: Text(l10n.offlineBrowserRefusedSource),
                          ),
                        TextButton.icon(
                          key: const Key('mirror_not_hosted_help'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () => unawaited(
                            LinkLauncher.open(context, mirrorHostingHelpUrl),
                          ),
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: Text(l10n.offlineMirrorNotHostedHelp),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

SettingsCubit? _maybeSettings(BuildContext context) {
  try {
    return context.read<SettingsCubit>();
  } on ProviderNotFoundException {
    return null;
  }
}
