import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
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
/// Kept apart from the (deferred) dictionary page so that History can
/// import it without loading the page.
class DictionaryLookUpRequest {
  // Not const: every navigation needs a new instance (see above).
  new({this.verbosity});

  /// The detail level of the look-up; null keeps the dictionary's.
  final DictionaryVerbosity? verbosity;

  @override
  String toString() => 'DictionaryLookUpRequest(${verbosity?.name})';
}

/// The [DictionaryLookUpRequest] the router's current location was opened
/// with ([GoRouter.state]), or null (no router, another `extra`).
DictionaryLookUpRequest? dictionaryRequestOf(BuildContext context) =>
    switch (GoRouter.maybeOf(context)?.state.extra) {
      final DictionaryLookUpRequest request => request,
      _ => null,
    };
