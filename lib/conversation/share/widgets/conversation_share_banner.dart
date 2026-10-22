import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/conversation/share/cubit/conversation_share_cubit.dart';
import 'package:mozhi/conversation/share/view/conversation_share_page.dart';
import 'package:mozhi/conversation/share/widgets/conversation_share_guard.dart';
import 'package:mozhi/l10n/l10n.dart';

/// While the conversation is shared on the local network: a slim bar
/// saying so with the number of guests, **Show code** (the sharing page)
/// and Stop. Nothing otherwise (or without a [ConversationShareCubit]).
class ConversationShareBanner extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    if (maybeConversationShare(context) == null) return const SizedBox.shrink();
    final (:live, :guests) = context
        .select<ConversationShareCubit, ({bool live, int guests})>(
          (cubit) =>
              (live: cubit.state.isLive, guests: cubit.state.guests.length),
        );
    if (!live) return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = l10n.conversationShareGuests(guests);
    final text = '${l10n.conversationShareBanner} · $count';
    return Material(
      key: const Key('conversation_share_banner'),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 4, 0),
        child: Row(
          children: [
            Icon(
              Icons.wifi_tethering,
              size: 20,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            ),
            TextButton(
              key: const Key('conversation_share_banner_show'),
              style: TextButton.styleFrom(
                foregroundColor: scheme.onSecondaryContainer,
              ),
              onPressed: () => unawaited(openConversationShare(context)),
              child: Text(l10n.conversationShareShowCode),
            ),
            IconButton(
              key: const Key('conversation_share_banner_stop'),
              tooltip: l10n.conversationShareStop,
              color: scheme.onSecondaryContainer,
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () =>
                  unawaited(context.read<ConversationShareCubit>().stop()),
            ),
          ],
        ),
      ),
    );
  }
}
