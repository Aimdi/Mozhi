import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:translation_repository/translation_repository.dart';

/// Pass as the navigation's `extra` to the dictionary's location to look
/// its word up right away, like `DictionaryLaunch.lookUp`, with
/// [verbosity] (null: the translate screen's detail level), e.g.
/// `context.go(AppRoutes.dictionaryWord(word: 'gato', from: 'es'),
/// extra: DictionaryLookUpRequest(verbosity: DictionaryVerbosity.concise))`.
///
/// Each request is its own object and is applied once (see
/// [dictionaryRequestOf]), also when the Dictionary tab already shows that
/// location and so keeps its page: opening the same History entry again
/// looks the word up again. Links from outside the app cannot carry it.
///
/// With [saved] (a look-up of the history) the kept entry is shown
/// without asking the AI again (`DictionaryCubit.openSaved`). With
/// [returnTo] (the location the user came from), Back from the entry goes
/// there instead of to the dictionary's search.
///
/// Kept apart from the (deferred) dictionary page so that History can
/// import it without loading the page.
class DictionaryLookUpRequest {
  // Not const: every navigation needs a new instance (see above).
  new({this.verbosity, this.saved, this.returnTo});

  /// The detail level of the look-up; null keeps the dictionary's (or
  /// [saved]'s).
  final DictionaryVerbosity? verbosity;

  /// The history's look-up to show as it was kept; null looks the word up.
  final HistoryEntry? saved;

  /// Where Back from the entry goes (a router location); null: back to the
  /// dictionary's search.
  final String? returnTo;

  @override
  String toString() =>
      'DictionaryLookUpRequest(${verbosity?.name}, ${saved?.id}, $returnTo)';
}

/// The [DictionaryLookUpRequest] the router's current location was opened
/// with ([GoRouter.state]), or null (no router, another `extra`).
DictionaryLookUpRequest? dictionaryRequestOf(BuildContext context) =>
    switch (GoRouter.maybeOf(context)?.state.extra) {
      final DictionaryLookUpRequest request => request,
      _ => null,
    };
