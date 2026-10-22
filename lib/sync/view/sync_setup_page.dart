import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/backup/view/widgets/passphrase_field.dart';
import 'package:mozhi/core/network/network_policy.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi/sync/cubit/sync_setup_cubit.dart';
import 'package:mozhi/sync/data/sync_service.dart';
import 'package:mozhi/sync/models/sync_config.dart';
import 'package:mozhi/sync/models/sync_status.dart';
import 'package:mozhi/sync/view/sync_texts.dart';
import 'package:mozhi/sync/view/widgets/sync_fields.dart';

/// Opens the sync setup over the current screen with [service]; shows
/// "Sync is on" when it was turned on.
Future<void> showSyncSetup(BuildContext context, SyncService service) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = context.l10n;
  final done = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => SyncSetupPage(service: service),
    ),
  );
  if (done ?? false) {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.syncTurnedOn)));
  }
}

/// The sync setup: provides a [SyncSetupCubit] for [service]; pops true
/// once sync is on.
class SyncSetupPage extends StatelessWidget {
  const new({required this.service, super.key});

  final SyncService service;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => SyncSetupCubit(service),
    child: const SyncSetupView(),
  );
}

/// The setup form: the WebDAV address, user name, app password and folder
/// with **Test connection**; once the connection works, the passphrase
/// (the other devices' one when a sync file is there, a new one with its
/// strength otherwise) and what to sync, then **Turn on sync**.
class SyncSetupView extends StatefulWidget {
  const new({super.key});

  @override
  State<SyncSetupView> createState() => _SyncSetupViewState();
}

