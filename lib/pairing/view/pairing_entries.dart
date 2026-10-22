import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/pairing/pairing_routes.dart';
import 'package:mozhi/pairing/view/pairing_unavailable.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// The **Phone to phone** section of Settings › Backup & sync: an
/// introduction, **Receive on this phone** and **Send to another phone**.
/// Nothing in the web app ([isPairingSupported]).
class PairingSettingsSection extends StatelessWidget {
  const new({super.key, this.divider = true});

  /// Whether a hairline closes the section.
  final bool divider;

  @override
  Widget build(BuildContext context) {
    if (!isPairingSupported) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return SettingsSection(
      title: l10n.pairingSectionTitle,
      divider: divider,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Text(
            l10n.pairingSectionIntro,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ListTile(
          key: const Key('pairing_receive'),
          leading: const SettingsIcon(Icons.qr_code_2),
          title: Text(l10n.pairingReceiveAction),
          subtitle: Text(l10n.pairingReceiveSubtitle),
          onTap: () => unawaited(context.push<void>(PairingRoutes.receive)),
        ),
        ListTile(
          key: const Key('pairing_send'),
          leading: const SettingsIcon(Icons.send_to_mobile_outlined),
          title: Text(l10n.pairingSendAction),
          subtitle: Text(l10n.pairingSendSubtitle),
          onTap: () => unawaited(context.push<void>(PairingRoutes.send)),
        ),
      ],
    );
  }
}

/// `/pairing`: the [PairingSettingsSection] on a page of its own.
class PairingPage extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (!isPairingSupported) {
      return PairingUnavailablePage(title: l10n.pairingSectionTitle);
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pairingSectionTitle)),
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: centeredPadding(constraints.maxWidth)
              .subtract(const EdgeInsets.symmetric(horizontal: 16))
              .resolve(TextDirection.ltr),
          children: const [PairingSettingsSection(divider: false)],
        ),
      ),
    );
  }
}

/// **Share language packs** on the Offline languages screen: opens
/// **Send to another phone** with the language packs selected. Nothing in
/// the web app ([isPairingSupported]).
class SharePacksEntry extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isPairingSupported) return const SizedBox.shrink();
    final l10n = context.l10n;
    return ListTile(
      key: const Key('offline_share_packs'),
      leading: const Icon(Icons.send_to_mobile_outlined),
      title: Text(l10n.pairingSharePacksAction),
      subtitle: Text(
        l10n.pairingSharePacksSubtitle,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => unawaited(
        context.push<void>(PairingRoutes.sendLocation(packs: true)),
      ),
    );
  }
}
