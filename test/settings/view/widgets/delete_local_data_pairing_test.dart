import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/widgets/delete_local_data.dart';

import '../helpers.dart';

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(const AppSettings());
  });

  test('deletes what an interrupted transfer left', () async {
    final history = createHistoryCubit();
    when(history.deleteAll).thenAnswer((_) async {});
    when(() => history.search(any())).thenReturn(null);
    final settings = createSettingsCubit();
    var deleted = 0;

    await LocalDataEraser(
      history: history,
      settings: settings,
      deletePairingFiles: () async => deleted++,
    ).erase();

    expect(deleted, 1);
  });
}
