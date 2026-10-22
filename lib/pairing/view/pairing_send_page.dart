import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/backup/view/backup_section_labels.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/pairing/cubit/pairing_send_cubit.dart';
import 'package:mozhi/pairing/data/pairing_environment.dart';
import 'package:mozhi/pairing/data/pairing_packs.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/view/pairing_environment_of.dart';
import 'package:mozhi/pairing/view/pairing_unavailable.dart';
import 'package:mozhi/pairing/widgets/pairing_labels.dart';
import 'package:mozhi/pairing/widgets/pairing_widgets.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';

/// **Send to another phone** (`/pairing/send`, also `mozhi://pair?code=…`,
/// which only fills in [initialCode]): connects with the other phone's
/// code, shows the numbers to compare, lets the user choose what to send
/// and sends it (docs/pairing.md). [purpose] decides what is selected at
/// first. Android only ([isPairingSupported]); leaving the page stops any
/// transfer.
class PairingSendPage extends StatelessWidget {
  const new({
    super.key,
    this.initialCode,
    this.purpose = PairingSendPurpose.everything,
    this.environment,
  });

  final String? initialCode;
  final PairingSendPurpose purpose;

  /// Replaces the app's network, storage and models (tests).
  final PairingEnvironment? environment;

  @override
  Widget build(BuildContext context) {
    if (environment == null && !isPairingSupported) {
      return PairingUnavailablePage(title: context.l10n.pairingSendTitle);
    }
    return BlocProvider(
      create: (context) => PairingSendCubit(
        environment ?? pairingEnvironmentOf(context),
        initialCode: initialCode,
        purpose: purpose,
      ),
      child: const PairingSendView(),
    );
  }
}

