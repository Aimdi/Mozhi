import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';

/// Asks for confirmation (with a "keep favorites" option) and clears the
/// history through [HistoryCubit]. Shows a snackbar when done.
Future<void> confirmClearHistory(BuildContext context) async {
  final cubit = context.read<HistoryCubit>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final clearedMessage = context.l10n.historyCleared;
  final keepFavorites = await showDialog<bool>(
    context: context,
    builder: (_) => const ClearHistoryDialog(),
  );
  if (keepFavorites == null) return;
  await cubit.clear(keepFavorites: keepFavorites);
  messenger?.showSnackBar(SnackBar(content: Text(clearedMessage)));
}

/// Pops with the "keep favorites" choice when confirmed, null when
/// cancelled.
class ClearHistoryDialog extends StatefulWidget {
  const new({super.key});

  @override
  State<ClearHistoryDialog> createState() => _ClearHistoryDialogState();
}

class _ClearHistoryDialogState extends State<ClearHistoryDialog> {
  bool _keepFavorites = true;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: const Icon(Icons.delete_sweep_outlined),
      title: Text(l10n.historyClearTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.historyClearBody),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _keepFavorites,
            title: Text(l10n.historyClearKeepFavorites),
            onChanged: (value) =>
                setState(() => _keepFavorites = value ?? false),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: colors.error),
          onPressed: () => Navigator.of(context).pop(_keepFavorites),
          child: Text(l10n.historyClearAction),
        ),
      ],
    );
  }
}
