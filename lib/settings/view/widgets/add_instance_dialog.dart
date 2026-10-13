import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
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

/// Asks for an instance URL (+ optional label) and returns the new
/// [MozhiInstance], or null when cancelled. [existingUrls] are rejected as
/// duplicates.
class AddInstanceDialog extends StatefulWidget {
  const AddInstanceDialog({required this.existingUrls, super.key});

  final List<String> existingUrls;

  @override
  State<AddInstanceDialog> createState() => _AddInstanceDialogState();
}

sealed class _TestState {
  const _TestState();
}

class _Testing extends _TestState {
  const _Testing();
}

class _TestOk extends _TestState {
  const _TestOk(this.latency);
  final Duration latency;
}

class _TestFailed extends _TestState {
  const _TestFailed(this.message);
  final String message;
}

class _AddInstanceDialogState extends State<AddInstanceDialog> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _labelController = TextEditingController();
  _TestState? _test;

  @override
  void dispose() {
    _urlController.dispose();
    _labelController.dispose();
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
    final uri = _normalized();
    if (uri == null) return l10n.settingsInstanceUrlInvalid;
    if (widget.existingUrls.contains(uri.toString())) {
      return l10n.settingsInstanceUrlDuplicate;
    }
    return null;
  }

  MozhiInstance? _buildInstance() {
    if (!(_formKey.currentState?.validate() ?? false)) return null;
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

  void _save() {
    final instance = _buildInstance();
    if (instance != null) Navigator.of(context).pop(instance);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
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
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.settingsInstanceUrl,
                hintText: l10n.settingsInstanceUrlHint,
                prefixIcon: const Icon(Icons.link),
                errorMaxLines: 3,
              ),
              validator: _validateUrl,
              onChanged: (_) {
                if (_test != null) setState(() => _test = null);
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _labelController,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: l10n.settingsInstanceLabel,
                prefixIcon: const Icon(Icons.label_outline),
              ),
              onFieldSubmitted: (_) => _save(),
            ),
            if (test != null) ...[
              const SizedBox(height: 16),
              switch (test) {
                _Testing() => const LinearProgressIndicator(),
                _TestOk(:final latency) => Text(
                  l10n.settingsInstanceTestOk(latency.inMilliseconds),
                  style: textTheme.bodyMedium?.copyWith(color: colors.success),
                ),
                _TestFailed(:final message) => Text(
                  l10n.settingsInstanceTestFailed(message),
                  style: textTheme.bodyMedium?.copyWith(color: colors.error),
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
        FilledButton(onPressed: _save, child: Text(l10n.commonAdd)),
      ],
    );
  }
}
