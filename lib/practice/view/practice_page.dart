import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/practice/cubit/practice_cubit.dart';
import 'package:mozhi/practice/cubit/practice_speech_cubit.dart';
import 'package:mozhi/practice/data/practice_repository.dart';
import 'package:mozhi/practice/data/practice_speech.dart';
import 'package:mozhi/practice/practice_routes.dart';
import 'package:mozhi/practice/widgets/anki_export_sheet.dart';
import 'package:mozhi/practice/widgets/practice_overview.dart';
import 'package:mozhi/practice/widgets/practice_session.dart';
import 'package:mozhi/practice/widgets/practice_summary.dart';
import 'package:mozhi/settings/view/widgets/empty_state_view.dart';
import 'package:mozhi/voice/offline/offline_speech.dart';

/// Practice (`/practice`, [location]): short review sessions of the
/// phrasebook's phrases as flashcards, scheduled by FSRS, with listening,
/// speaking (on the device) and typing practice. `?collection=<id>`
/// ([collectionParameter]) practises one collection.
///
/// Requires a [PracticeRepository] above it; speaking practice uses the
/// [OfflineSpeech] when provided (Whisper on this device), or
/// [recognizer] (tests).
class PracticePage extends StatelessWidget {
  const new({this.collectionId, this.recognizer, super.key});

  static const String location = PracticeRoutes.location;
  static const String collectionParameter = PracticeRoutes.collectionParameter;

  /// The location practising [collectionId] (all practised collections
  /// without one).
  static String locationFor({String? collectionId}) =>
      PracticeRoutes.locationFor(collectionId: collectionId);

  final String? collectionId;
  final PracticeRecognizer? recognizer;

  static T? _maybe<T>(BuildContext context) {
    try {
      return context.read<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Which side of a phrase is the user's (read once, for the page).
    final appLanguage = Localizations.localeOf(context).languageCode;
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) {
            final cubit = PracticeCubit(
              repository: context.read<PracticeRepository>(),
              appLanguage: appLanguage,
              onlyCollection: collectionId,
            );
            unawaited(cubit.load());
            return cubit;
          },
        ),
        BlocProvider(
          create: (context) {
            final cubit = PracticeSpeechCubit(
              recognizer:
                  recognizer ??
                  WhisperPracticeRecognizer(
                    speech: _maybe<OfflineSpeech>(context),
                  ),
            );
            unawaited(cubit.load());
            return cubit;
          },
        ),
      ],
      child: const PracticeView(),
    );
  }
}

/// The layout of the [PracticeCubit] above it (see [PracticePage]): the
/// overview, a session (with Undo and End session in the app bar) or its
/// summary.
class PracticeView extends StatelessWidget {
  const new({super.key});

  Future<void> _export(BuildContext context) async {
    final cubit = context.read<PracticeCubit>();
    final deck = cubit.state.deck;
    if (deck == null) return;
    await showAnkiExport(
      context,
      phrasebook: context.read<PracticeRepository>().phrasebook,
      collections: deck.collections,
      appLanguage: cubit.appLanguage,
      initialCollection: cubit.onlyCollection,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = context.select<PracticeCubit, PracticeStatus>(
      (cubit) => cubit.state.status,
    );
    final canUndo = context.select<PracticeCubit, bool>(
      (cubit) => cubit.state.canUndo,
    );
    final reviewing = status == PracticeStatus.reviewing;
    final cubit = context.read<PracticeCubit>();
    final body = switch (status) {
      PracticeStatus.loading => const Center(
        child: CircularProgressIndicator(),
      ),
      PracticeStatus.ready => PracticeOverview(
        onExport: () => unawaited(_export(context)),
      ),
      PracticeStatus.reviewing => const PracticeSession(),
      PracticeStatus.finished => const PracticeSummary(),
      PracticeStatus.unreadable => EmptyStateView(
        icon: Icons.lock_outline,
        tone: EmptyStateTone.error,
        title: l10n.practiceUnreadableTitle,
        body: l10n.practiceUnreadableBody,
        announce: true,
        action: FilledButton(
          key: const Key('practice_start_over'),
          onPressed: () => unawaited(cubit.startOver()),
          child: Text(l10n.practiceStartOver),
        ),
      ),
      PracticeStatus.failure => EmptyStateView(
        icon: Icons.error_outline,
        tone: EmptyStateTone.error,
        title: l10n.practiceLoadFailed,
        announce: true,
        action: FilledButton(
          key: const Key('practice_retry'),
          onPressed: () => unawaited(cubit.load()),
          child: Text(l10n.commonRetry),
        ),
      ),
    };
    return BlocListener<PracticeCubit, PracticeState>(
      listenWhen: (previous, current) =>
          current.saveFailed && !previous.saveFailed,
      listener: (context, state) => ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l10n.practiceSaveFailed))),
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.practiceTitle),
          actions: [
            if (reviewing) ...[
              IconButton(
                key: const Key('practice_undo'),
                tooltip: l10n.practiceUndoRating,
                icon: const Icon(Icons.undo),
                onPressed: canUndo ? () => unawaited(cubit.undo()) : null,
              ),
              IconButton(
                key: const Key('practice_end'),
                tooltip: l10n.practiceEndSession,
                icon: const Icon(Icons.stop_circle_outlined),
                onPressed: cubit.finish,
              ),
            ],
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(top: false, bottom: !reviewing, child: body),
      ),
    );
  }
}
