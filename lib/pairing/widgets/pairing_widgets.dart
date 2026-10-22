import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/pairing/data/pairing_session.dart';
import 'package:mozhi/pairing/models/pairing_item.dart';
import 'package:mozhi/pairing/widgets/pairing_labels.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart'
    show formatStoredSize;
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// The six digits both phones show ("123 456"), read digit by digit by
/// screen readers, under [title].
class PairingNumber extends StatelessWidget {
  const new({required this.sas, required this.title, super.key});

  final String sas;
  final String title;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final grouped = sas.length == 6
        ? '${sas.substring(0, 3)} ${sas.substring(3)}'
        : sas;
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          spacing: AppSpacing.sm,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            Semantics(
              label: l10n.pairingSasSemantics(sas.split('').join(' ')),
              excludeSemantics: true,
              child: Text(
                grouped,
                key: const Key('pairing_sas'),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  letterSpacing: 4,
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How far a transfer is: a bar, what is going across ([titles] by item
/// id) and the bytes.
class PairingProgressView extends StatelessWidget {
  const new({
    required this.progress,
    required this.titles,
    required this.sending,
    super.key,
  });

  final PairingProgress? progress;
  final Map<String, String> titles;

  /// Whether this phone sends (else it receives).
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final progress = this.progress;
    final title = titles[progress?.itemId] ?? '';
    final label = switch (progress) {
      null => '',
      PairingProgress(installing: true) => l10n.pairingInstalling(title),
      _ when sending => l10n.pairingSending(title),
      _ => l10n.pairingReceiving(title),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AppSpacing.md,
      children: [
        Text(label, style: theme.textTheme.titleMedium),
        LinearProgressIndicator(
          value: progress?.fraction,
          semanticsLabel: label,
        ),
        if (progress != null)
          Text(
            l10n.pairingProgressBytes(
              formatStoredSize(l10n, progress.bytes),
              formatStoredSize(l10n, progress.totalBytes),
            ),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        Text(
          l10n.pairingKeepOpen,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// What became of each item ([titles] by item id).
class PairingResultsList extends StatelessWidget {
  const new({required this.results, required this.titles, super.key});

  final List<PairingItemResult> results;
  final Map<String, String> titles;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final result in results)
          ListTile(
            leading: result.outcome == PairingItemOutcome.installed
                ? Icon(Icons.check_circle_outline, color: colors.primary)
                : Icon(Icons.error_outline, color: colors.error),
            title: Text(titles[result.id] ?? result.id),
            subtitle: Text(
              pairingOutcomeText(
                l10n,
                result.outcome,
                isData: result.id.startsWith('${PairingItemKind.data.name}:'),
              ),
            ),
          ),
      ],
    );
  }
}

/// A page body that keeps its content centred and at most 720 dp wide,
/// scrolling when it does not fit.
class PairingBody extends StatelessWidget {
  const new({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: centeredPadding(constraints.maxWidth, top: AppSpacing.lg),
        children: children,
      ),
    );
  }
}

/// The buttons at the end of a step, side by side (wrapping when narrow).
class PairingActions extends StatelessWidget {
  const new({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: children,
      ),
    );
  }
}
