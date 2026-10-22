import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/backup/data/backup_registry.dart';
import 'package:mozhi/backup/view/backup_section_labels.dart';
import 'package:mozhi/core/qr/qr_code_view.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/pairing/cubit/pairing_receive_cubit.dart';
import 'package:mozhi/pairing/data/pairing_environment.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/view/pairing_environment_of.dart';
import 'package:mozhi/pairing/view/pairing_unavailable.dart';
import 'package:mozhi/pairing/widgets/pairing_labels.dart';
import 'package:mozhi/pairing/widgets/pairing_widgets.dart';
import 'package:mozhi/platform/clipboard_service.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';

/// **Receive on this phone** (`/pairing/receive`): shows a code for the
/// other phone, the numbers to compare, its offer, and the transfer
/// (docs/pairing.md). Android only ([isPairingSupported]); leaving the
/// page stops listening and any transfer.
class PairingReceivePage extends StatelessWidget {
  const new({super.key, this.environment});

  /// Replaces the app's network, storage and models (tests).
  final PairingEnvironment? environment;

  @override
  Widget build(BuildContext context) {
    if (environment == null && !isPairingSupported) {
      return PairingUnavailablePage(title: context.l10n.pairingReceiveTitle);
    }
    return BlocProvider(
      create: (context) {
        final cubit = PairingReceiveCubit(
          environment ?? pairingEnvironmentOf(context),
        );
        unawaited(cubit.start());
        return cubit;
      },
      child: const PairingReceiveView(),
    );
  }
}

class PairingReceiveView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pairingReceiveTitle)),
      body: BlocBuilder<PairingReceiveCubit, PairingReceiveState>(
        builder: (context, state) {
          final cubit = context.read<PairingReceiveCubit>();
          void close() => Navigator.of(context).maybePop();
          return switch (state.step) {
            PairingReceiveStep.starting => const Center(
              child: CircularProgressIndicator(),
            ),
            PairingReceiveStep.noNetwork => EmptyStateView(
              icon: Icons.wifi_off,
              title: l10n.pairingNoNetworkTitle,
              body: l10n.pairingNoNetworkBody,
              announce: true,
              action: FilledButton.icon(
                onPressed: () => unawaited(cubit.start()),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.commonRetry),
              ),
            ),
            PairingReceiveStep.waiting => _Waiting(state: state),
            PairingReceiveStep.expired => EmptyStateView(
              icon: Icons.timer_off_outlined,
              title: l10n.pairingExpiredTitle,
              body: l10n.pairingExpiredBody,
              announce: true,
              action: FilledButton.icon(
                key: const Key('pairing_new_code'),
                onPressed: () => unawaited(cubit.start()),
                icon: const Icon(Icons.qr_code_2),
                label: Text(l10n.pairingNewCode),
              ),
            ),
            PairingReceiveStep.connected => PairingBody(
              children: [
                _Numbers(state: state),
                const SizedBox(height: AppSpacing.xl),
                Row(
                  spacing: AppSpacing.md,
                  children: [
                    const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    Expanded(child: Text(l10n.pairingWaitingForOffer)),
                  ],
                ),
              ],
            ),
            PairingReceiveStep.offer => _Offer(state: state),
            PairingReceiveStep.transferring => PairingBody(
              children: [
                PairingProgressView(
                  progress: state.progress,
                  titles: _titles(l10n, state),
                  sending: false,
                ),
                PairingActions(
                  children: [
                    OutlinedButton(
                      onPressed: close,
                      child: Text(l10n.commonCancel),
                    ),
                  ],
                ),
              ],
            ),
            PairingReceiveStep.done => PairingBody(
              children: [
                Text(
                  l10n.pairingDoneTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: AppSpacing.md),
                PairingResultsList(
                  results: state.results,
                  titles: _titles(l10n, state),
                ),
                PairingActions(
                  children: [
                    FilledButton(
                      onPressed: close,
                      child: Text(l10n.commonClose),
                    ),
                  ],
                ),
              ],
            ),
            PairingReceiveStep.declined => EmptyStateView(
              icon: Icons.do_not_disturb_on_outlined,
              title: l10n.pairingDeclinedTitle,
              body: l10n.pairingDeclinedBody,
              action: FilledButton(
                onPressed: close,
                child: Text(l10n.commonClose),
              ),
            ),
            PairingReceiveStep.failed => EmptyStateView(
              icon: Icons.error_outline,
              tone: EmptyStateTone.error,
              title: l10n.pairingFailedTitle,
              body: pairingFailureMessage(l10n, state.failure!),
              announce: true,
              action: FilledButton.icon(
                key: const Key('pairing_new_code'),
                onPressed: () => unawaited(cubit.start()),
                icon: const Icon(Icons.qr_code_2),
                label: Text(l10n.pairingNewCode),
              ),
            ),
          };
        },
      ),
    );
  }

  static Map<String, String> _titles(
    AppLocalizations l10n,
    PairingReceiveState state,
  ) => {
    for (final offered in state.offered)
      offered.item.id: pairingItemTitle(
        l10n,
        offered.item,
        language: offered.plan.language,
      ),
  };
}

/// The code (QR and text), when it expires, and the network.
class _Waiting extends StatelessWidget {
  const new({required this.state});

