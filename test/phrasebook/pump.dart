import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/phrasebook/data/phrasebook_repository.dart';
import 'package:mozhi/speech/speech_service.dart';

import 'helpers.dart';

class MockSpeechService extends Mock implements SpeechService;

class MockGoRouter extends Mock implements GoRouter;

/// A [MockSpeechService] that reads nothing aloud and says so.
MockSpeechService createSpeech() {
  final speech = MockSpeechService();
  when(() => speech.speaking).thenAnswer((_) => const Stream.empty());
  when(() => speech.current).thenReturn(null);
  when(
    () => speech.toggle(
      id: any(named: 'id'),
      text: any(named: 'text'),
      languageCode: any(named: 'languageCode'),
      allowOnline: any(named: 'allowOnline'),
    ),
  ).thenAnswer((_) async {});
  return speech;
}

/// A [MockGoRouter] whose navigation does nothing.
MockGoRouter createRouter({bool canPop = true}) {
  final router = MockGoRouter();
  when(() => router.push<Object?>(any(), extra: any(named: 'extra')))
      .thenAnswer((_) async => null);
  when(() => router.push<void>(any(), extra: any(named: 'extra')))
      .thenAnswer((_) async {});
  when(() => router.go(any(), extra: any(named: 'extra'))).thenReturn(null);
  when(router.canPop).thenReturn(canPop);
  return router;
}

/// A phrasebook in memory with [favorites] as its Favorites collection.
PhrasebookRepository createPhrasebook({
  FakeFavorites? favorites,
  StarterPhrasebooks? starter,
  KeyValueStore? store,
}) => PhrasebookRepository(
  store: store ?? MemoryStore(),
  keyStore: MemoryStore(),
  favorites: favorites ?? FakeFavorites(),
  starter: starter,
);

extension PumpPhrasebook on WidgetTester {
  /// Sets the logical screen size for this test.
  void setSize(Size size) {
    view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(view.reset);
  }

  /// Pumps [widget] under a [MaterialApp] with the [repository], a speech
  /// service and a router, as the app provides them.
  Future<void> pumpPhrasebook(
    Widget widget, {
    PhrasebookRepository? repository,
    SpeechService? speech,
    GoRouter? router,
    Size size = const Size(420, 900),
    bool disableAnimations = false,
  }) async {
    setSize(size);
    await pumpWidget(
      MultiRepositoryProvider(
        providers: [
          if (repository != null)
            RepositoryProvider<PhrasebookRepository>.value(value: repository),
          RepositoryProvider<SpeechService>.value(
            value: speech ?? createSpeech(),
          ),
        ],
        child: InheritedGoRouter(
          goRouter: router ?? createRouter(),
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true),
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: disableAnimations),
              child: child!,
            ),
            home: widget,
          ),
        ),
      ),
    );
  }
}
