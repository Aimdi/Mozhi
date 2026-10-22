import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/insecure_http_warning.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// What the "Model source" row shows for [source]: the original
/// publishers, this web server, or the mirror's host, and whether the
/// original publishers are the fallback.
String modelSourceSummary(AppLocalizations l10n, ModelSource source) {
  final name = switch (source.kind) {
    ModelSourceKind.defaultHosts => l10n.settingsModelSourceDefault,
    ModelSourceKind.thisServer => l10n.settingsModelSourceThisServer,
    ModelSourceKind.custom => l10n.settingsModelSourceMirror(
      modelSourceHost(source) ?? '',
    ),
  };
  return source.fallsBackToDefault
      ? l10n.settingsModelSourceWithFallback(name)
      : name;
}

/// The host (and port) of [source]'s mirror, as shown to the user; null
/// for the original publishers.
String? modelSourceHost(ModelSource source, {Uri? appBase}) {
  final mirror = source.mirror(appBase: appBase);
  if (mirror == null) return null;
  return mirror.hasPort ? '${mirror.host}:${mirror.port}' : mirror.host;
}

/// "Model source": where on-device models are downloaded from
/// (`AppSettings.modelSource`), changed in a [ModelSourceDialog]. Reads
/// and changes the [SettingsCubit] above; shows nothing without one.
class ModelSourceTile extends StatelessWidget {
  const new({super.key});

  /// Key of the tile.
  static const tileKey = Key('settings_model_source');

