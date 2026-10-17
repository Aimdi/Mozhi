import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/network/network.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/insecure_http_warning.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';
import 'package:mozhi_api/mozhi_api.dart' show MozhiApiClient;
import 'package:translation_repository/translation_repository.dart';

/// User-facing text for a failure (repository/API errors carry a message).
String describeError(Object error) => switch (error) {
  MozhiApiException(:final message) => message,
  LlmApiException(:final message, :final statusCode) =>
    statusCode == null ? message : '$statusCode: $message',
  FormatException(:final message) => message,
  _ => error.toString(),
};

/// Like [describeError], but a request the network policy refused (plain
/// http to a public server, `.onion` without a proxy, a broken proxy
/// setting) gets its localised explanation ([describeNetworkPolicyError]).
String describeErrorLocalized(AppLocalizations l10n, Object error) =>
    describeNetworkPolicyError(l10n, error) ?? describeError(error);

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
/// duplicates. With [initial] it edits that instance instead (prefilled;
/// leave its own URL out of [existingUrls]).
///
/// Plain `http://` is only accepted for this device, the local network and
/// Tor/I2P addresses ([isCleartextAllowed]): for any other host a banner
/// says so as it is typed and the URL does not validate, because the app
/// would refuse to send anything there. A Tor or I2P address while no proxy
/// is active ([proxyActive]) gets a note that it needs one.
///
/// "Test" translates `hello` with the instance through [checker] (default:
/// the session's, see [NetworkSession.instanceChecker]) and shows the
/// result and how long it took.
class AddInstanceDialog extends StatefulWidget {
  const new({
    required this.existingUrls,
    this.initial,
    this.checker,
    this.proxyActive,
    super.key,
  });

  final List<String> existingUrls;
  final MozhiInstance? initial;
  final MozhiInstanceChecker? checker;

  /// Whether requests go through a proxy (default:
  /// [NetworkSession.hasProxy] of the current session).
  final bool? proxyActive;

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
  const new(this.result);
  final InstanceTestResult result;
}

class _TestFailed extends _TestState {
  const new(this.message);
  final String message;
}

class _AddInstanceDialogState extends State<AddInstanceDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _urlController = TextEditingController(text: widget.initial?.url);
  late final _labelController = TextEditingController(
    text: widget.initial?.label,
  );
  final _urlFocus = FocusNode();
  _TestState? _test;

  MozhiInstanceChecker get _checker =>
      widget.checker ?? NetworkSession.current.instanceChecker;

  bool get _proxyActive =>
      widget.proxyActive ?? NetworkSession.current.hasProxy;

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
    if (!isCleartextAllowed(uri)) return l10n.commonHttpsRequired;
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
    final url = uri.toString();
    final initial = widget.initial;
    return MozhiInstance(
      url: url,
      label: label.isEmpty ? null : label,
      // An edited public instance stays one while its URL is the same.
      isCustom: initial == null || initial.url != url || initial.isCustom,
    );
  }

  Future<void> _runTest() async {
    final instance = _buildInstance();
    if (instance == null) return;
    final l10n = context.l10n;
    setState(() => _test = const _Testing());
    _TestState result;
    try {
      result = _TestOk(await _checker.test(instance.url));
    } on InstanceHasNoEnginesException {
      result = _TestFailed(l10n.settingsInstancesNoEngines);
    } on Object catch (error) {
      result = _TestFailed(
        l10n.settingsInstanceTestFailed(describeErrorLocalized(l10n, error)),
      );
    }
    if (mounted) setState(() => _test = result);
  }

  bool get _insecure => switch (_normalized()) {
    final uri? => !isCleartextAllowed(uri),
    null => false,
  };

  bool get _needsProxy => switch (_normalized()) {
    final uri? => !_proxyActive && isHiddenServiceHost(uri.host),
    null => false,
  };

  void _save() {
    final instance = _buildInstance();
    if (instance == null) return;
    Navigator.of(context).pop(instance);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final test = _test;
    final editing = widget.initial != null;
    return AlertDialog(
      title: Text(
        editing ? l10n.settingsInstanceEditTitle : l10n.settingsInstancesAdd,
      ),
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
              // Rebuild for the banners, and drop a stale test result.
              onChanged: (_) => setState(() => _test = null),
            ),
            if (_insecure) ...[
              const SizedBox(height: 12),
              InsecureHttpWarning(
                key: const Key('instance_insecure_warning'),
                title: l10n.settingsInstanceInsecureTitle,
                text: l10n.commonErrorCleartextRefused,
              ),
            ],
            if (_needsProxy) ...[
              const SizedBox(height: 12),
              _TestMessage(
                key: const Key('instance_needs_proxy'),
                icon: Icons.vpn_lock_outlined,
                color: colors.warning,
                text: l10n.settingsInstanceNeedsProxyNote,
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
              onFieldSubmitted: (_) => _save(),
            ),
            if (test != null) ...[
              const SizedBox(height: 16),
              switch (test) {
                _Testing() => LinearProgressIndicator(
                  semanticsLabel: l10n.settingsInstanceTesting,
                ),
                _TestOk(:final result) => _TestMessage(
                  icon: Icons.check_circle_outline,
                  color: colors.success,
                  text: l10n.settingsInstancesTestResult(
                    result.engineName,
                    result.text,
                    result.latency.inMilliseconds,
                  ),
                ),
                _TestFailed(:final message) => _TestMessage(
                  icon: Icons.error_outline,
                  color: colors.error,
                  text: message,
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
          onPressed: _save,
          child: Text(editing ? l10n.commonSave : l10n.commonAdd),
        ),
      ],
    );
  }
}

/// Test outcome: a coloured icon plus text in the normal on-surface colour
/// (coloured text on the dialog surface fell below 4.5:1), announced as a
/// status message (WCAG 4.1.3).
class _TestMessage extends StatelessWidget {
  const new({
    required this.icon,
    required this.color,
    required this.text,
    super.key,
  });

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
