import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/l10n/l10n.dart';

final _hostPort = RegExp(r'^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+):([0-9]{1,5})$');
final _hostLabel = RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$');

/// Whether [value] (trimmed) is an HTTP proxy address `host:port`: a host
/// name, an IPv4 address or an IPv6 address in brackets (`[::1]:8118`),
/// and a port from 1 to 65535. No scheme, user or path.
bool isValidHttpProxy(String value) {
  final match = _hostPort.firstMatch(value.trim());
  if (match == null) return false;
  final port = int.parse(match[2]!);
  if (port < 1 || port > 65535) return false;
  final host = match[1]!;
  if (host.startsWith('[')) {
    try {
      Uri.parseIPv6Address(host.substring(1, host.length - 1));
      return true;
    } on FormatException {
      return false;
    }
  }
  return host.length <= 253 && host.split('.').every(_hostLabel.hasMatch);
}

/// What [HttpProxyDialog] pops: the proxy to use, or [remove] to connect
/// directly again.
@immutable
class HttpProxyChoice {
  const new(this.proxy);

  /// Connect directly (no proxy).
  static const remove = HttpProxyChoice(null);

  /// `host:port`, or null for no proxy.
  final String? proxy;
}

/// Edits the HTTP proxy (`host:port`): explains that it applies after a
/// restart and suggests Orbot's HTTP proxy for Tor. Pops an
/// [HttpProxyChoice], or null when cancelled.
class HttpProxyDialog extends StatefulWidget {
  const new({this.initialValue, super.key});

  /// The current proxy, if any.
  final String? initialValue;

  @override
  State<HttpProxyDialog> createState() => _HttpProxyDialogState();
}

class _HttpProxyDialogState extends State<HttpProxyDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      Navigator.of(context).pop(HttpProxyChoice.remove);
      return;
    }
    if (!isValidHttpProxy(value)) {
      setState(() => _error = context.l10n.settingsHttpProxyInvalid);
      return;
    }
    Navigator.of(context).pop(HttpProxyChoice(value));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final secondary = theme.colorScheme.onSurfaceVariant;
    return AlertDialog(
      icon: const Icon(Icons.vpn_lock_outlined),
      title: Text(l10n.settingsHttpProxy),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.settingsHttpProxyHelp),
          const SizedBox(height: 16),
          TextField(
            key: const Key('settings_http_proxy_field'),
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: imeLearningAllowed(context),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
            decoration: InputDecoration(
              labelText: l10n.settingsHttpProxyLabel,
              hintText: l10n.settingsHttpProxyHint,
              errorText: _error,
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.restart_alt, size: 18, color: secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.settingsHttpProxyRestart,
                  style: theme.textTheme.bodySmall?.copyWith(color: secondary),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        if (widget.initialValue != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(HttpProxyChoice.remove),
            child: Text(l10n.settingsHttpProxyRemove),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
      ],
    );
  }
}