  @override
  Widget build(BuildContext context) {
    final SettingsCubit cubit;
    try {
      cubit = context.read<SettingsCubit>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    return BlocSelector<SettingsCubit, AppSettings, ModelSource>(
      bloc: cubit,
      selector: (settings) => settings.modelSource,
      builder: (context, source) {
        final l10n = context.l10n;
        return ListTile(
          key: tileKey,
          leading: const SettingsIcon(Icons.cloud_download_outlined),
          title: Text(l10n.settingsModelSource),
          subtitle: Text(modelSourceSummary(l10n, source)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(_pick(context, cubit, source)),
        );
      },
    );
  }

  Future<void> _pick(
    BuildContext context,
    SettingsCubit cubit,
    ModelSource current,
  ) async {
    final chosen = await showDialog<ModelSource>(
      context: context,
      builder: (context) => ModelSourceDialog(initial: current),
    );
    if (chosen != null && chosen != current) cubit.setModelSource(chosen);
  }
}

/// Picks the [ModelSource]: the original publishers, this web server
/// ([offerThisServer], default in a browser) or a custom mirror with its
/// address (https, or http on this device, the local network and `.onion`
/// / `.i2p`; plain http to a public server is refused with the
/// insecure-HTTP warning), and whether a file the mirror lacks comes from
/// the original publishers. Pops the chosen source, or null when
/// cancelled.
class ModelSourceDialog extends StatefulWidget {
  const new({
    required this.initial,
    this.offerThisServer = kIsWeb,
    this.appBase,
    this.proxyActive,
    super.key,
  });

  final ModelSource initial;

  /// Whether "This web server" is offered (only a web app has one).
  final bool offerThisServer;

  /// The web app's base URL, for the "This web server" address (default:
  /// the browser's `document.baseURI`).
  final Uri? appBase;

  /// Whether a proxy is set (default: the current `NetworkSession`'s), for
  /// the note on `.onion` / `.i2p` mirrors.
  final bool? proxyActive;

  /// Key of the mirror address field.
  static const urlFieldKey = Key('model_source_url');

  /// Key of the "use the original publishers" switch.
  static const fallbackKey = Key('model_source_fallback');

  /// Key of the Save action.
  static const saveKey = Key('model_source_save');

  @override
  State<ModelSourceDialog> createState() => _ModelSourceDialogState();
}

class _ModelSourceDialogState extends State<ModelSourceDialog> {
  late ModelSourceKind _kind = widget.initial.kind;
  late bool _fallback = widget.initial.fallbackToDefault;
  late final _url = TextEditingController(text: widget.initial.customUrl);
  final _urlFocus = FocusNode();
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  bool get _proxyActive =>
      widget.proxyActive ?? NetworkSession.current.hasProxy;

  Uri? get _typed {
    final text = _url.text.trim();
    if (text.isEmpty) return null;
    return Uri.tryParse(text.contains('://') ? text : 'https://$text');
  }

  void _choose(ModelSourceKind? kind) {
    if (kind == null) return;
    setState(() {
      _kind = kind;
      _error = null;
    });
    if (kind == ModelSourceKind.custom) _urlFocus.requestFocus();
  }

  void _save() {
    final l10n = context.l10n;
    var customUrl = widget.initial.customUrl;
    if (_kind == ModelSourceKind.custom) {
      final problem = ModelSource.mirrorUrlProblem(_url.text);
      if (problem != null) {
        setState(
          () => _error = switch (problem) {
            ModelMirrorUrlProblem.invalid => l10n.settingsModelSourceUrlInvalid,
            ModelMirrorUrlProblem.credentials =>
              l10n.settingsModelSourceUrlCredentials,
            ModelMirrorUrlProblem.query => l10n.settingsModelSourceUrlQuery,
            ModelMirrorUrlProblem.cleartext => l10n.commonHttpsRequired,
          },
        );
        _urlFocus.requestFocus();
        return;
      }
      customUrl = ModelSource.normalizeMirrorUrl(_url.text).toString();
    }
    Navigator.of(context).pop(
      ModelSource(
        kind: _kind,
        customUrl: customUrl,
        fallbackToDefault: _fallback,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final typed = _typed;
    final custom = _kind == ModelSourceKind.custom;
    final insecure = custom && typed != null && !isCleartextAllowed(typed);
    final needsProxy =
        custom &&
        typed != null &&
        !_proxyActive &&
        isHiddenServiceHost(typed.host);
    final thisServer = const ModelSource(kind: ModelSourceKind.thisServer)
        .mirror(appBase: widget.appBase);
    return AlertDialog(
      icon: const Icon(Icons.cloud_download_outlined),
      title: Text(l10n.settingsModelSource),
      scrollable: true,
      contentPadding: const EdgeInsets.only(top: 16, bottom: 8),
      content: RadioGroup<ModelSourceKind>(
        groupValue: _kind,
        onChanged: _choose,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(l10n.settingsModelSourceDialogBody),
            ),
            const SizedBox(height: 8),
            RadioListTile<ModelSourceKind>(
              value: ModelSourceKind.defaultHosts,
              title: Text(l10n.settingsModelSourceDefault),
              subtitle: Text(l10n.settingsModelSourceDefaultSubtitle),
            ),
            if (widget.offerThisServer ||
                widget.initial.kind == ModelSourceKind.thisServer)
              RadioListTile<ModelSourceKind>(
                value: ModelSourceKind.thisServer,
                title: Text(l10n.settingsModelSourceThisServer),
                subtitle: Text(
                  l10n.settingsModelSourceThisServerSubtitle(
                    thisServer?.toString() ?? '/models/',
                  ),
                ),
              ),
            RadioListTile<ModelSourceKind>(
              value: ModelSourceKind.custom,
              title: Text(l10n.settingsModelSourceCustom),
              subtitle: Text(l10n.settingsModelSourceCustomSubtitle),
            ),
            if (custom)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: ModelSourceDialog.urlFieldKey,
                      controller: _url,
                      focusNode: _urlFocus,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: imeLearningAllowed(
                        context,
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      inputFormatters: [
                        FilteringTextInputFormatter.deny(RegExp(r'\s')),
                      ],
                      decoration: InputDecoration(
                        labelText: l10n.settingsModelSourceUrlLabel,
                        hintText: l10n.settingsModelSourceUrlHint,
                        prefixIcon: const Icon(Icons.link),
                        errorText: _error,
                        errorMaxLines: 4,
                        border: const OutlineInputBorder(),
                      ),
                      // Rebuild for the banners; drop a stale error.
                      onChanged: (_) => setState(() => _error = null),
                      onSubmitted: (_) => _save(),
                    ),
                    if (insecure) ...[
                      const SizedBox(height: 12),
                      InsecureHttpWarning(
                        key: const Key('model_source_insecure_warning'),
                        title: l10n.settingsInstanceInsecureTitle,
                        text: l10n.commonErrorCleartextRefused,
                      ),
                    ],
                    if (needsProxy) ...[
                      const SizedBox(height: 12),
                      Row(
                        key: const Key('model_source_needs_proxy'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.vpn_lock_outlined,
                            size: 20,
                            color: colors.warning,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Semantics(
                              container: true,
                              liveRegion: true,
                              child: Text(l10n.settingsInstanceNeedsProxyNote),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            if (_kind != ModelSourceKind.defaultHosts) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                key: ModelSourceDialog.fallbackKey,
                title: Text(l10n.settingsModelSourceFallback),
                subtitle: Text(l10n.settingsModelSourceFallbackSubtitle),
                value: _fallback,
                onChanged: (value) => setState(() => _fallback = value),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: ModelSourceDialog.saveKey,
          onPressed: _save,
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
