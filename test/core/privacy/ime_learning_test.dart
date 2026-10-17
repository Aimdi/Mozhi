import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/core/privacy/ime_learning.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

void main() {
  group('imeLearningAllowed', () {
    Widget probe(List<bool> results) => Directionality(
      textDirection: TextDirection.ltr,
      child: Builder(
        builder: (context) {
          results.add(imeLearningAllowed(context));
          return const SizedBox();
        },
      ),
    );

    testWidgets('is true without a SettingsCubit', (tester) async {
      final results = <bool>[];
      await tester.pumpWidget(probe(results));
      expect(results, [true]);
    });

    testWidgets('follows incognito', (tester) async {
      final settings = _MockSettingsCubit();
      whenListen(
        settings,
        Stream.fromIterable(const [AppSettings(incognito: true)]),
        initialState: const AppSettings(),
      );
      final results = <bool>[];

      await tester.pumpWidget(
        BlocProvider<SettingsCubit>.value(
          value: settings,
          child: probe(results),
        ),
      );
      await tester.pump();

      expect(results, [true, false]);
    });
  });
}
