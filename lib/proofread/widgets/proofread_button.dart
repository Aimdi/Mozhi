import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/proofread/cubit/proofread_cubit.dart';

/// The "Proofread" action with a loading state: a bold pill (the theme's
/// inverse filled button).
class ProofreadButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (canProofread, isLoading) = context
        .select<ProofreadCubit, (bool, bool)>(
          (cubit) => (cubit.state.canProofread, cubit.state.isLoading),
        );
    return FilledButton.icon(
      key: const Key('proofread_button'),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        textStyle: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w700),
        shape: const StadiumBorder(),
      ),
      onPressed: canProofread ? context.read<ProofreadCubit>().proofread : null,
      icon: isLoading
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.spellcheck),
      label: Text(isLoading ? l10n.proofreadActionBusy : l10n.proofreadAction),
    );
  }
}