class _SyncSetupViewState extends State<SyncSetupView> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _folder = TextEditingController(text: SyncConfig.defaultFolder);
  final _passphrase = TextEditingController();
  final _repeat = TextEditingController();
  Set<String> _excluded = SyncConfig.defaultExcludedSections;
  bool _includeSecrets = false;
  bool _wifiOnly = false;
  bool _showErrors = false;
  bool _showPassphraseErrors = false;

  @override
  void dispose() {
    for (final controller in [
      _server,
      _user,
      _password,
      _folder,
      _passphrase,
      _repeat,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  SyncConnection? get _connection {
    final server = SyncAddress.server(_server.text);
    final user = _user.text.trim();
    if (server == null || user.isEmpty || _password.text.isEmpty) return null;
    return SyncConnection(
      server: server,
      username: user,
      password: _password.text,
      folder: SyncAddress.folder(_folder.text),
    );
  }

  void _edited() {
    final connection = _connection;
    if (connection != null) context.read<SyncSetupCubit>().edited(connection);
    setState(() {});
  }

  Future<void> _test() async {
    final connection = _connection;
    if (connection == null) {
      setState(() => _showErrors = true);
      return;
    }
    FocusScope.of(context).unfocus();
    await context.read<SyncSetupCubit>().test(connection);
  }

  bool _passphraseValid(bool joining) {
    if (joining) return _passphrase.text.isNotEmpty;
    return PassphraseStrength.of(_passphrase.text).acceptable &&
        _passphrase.text == _repeat.text;
  }

  Future<void> _turnOn(SyncSetupState state) async {
    final joining = state.probe?.hasSyncFile ?? false;
    if (!_passphraseValid(joining)) {
      setState(() => _showPassphraseErrors = true);
      return;
    }
    final connection = _connection;
    if (connection == null) return;
    FocusScope.of(context).unfocus();
    await context.read<SyncSetupCubit>().turnOn(
      passphrase: _passphrase.text,
      options: SyncConfig(
        server: connection.server,
        username: connection.username,
        folder: connection.folder,
        excludedSections: _excluded,
        includeSecrets: _includeSecrets,
        wifiOnly: _wifiOnly,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocConsumer<SyncSetupCubit, SyncSetupState>(
      listenWhen: (previous, current) => current.step == SyncSetupStep.done,
      listener: (context, state) => Navigator.of(context).pop(true),
      builder: (context, state) => Scaffold(
        appBar: AppBar(title: Text(l10n.syncSetupTitle)),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) => AutofillGroup(
              child: ListView(
                padding: centeredPadding(
                  constraints.maxWidth,
                  maxWidth: 640,
                  top: AppSpacing.lg,
                ),
                children: [
                  ..._connectionPart(state),
                  if (state.step != SyncSetupStep.editing &&
                      state.step != SyncSetupStep.testing)
                    ..._passphrasePart(state),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _connectionPart(SyncSetupState state) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final busy = state.busy;
    final serverError = _showErrors && SyncAddress.server(_server.text) == null
        ? (_server.text.trim().isEmpty
              ? l10n.syncFieldRequired
              : l10n.syncServerInvalid)
        : null;
    return [
      Text(l10n.syncSetupIntro, style: theme.textTheme.bodyMedium),
      if (kIsWeb) ...[
        const SizedBox(height: AppSpacing.sm),
        Text(
          l10n.syncWebCorsNote,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
      const SizedBox(height: AppSpacing.xl),
      TextField(
        key: const Key('sync_server'),
        controller: _server,
        enabled: !busy,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.url],
        onChanged: (_) => _edited(),
        decoration: InputDecoration(
          labelText: l10n.syncServerLabel,
          hintText: l10n.syncServerHint,
          helperText: l10n.syncServerHelper,
          helperMaxLines: 3,
          errorText: serverError,
          errorMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      TextField(
        key: const Key('sync_user'),
        controller: _user,
        enabled: !busy,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.username],
        onChanged: (_) => _edited(),
        decoration: InputDecoration(
          labelText: l10n.syncUserLabel,
          errorText: _showErrors && _user.text.trim().isEmpty
              ? l10n.syncFieldRequired
              : null,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      SyncPasswordField(
        key: const Key('sync_password'),
        controller: _password,
        enabled: !busy,
        helperText: l10n.syncPasswordHelper,
        errorText: _showErrors && _password.text.isEmpty
            ? l10n.syncFieldRequired
            : null,
        textInputAction: TextInputAction.next,
        onChanged: (_) => _edited(),
      ),
      const SizedBox(height: AppSpacing.lg),
      TextField(
        key: const Key('sync_folder'),
        controller: _folder,
        enabled: !busy,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        onChanged: (_) => _edited(),
        onSubmitted: (_) => unawaited(_test()),
        decoration: InputDecoration(
          labelText: l10n.syncFolderLabel,
          helperText: l10n.syncFolderHelper,
          helperMaxLines: 2,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton.tonalIcon(
          key: const Key('sync_test'),
          onPressed: busy ? null : _test,
          icon: state.step == SyncSetupStep.testing
              ? const SyncSpinner()
              : const Icon(Icons.wifi_tethering),
          label: Text(
            state.step == SyncSetupStep.testing
                ? l10n.syncTesting
                : l10n.syncTest,
          ),
        ),
      ),
      if (state.step == SyncSetupStep.editing && state.failure != null)
        _Message(
          error: true,
          text: describeSyncFailure(l10n, state.failure!, cause: state.cause),
        ),
      if (state.probe case final probe?
          when state.step != SyncSetupStep.editing)
        _Message(
          text: probe.hasSyncFile
              ? l10n.syncTestFoundFile
              : probe.folderExists
              ? l10n.syncTestNoFile
              : l10n.syncTestNoFolder,
        ),
    ];
  }

  List<Widget> _passphrasePart(SyncSetupState state) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final joining = state.probe?.hasSyncFile ?? false;
    final busy = state.busy;
    final strength = PassphraseStrength.of(_passphrase.text);
    String? passphraseError;
    String? repeatError;
    if (_showPassphraseErrors) {
      if (_passphrase.text.isEmpty) {
        passphraseError = l10n.syncFieldRequired;
      } else if (!joining && !strength.acceptable) {
        passphraseError = l10n.backupPassphraseTooShort(
          PassphraseStrength.minLength,
        );
      } else if (!joining && _passphrase.text != _repeat.text) {
        repeatError = l10n.backupPassphraseMismatch;
      }
    }
    if (state.failure == SyncFailure.wrongPassphrase) {
      passphraseError = l10n.syncFailureWrongPassphrase;
    }
    return [
      const SizedBox(height: AppSpacing.xl),
      PassphraseField(
        key: const Key('sync_passphrase'),
        controller: _passphrase,
        label: l10n.backupPassphrase,
        newPassphrase: !joining,
        enabled: !busy,
        helperText: joining
            ? l10n.syncPassphraseJoinHelper
            : l10n.syncPassphraseNewHelper,
        errorText: passphraseError,
        textInputAction: joining ? TextInputAction.done : TextInputAction.next,
        onChanged: (_) => setState(() {}),
      ),
      if (!joining) ...[
        PassphraseStrengthHint(passphrase: _passphrase.text),
        const SizedBox(height: AppSpacing.lg),
        PassphraseField(
          key: const Key('sync_passphrase_repeat'),
          controller: _repeat,
          label: l10n.backupPassphraseRepeat,
          newPassphrase: true,
          enabled: !busy,
          errorText: repeatError,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {}),
        ),
      ],
      if (joining) _Message(text: l10n.syncJoinNote),
      const SizedBox(height: AppSpacing.xl),
      Text(l10n.syncWhatToSync, style: theme.textTheme.titleSmall),
      SyncSectionsPicker(
        sectionIds: context.read<SyncSetupCubit>().sectionIds,
        excluded: _excluded,
        includeSecrets: _includeSecrets,
        enabled: !busy,
        onExcludedChanged: (excluded) => setState(() => _excluded = excluded),
        onIncludeSecretsChanged: (value) =>
            setState(() => _includeSecrets = value),
      ),
      if (!kIsWeb)
        SwitchListTile(
          key: const Key('sync_wifi_only'),
          contentPadding: EdgeInsets.zero,
          secondary: const ExcludeSemantics(child: Icon(Icons.wifi)),
          title: Text(l10n.syncWifiOnly),
          subtitle: Text(l10n.syncWifiOnlySubtitle),
          value: _wifiOnly,
          onChanged: busy ? null : (value) => setState(() => _wifiOnly = value),
        ),
      const SizedBox(height: AppSpacing.xl),
      if (state.failure case final failure?
          when failure != SyncFailure.wrongPassphrase)
        _Message(
          error: true,
          text: describeSyncFailure(l10n, failure, cause: state.cause),
        ),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: FilledButton.icon(
          key: const Key('sync_turn_on'),
          onPressed: busy ? null : () => _turnOn(state),
          icon: state.step == SyncSetupStep.turningOn
              ? const SyncSpinner()
              : const Icon(Icons.cloud_sync_outlined),
          label: Text(
            state.step == SyncSetupStep.turningOn
                ? l10n.syncTurningOn
                : l10n.syncTurnOn,
          ),
        ),
      ),
    ];
  }
}

/// The setup's address and folder fields as sync uses them.
abstract final class SyncAddress {
  /// The address as typed, with `https://` when it has no scheme; null
  /// when it is not a usable http(s) address, or is plain http to a public
  /// server (the network policy would refuse it).
  static Uri? server(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(
      trimmed.contains('://') ? trimmed : 'https://$trimmed',
    );
    if (uri == null ||
        !(uri.isScheme('https') || uri.isScheme('http')) ||
        uri.host.isEmpty ||
        !isCleartextAllowed(uri)) {
      return null;
    }
    return uri;
  }

  /// [text] without surrounding slashes and spaces (`/Apps/Mozhi/` →
  /// `Apps/Mozhi`); empty for the WebDAV address itself.
  static String folder(String text) => text
      .split('/')
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .join('/');
}

/// A result line under a step: a check (or, for an [error], an error
/// icon) and [text], announced to screen readers.
class _Message extends StatelessWidget {
  const new({required this.text, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = error
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Semantics(
        liveRegion: true,
        container: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Icon(
                error ? Icons.error_outline : Icons.check_circle_outline,
                size: 20,
                color: error ? color : theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