class PairingSendView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pairingSendTitle)),
      body: BlocBuilder<PairingSendCubit, PairingSendState>(
        builder: (context, state) {
          final cubit = context.read<PairingSendCubit>();
          final theme = Theme.of(context);
          void close() => Navigator.of(context).maybePop();
          return switch (state.step) {
            PairingSendStep.enterCode => const _EnterCode(),
            PairingSendStep.connecting => _Busy(label: l10n.pairingConnecting),
            PairingSendStep.confirm => PairingBody(
              children: [
                PairingNumber(sas: state.sas!, title: l10n.pairingConfirmTitle),
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
            ),
            PairingSendStep.choose when state.loading => const Center(
              child: CircularProgressIndicator(),
            ),
            PairingSendStep.choose => const _Choose(),
            PairingSendStep.waiting => _Busy(
              label: l10n.pairingWaitingForAnswer,
              onCancel: close,
            ),
            PairingSendStep.transferring => PairingBody(
              children: [
                PairingProgressView(
                  progress: state.progress,
                  titles: _titles(l10n, state),
                  sending: true,
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
            PairingSendStep.done => PairingBody(
              children: [
                Text(
                  l10n.pairingDoneTitle,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: AppSpacing.md),
                PairingResultsList(
                  results: state.results,
                  titles: _titles(l10n, state),
                ),
                if (state.skipped.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text(
                      l10n.pairingSkipped(state.skipped.length),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
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
            PairingSendStep.failed => EmptyStateView(
              icon: Icons.error_outline,
              tone: EmptyStateTone.error,
              title: l10n.pairingFailedTitle,
              body: pairingFailureMessage(l10n, state.failure!),
              announce: true,
              action: FilledButton.icon(
                key: const Key('pairing_retry'),
                onPressed: cubit.retry,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.commonRetry),
              ),
            ),
          };
        },
      ),
    );
  }

  static Map<String, String> _titles(
    AppLocalizations l10n,
    PairingSendState state,
  ) => {
    PairingBackupItem.id: l10n.pairingItemData,
    for (final outgoing in state.packs)
      outgoing.item.id: pairingItemTitle(
        l10n,
        outgoing.item,
        language: outgoing.language,
      ),
  };
}

/// A spinner with [label], and Cancel when [onCancel] is given.
class _Busy extends StatelessWidget {
  const new({required this.label, this.onCancel});

  final String label;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return PairingBody(
      children: [
        Row(
          spacing: AppSpacing.md,
          children: [
            const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            Expanded(child: Text(label)),
          ],
        ),
        if (onCancel case final onCancel?)
          PairingActions(
            children: [
              OutlinedButton(
                onPressed: onCancel,
                child: Text(context.l10n.commonCancel),
              ),
            ],
          ),
      ],
    );
  }
}

/// How to get the code, the code field, Paste and Connect.
class _EnterCode extends StatefulWidget {
  const new();

  @override
  State<_EnterCode> createState() => _EnterCodeState();
}

class _EnterCodeState extends State<_EnterCode> {
  late final TextEditingController _controller = TextEditingController(
    text: context.read<PairingSendCubit>().state.input,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    // Read only because the user tapped Paste.
    final ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } on Object {
      return;
    }
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    _controller.text = text;
    context.read<PairingSendCubit>().setInput(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<PairingSendCubit>();
    final invalid = context.select<PairingSendCubit, bool>(
      (cubit) => cubit.state.invalidCode,
    );
    return PairingBody(
      children: [
        Text(
          l10n.pairingSendBody,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        TextField(
          key: const Key('pairing_code_field'),
          controller: _controller,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          textCapitalization: TextCapitalization.characters,
          style: theme.textTheme.titleMedium?.copyWith(fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: l10n.pairingCodeField,
            hintText: 'ABCD-EFGH-JKMN-PQRS-TVWX-YZ01',
            errorText: invalid ? l10n.pairingCodeInvalid : null,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: l10n.pairingPaste,
              icon: const Icon(Icons.content_paste),
              onPressed: () => unawaited(_paste()),
            ),
          ),
          onChanged: cubit.setInput,
          onSubmitted: (_) => unawaited(cubit.connect()),
        ),
        PairingActions(
          children: [
            FilledButton(
              key: const Key('pairing_connect'),
              onPressed: () => unawaited(cubit.connect()),
              child: Text(l10n.pairingConnect),
            ),
          ],
        ),
      ],
    );
  }
}

/// What to send: the data (with its sections and the secrets switch) and
/// the offline items.
class _Choose extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final cubit = context.read<PairingSendCubit>();
    final state = context.watch<PairingSendCubit>().state;
    final secondary = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final dataSelected = state.selected.contains(PairingBackupItem.id);
    return PairingBody(
      children: [
        Text(l10n.pairingChooseTitle, style: theme.textTheme.headlineSmall),
        const SizedBox(height: AppSpacing.md),
        if (state.sections.isNotEmpty) ...[
          CheckboxListTile(
            key: const Key('pairing_send_data'),
            value: dataSelected,
            onChanged: (_) => cubit.toggle(PairingBackupItem.id),
            secondary: Icon(pairingItemIcon(PairingItemKind.data)),
            title: Text(l10n.pairingItemData),
            subtitle: Text(l10n.pairingChooseDataBody),
          ),
          if (dataSelected) ...[
            Padding(
              padding: const EdgeInsetsDirectional.only(
                start: 72,
                end: AppSpacing.lg,
              ),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final id in state.sections)
                    FilterChip(
                      avatar: Icon(BackupSectionLabels.icon(id), size: 18),
                      label: Text(BackupSectionLabels.name(l10n, id)),
                      selected: state.chosenSections.contains(id),
                      onSelected: (_) => cubit.toggleSection(id),
                    ),
                ],
              ),
            ),
            SwitchListTile(
              key: const Key('pairing_send_secrets'),
              contentPadding: const EdgeInsetsDirectional.only(
                start: 72,
                end: AppSpacing.lg,
              ),
              value: state.includeSecrets,
              onChanged: (include) => cubit.setIncludeSecrets(include: include),
              title: Text(l10n.pairingIncludeSecrets),
              subtitle: state.includeSecrets
                  ? Text(
                      l10n.pairingIncludeSecretsWarning,
                      style: TextStyle(color: theme.colorScheme.error),
                    )
                  : null,
            ),
          ],
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.xs,
          ),
          child: Semantics(
            header: true,
            child: Text(
              l10n.pairingChoosePacks,
              style: theme.textTheme.titleMedium,
            ),
          ),
        ),
        if (state.packs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(l10n.pairingNoPacks, style: secondary),
          ),
        for (final outgoing in state.packs)
          CheckboxListTile(
            key: ValueKey('pairing_send_${outgoing.item.id}'),
            value: state.selected.contains(outgoing.item.id),
            onChanged: (_) => cubit.toggle(outgoing.item.id),
            secondary: Icon(pairingItemIcon(outgoing.item.kind)),
            title: Text(
              pairingItemTitle(
                l10n,
                outgoing.item,
                language: outgoing.language,
              ),
            ),
            subtitle: Text(formatStoredSize(l10n, outgoing.item.size)),
          ),
        PairingActions(
          children: [
            FilledButton(
              key: const Key('pairing_send'),
              onPressed: state.canSend ? () => unawaited(cubit.send()) : null,
              child: Text(l10n.pairingSend),
            ),
          ],
        ),
      ],
    );
  }
}
