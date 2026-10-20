import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/haptics.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:mozhi/dictionary/cubit/dictionary_cubit.dart';
import 'package:mozhi/history/cubit/history_cubit.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:translation_repository/translation_repository.dart';

/// The heart beside "New look-up", like History's: adds the shown entry's
/// look-up to the favourites or takes it out
/// ([DictionaryCubit.toggleFavorite]). Filled in the favourite colour while
/// the history has the look-up as a favourite (`HistoryState.lookUpOf`).
///
/// The label says the state ("Add to favorites" / "Remove from
/// favorites"), so the icon swaps instead of using toggle semantics, as on
/// History's entries. Shown (disabled) while the entry loads and enabled
/// once there is one; nothing for an error, an empty entry or without a
/// [HistoryCubit] above.
class DictionaryFavoriteButton extends StatelessWidget {
  const new({super.key});

  /// Width and height of the round button (the "New look-up" height).
  static const double size = 52;

  @override
  Widget build(BuildContext context) {
    if (context.read<HistoryCubit?>() == null) return const SizedBox.shrink();
    final (status, lookedUp, source, target, empty) = context
        .select<DictionaryCubit, _Shown>((cubit) {
          final state = cubit.state;
          return (
            state.status,
            state.lookedUp,
            state.source,
            state.target,
            state.isEmptyEntry,
          );
        });
    final ready = status == DictionaryStatus.success && !empty;
    if (!ready && status != DictionaryStatus.loading) {
      return const SizedBox.shrink();
    }
    final favorite = context.select<HistoryCubit, bool>(
      (cubit) =>
          cubit.state
              .lookUpOf(lookedUp, source: source, target: target)
              ?.isFavorite ??
          false,
    );
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final palette = AppPalette.of(context);
    // The gap to "New look-up" goes with the button.
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 12),
      child: IconButton.outlined(
        key: const Key('dictionary_favorite'),
        tooltip: favorite ? l10n.historyUnfavorite : l10n.historyFavorite,
        style: IconButton.styleFrom(
          fixedSize: const Size.square(size),
          side: BorderSide(color: colors.outlineVariant),
          foregroundColor: favorite ? palette.like : colors.onSurface,
        ),
        icon: Icon(
          favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        ),
        onPressed: ready
            ? () {
                Haptics.light(context);
                unawaited(context.read<DictionaryCubit>().toggleFavorite());
              }
            : null,
      ),
    );
  }
}

typedef _Shown = (DictionaryStatus, String, Language, Language, bool);
