import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/practice/data/practice_repository.dart';
import 'package:mozhi/practice/practice_routes.dart';

/// The [PracticeRepository] above [context], or null where the app
/// provides none (practice is then not offered).
PracticeRepository? maybePracticeRepository(BuildContext context) {
  try {
    return context.read<PracticeRepository>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// The label of the Practice entry of a menu (the translate screen's More
/// tools): "Practice" with a badge counting the cards due for review
/// ([PracticeRepository.dueCount], recounted when it shows). No badge
/// without a [PracticeRepository] or with nothing due; new cards are not
/// counted, so it never nags.
class PracticeMenuLabel extends StatefulWidget {
  const new({this.repository, super.key});

  /// The practice to count (default: the one above the label). A menu
  /// passes its own: its items are built in an overlay, away from the
  /// providers around the menu button.
  final PracticeRepository? repository;

  @override
  State<PracticeMenuLabel> createState() => _PracticeMenuLabelState();
}

class _PracticeMenuLabelState extends State<PracticeMenuLabel> {
  PracticeRepository? _repository;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? maybePracticeRepository(context);
    unawaited(_repository?.refreshDueCount());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = Text(l10n.practiceTitle);
    final repository = _repository;
    if (repository == null) return label;
    return ValueListenableBuilder<int>(
      valueListenable: repository.dueCount,
      builder: (context, due, _) {
        if (due <= 0) return label;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: label),
            const SizedBox(width: 8),
            Semantics(
              label: l10n.practiceDueBadge(due),
              excludeSemantics: true,
              child: Badge.count(
                key: const Key('practice_due_badge'),
                count: due,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A collection's Practice button (the phrasebook): opens practice of
/// that collection alone ([PracticeRoutes.locationFor]).
class PracticeCollectionButton extends StatelessWidget {
  const new({required this.collectionId, this.compact = false, super.key});

  final String collectionId;

  /// An icon button (app bars) instead of a labelled one.
  final bool compact;

  void _open(BuildContext context) => unawaited(
    context.push<void>(PracticeRoutes.locationFor(collectionId: collectionId)),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (compact) {
      return IconButton(
        key: const Key('practice_collection'),
        tooltip: l10n.practiceCollectionTooltip,
        icon: const Icon(Icons.school_outlined),
        onPressed: () => _open(context),
      );
    }
    return OutlinedButton.icon(
      key: const Key('practice_collection'),
      onPressed: () => _open(context),
      icon: const Icon(Icons.school_outlined),
      label: Text(l10n.practiceTitle),
    );
  }
}