  final PairingReceiveState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<PairingReceiveCubit>();
    final code = state.code!;
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return PairingBody(
      children: [
        Text(l10n.pairingReceiveScan, style: theme.textTheme.headlineSmall),
        const SizedBox(height: AppSpacing.sm),
        Text(l10n.pairingReceiveScanBody, style: secondary),
        const SizedBox(height: AppSpacing.xl),
        Center(
          child: QrCodeView(
            data: code.link,
            semanticLabel: l10n.pairingQrLabel,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text(l10n.pairingReceiveOrType, style: theme.textTheme.titleSmall),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                code.text,
                key: const Key('pairing_code_text'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 1,
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.pairingCopyCode,
              icon: const Icon(Icons.copy),
              onPressed: () => unawaited(_copy(context, code.text)),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        _Countdown(expiresAt: state.expiresAt!),
        if (state.addresses.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.md),
            child: DropdownMenu<String>(
              key: const Key('pairing_network'),
              label: Text(l10n.pairingChooseNetwork),
              initialSelection: state.address,
              dropdownMenuEntries: [
                for (final address in state.addresses)
                  DropdownMenuEntry(value: address, label: address),
              ],
              onSelected: (address) {
                if (address != null && address != state.address) {
                  unawaited(cubit.useAddress(address));
                }
              },
            ),
          )
        else if (state.address case final address?)
          Text(l10n.pairingOnNetwork(address), style: secondary),
        PairingActions(
          children: [
            TextButton.icon(
              key: const Key('pairing_new_code'),
              onPressed: () => unawaited(cubit.start(address: state.address)),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.pairingNewCode),
            ),
          ],
        ),
      ],
    );
  }

  static Future<void> _copy(BuildContext context, String text) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      await copyText(text);
    } on Object {
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text(l10n.commonCopied)));
  }
}

/// "Expires in 4:59", counting down.
class _Countdown extends StatefulWidget {
  const new({required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.expiresAt.difference(DateTime.now());
    final seconds = left.isNegative ? 0 : left.inSeconds;
    final time =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    final theme = Theme.of(context);
    return Text(
      context.l10n.pairingExpiresIn(time),
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// The numbers to compare: with the question and the answers until the
/// user confirms they match (nothing can be accepted before), then for
/// the person at the other phone.
class _Numbers extends StatelessWidget {
  const new({required this.state});

  final PairingReceiveState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sas = state.sas!;
    if (state.numbersConfirmed) {
      return PairingNumber(sas: sas, title: l10n.pairingCheckNumber);
    }
    final theme = Theme.of(context);
    final cubit = context.read<PairingReceiveCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PairingNumber(sas: sas, title: l10n.pairingConfirmTitle),
        const SizedBox(height: AppSpacing.md),
        Text(
          l10n.pairingConfirmBody,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        PairingActions(
          children: [
            OutlinedButton(
              key: const Key('pairing_mismatch'),
              onPressed: () => unawaited(cubit.confirm(match: false)),
              child: Text(l10n.pairingConfirmMismatch),
            ),
            FilledButton(
              key: const Key('pairing_match'),
              onPressed: () => unawaited(cubit.confirm(match: true)),
              child: Text(l10n.pairingConfirmMatch),
            ),
          ],
        ),
      ],
    );
  }
}

/// The numbers to compare and the other phone's offer.
class _Offer extends StatelessWidget {
  const new({required this.state});

  final PairingReceiveState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<PairingReceiveCubit>();
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final data = state.dataItem;
    return PairingBody(
      children: [
        _Numbers(state: state),
        const SizedBox(height: AppSpacing.xl),
        Text(l10n.pairingOfferTitle, style: theme.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        for (final offered in state.offered) _OfferedTile(offered: offered),
        if (data != null && state.selected.contains(data.item.id)) ...[
          const SizedBox(height: AppSpacing.md),
          SegmentedButton<BackupRestoreMode>(
            segments: [
              ButtonSegment(
                value: BackupRestoreMode.merge,
                label: Text(l10n.pairingModeMerge),
              ),
              ButtonSegment(
                value: BackupRestoreMode.replace,
                label: Text(l10n.pairingModeReplace),
              ),
            ],
            selected: {state.mode},
            onSelectionChanged: (modes) => cubit.setMode(modes.single),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(l10n.pairingModesBody, style: secondary),
        ],
        if (!state.numbersConfirmed) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            l10n.pairingAcceptAfterNumbers,
            key: const Key('pairing_accept_hint'),
            style: secondary,
          ),
        ],
        PairingActions(
          children: [
            OutlinedButton(
              key: const Key('pairing_decline'),
              onPressed: () => unawaited(cubit.decline()),
              child: Text(l10n.pairingDecline),
            ),
            FilledButton(
              key: const Key('pairing_accept'),
              // Only once the user said both phones show the same number.
              onPressed: state.numbersConfirmed
                  ? () => unawaited(cubit.accept())
                  : null,
              child: Text(l10n.pairingAccept),
            ),
          ],
        ),
      ],
    );
  }
}

class _OfferedTile extends StatelessWidget {
  const new({required this.offered});

  final PairingOfferedItem offered;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = context.watch<PairingReceiveCubit>().state;
    final item = offered.item;
    final available = offered.plan.status == PairingItemStatus.available;
    final status = switch (offered.plan.status) {
      PairingItemStatus.available => formatStoredSize(l10n, offered.plan.size),
      PairingItemStatus.installed => l10n.pairingItemInstalled,
      PairingItemStatus.incompatible => l10n.pairingItemIncompatible,
    };
    final sections = [
      for (final id in item.sections) BackupSectionLabels.name(l10n, id),
    ].join(', ');
    return CheckboxListTile(
      key: ValueKey('pairing_item_${item.id}'),
      value: available && state.selected.contains(item.id),
      onChanged: available
          ? (_) => context.read<PairingReceiveCubit>().toggle(item.id)
          : null,
      secondary: Icon(pairingItemIcon(item.kind)),
      title: Text(
        pairingItemTitle(l10n, item, language: offered.plan.language),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sections.isNotEmpty) Text(sections),
          Text(status),
          if (item.secrets)
            Text(
              l10n.pairingItemSecrets,
              style: TextStyle(color: theme.colorScheme.error),
            ),
        ],
      ),
    );
  }
}
