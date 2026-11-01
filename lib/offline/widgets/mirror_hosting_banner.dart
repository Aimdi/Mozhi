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

/// How to mirror the downloads on the web app's server.
final Uri mirrorHostingHelpUrl = Uri.parse(
  'https://github.com/Aimdi/Mozhi/blob/main/docs/self-hosting-mozhi.md'
  '#mirror-the-on-device-models',
);

/// Builds [builder] with whether downloads of [kind] cannot work here
/// ([MirrorHostingProbe.downloadsBlocked] with the settings' model
/// source, else [ModelSource.current]): false until the probe first
/// answers, asked again when the model source or [kind] changes.
class MirrorHostingBuilder extends StatefulWidget {
  const new({required this.kind, required this.builder, super.key, this.probe});

  final MirrorDataKind kind;

  /// Default: [MirrorHostingProbe.instance].
  final MirrorHostingProbe? probe;

  final Widget Function(BuildContext context, {required bool blocked}) builder;

  @override
  State<MirrorHostingBuilder> createState() => _MirrorHostingBuilderState();
}

class _MirrorHostingBuilderState extends State<MirrorHostingBuilder> {
  (ModelSource, MirrorDataKind)? _asked;
  bool _blocked = false;

  void _probe((ModelSource, MirrorDataKind) question) {
    final (source, kind) = question;
    final probe = widget.probe ?? MirrorHostingProbe.instance;
    unawaited(
      probe.downloadsBlocked(kind, source).then((blocked) {
        if (mounted && _asked == question && blocked != _blocked) {
          setState(() => _blocked = blocked);
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
    return widget.builder(context, blocked: _blocked);
  }
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

/// The web app's server does not host this screen's downloads: says so
/// once, with "Import from files" ([onImport]; none when null) and a link
/// to how to mirror them ([mirrorHostingHelpUrl]).
class MirrorNotHostedBanner extends StatelessWidget {
  const new({this.onImport, this.importing = false, super.key});

  final VoidCallback? onImport;

  /// An import is running ([onImport] is disabled).
  final bool importing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final onImport = this.onImport;
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
              Icon(Icons.cloud_off_outlined, color: theme.colorScheme.primary),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        l10n.offlineMirrorNotHostedTitle,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      l10n.offlineMirrorNotHostedBody,
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
