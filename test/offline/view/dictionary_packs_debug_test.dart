import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/dictionary/data/dictionary_packs.dart';
import 'package:mozhi/offline/offline.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../dictionary/data/dictionary_pack_fixtures.dart';
import '../../helpers/helpers.dart';

class _Observer extends BlocObserver {
  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    // ignore: avoid_print
    print('DEBUG error $error\n$stackTrace');
    super.onError(bloc, error, stackTrace);
  }
}

void main() {
  testWidgets('debug', (tester) async {
    Bloc.observer = _Observer();
    final spanish = spanishPack();
    final es = packInfo('es', spanish);
    final storage = MemoryDictionaryPackStorage();
    final packs = DictionaryPacks(
      catalog: DictionaryPackCatalog([es]),
      storage: storage,
      httpClient: MockClient((_) async => http.Response.bytes(spanish, 200)),
      isMeteredConnection: () async => false,
    );
    await tester.pumpApp(DictionaryPacksPage(packs: packs, store: MemoryStore()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('offline_download_pill')));
    await tester.pump();
    var state0 = tester
        .element(find.byType(DictionaryPacksView))
        .read<DictionaryPacksCubit>()
        .state;
    // ignore: avoid_print
    print('DEBUG after pump ${state0.pending} ${state0.progress}');
    // ignore: avoid_print
    print('DEBUG storage ${storage.debugIds}');
    await tester.pump(const Duration(seconds: 61));
    state0 = tester
        .element(find.byType(DictionaryPacksView))
        .read<DictionaryPacksCubit>()
        .state;
    // ignore: avoid_print
    print('DEBUG after 61s ${state0.pending} ${state0.progress} ${state0.outcome?.error}');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await tester.pumpAndSettle();
    final state = tester
        .element(find.byType(DictionaryPacksView))
        .read<DictionaryPacksCubit>()
        .state;
    // ignore: avoid_print
    print('DEBUG outcome ${state.outcome} ${state.outcome?.error} '
        '${await storage.list()} pending=${state.pending}');
  });
}
