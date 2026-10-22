import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';

/// Whether phone to phone works here: in the Android app only (a browser
/// cannot listen on the network).
bool get isPairingSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// What the pairing pages show where [isPairingSupported] is false (the
/// web app, desktop builds).
class PairingUnavailablePage extends StatelessWidget {
  const new({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: EmptyStateView(
        icon: Icons.phonelink_off,
        title: context.l10n.pairingUnavailable,
      ),
    );
  }
}
