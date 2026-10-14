import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/insecure_http_warning.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi_api/mozhi_api.dart';
import 'package:translation_repository/translation_repository.dart';

/// User-facing text for a failure (repository/API errors carry a message).
String describeError(Object error) => switch (error) {
  MozhiApiException(:final message) => message,
  LlmApiException(:final message, :final statusCode) =>
    statusCode == null ? message : '$statusCode: $message',
  FormatException(:final message) => message,
  _ => error.toString(),
};

/// Why [input] must not be saved as a service URL, or null when it is fine:
/// `userInfo` (`https://user:pass@host`) and query strings (`?key=…`) would
/// put credentials into plain preferences, backups, the UI and error
/// messages.
UrlSecretProblem? urlSecretProblem(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  final hasScheme = RegExp('^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmed);
  final uri = Uri.tryParse(hasScheme ? trimmed : '//$trimmed');
  if (uri == null) return null;
  if (uri.userInfo.isNotEmpty) return UrlSecretProblem.credentials;
  if (uri.hasQuery) return UrlSecretProblem.query;
  return null;
}

/// See [urlSecretProblem].
enum UrlSecretProblem { credentials, query }

/// Asks for an instance URL (+ optional label) and returns the new
/// [MozhiInstance], or null when cancelled. [existingUrls] are rejected as
/// duplicates.
///
/// A plain `http://` URL to a host outside the device and the local network
/// ([isInsecureHttp]) shows a warning banner, and adding it needs an
/// explicit confirmation (the translated text would travel unencrypted).
class AddInstanceDialog extends StatefulWidget {
  const new({required this.existingUrls, super.key});

  final List<String> existingUrls;

  @override
  State<AddInstanceDialog> createState() => _AddInstanceDialogState();
}

sealed class _TestState {
  const new();
}

class _Testing extends _TestState {
  const new();
}

class _TestOk extends _TestState {
  const new(this.latency);
  final Duration latency;
}

class _TestFailed extends _TestState {
  const new(this.message);
  final String message;
}

class _AddInstanceDialogState extends State<AddInstanceDialog> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _labelController = TextEditingController();
  final _urlFocus = FocusNode();
  _TestState? _test;

  /// The plain-http URL the user agreed to add without encryption.
  String? _insecureConfirmedFor;

  @override
  void dispose() {
    _urlController.dispose();
    _labelController.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  Uri? _normalized() {
    try {
      return MozhiApiClient.normalizeBaseUrl(_urlController.text);
    } on FormatException {
      return null;
    }
  }

  String? _validateUrl(String? value) {
    final l10n = context.l10n;
    if (value == null || value.trim().isEmpty) {
      return l10n.settingsInstanceUrlInvalid;
    }
    switch (urlSecretProblem(value)) {
      case UrlSecretProblem.credentials:
        return l10n.settingsInstanceUrlCredentials;
      case UrlSecretProblem.query:
        return l10n.settingsInstanceUrlQuery;
      case null:
    }
    final uri = _normalized();
    if (uri == null) return l10n.settingsInstanceUrlInvalid;
    if (widget.existingUrls.contains(uri.toString())) {
      return l10n.settingsInstanceUrlDuplicate;
    }
    return null;
  }

  MozhiInstance? _buildInstance() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      // The URL is the only validated field: move focus back to it so its
      // error is read and can be fixed right away (WCAG 3.3.1).
      _urlFocus.requestFocus();
      return null;
    }
    final uri = _normalized();
    if (uri == null) return null;
    final label = _labelController.text.trim();
    return MozhiInstance(
      url: uri.toString(),
      label: label.isEmpty ? null : label,
    );
  }

  Future<void> _runTest() async {
    final instance = _buildInstance();
    if (instance == null) return;
    final repository = context.read<TranslationRepository>();
    setState(() => _test = const _Testing());
    _TestState result;
    try {
      result = _TestOk(await repository.pingInstance(instance));
    } on Object catch (error) {
      result = _TestFailed(describeError(error));
    }
    if (mounted) setState(() => _test = result);
  }

  bool get _insecure => isInsecureHttp(_normalized());

  /// Asks once per URL before a plain-http instance outside the local
  /// network is added; true when it may be added.
  Future<bool> _confirmInsecure(MozhiInstance instance) async {
    final uri = Uri.parse(instance.url);
    if (!isInsecureHttp(uri) || _insecureConfirmedFor == instance.url) {
      return true;
    }
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.no_encryption_outlined),
        title: Text(l10n.settingsInstanceInsecureConfirmTitle),
        content: Text(l10n.settingsInstanceInsecureConfirmBody(uri.host)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsInstanceInsecureConfirmAction),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return false;
    _insecureConfirmedFor = instance.url;
    return true;
  }

  Future<void> _save() async {
    final instance = _buildInstance();
    if (instance == null) return;
    if (!await _confirmInsecure(instance) || !mounted) return;
    Navigator.of(context).pop(instance);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final test = _test;
    return AlertDialog(
      title: Text(l10n.settingsInstancesAdd),
      scrollable: true,
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _urlController,
              focusNode: _urlFocus,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.settingsInstanceUrl,
                hintText: l10n.settingsInstanceUrlHint,
                prefixIcon: const Icon(Icons.link),
                border: const OutlineInputBorder(),
                errorMaxLines: 4,
              ),
              validator: _validateUrl,
              // Rebuild for the insecure-http banner, and drop a stale
              // test result.
              onChanged: (_) => setState(() => _test = null),
            ),
            if (_insecure) ...[
              const SizedBox(height: 12),
              InsecureHttpWarning(
                key: const Key('instance_insecure_warning'),
                title: l10n.settingsInstanceInsecureTitle,
                text: l10n.settingsInstanceInsecureWarning,
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              controller: _labelController,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: l10n.settingsInstanceLabel,
                prefixIcon: const Icon(Icons.label_outline),
                border: const OutlineInputBorder(),
              ),
              onFieldSubmitted: (_) => unawaited(_save()),
            ),
            if (test != null) ...[
              const SizedBox(height: 16),
              switch (test) {
                _Testing() => LinearProgressIndicator(
                  semanticsLabel: l10n.settingsInstanceTesting,
                ),
                _TestOk(:final latency) => _TestMessage(
                  icon: Icons.check_circle_outline,
                  color: colors.success,
                  text: l10n.settingsInstanceTestOk(latency.inMilliseconds),
                ),
                _TestFailed(:final message) => _TestMessage(
                  icon: Icons.error_outline,
                  color: colors.error,
                  text: l10n.settingsInstanceTestFailed(message),
                ),
              },
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: test is _Testing ? null : _runTest,
          child: Text(l10n.settingsInstanceTest),
        ),
        FilledButton(
          onPressed: () => unawaited(_save()),
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }
}

/// Test outcome: a coloured icon plus text in the normal on-surface colour
/// (coloured text on the dialog surface fell below 4.5:1), announced as a
/// status message (WCAG 4.1.3).
class _TestMessage extends StatelessWidget {
  const new({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Semantics(
            container: true,
            liveRegion: true,
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ),
      ],
    );
  }
}
