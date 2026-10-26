import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/view/categories/appearance_settings.dart';
import 'package:mozhi/settings/view/settings_search_index.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

void main() {
  late _MockSettingsCubit settings;

  setUp(() {
    settings = _MockSettingsCubit();
    when(() => settings.state).thenReturn(const AppSettings());
  });

  Future<void> pump(WidgetTester tester, AppSettings state) {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(800, 3000);
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      BlocProvider<SettingsCubit>.value(
        value: settings,
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: AppearanceSettings(settings: state),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('"Tap a word to look it up" switches the setting', (
    tester,
  ) async {
    await pump(tester, const AppSettings());
    final tile = tester.widget<SwitchListTile>(
      find.byKey(const Key('settings_tap_to_look_up')),
    );
    expect(tile.value, isTrue);
    await tester.tap(find.text('Tap a word to look it up'));
    verify(() => settings.setTapToLookUp(enabled: false)).called(1);
  });

  testWidgets('"Highlight the word being read" switches the setting', (
    tester,
  ) async {
    await pump(tester, const AppSettings(highlightSpokenWord: false));
    final tile = tester.widget<SwitchListTile>(
      find.byKey(const Key('settings_highlight_spoken_word')),
    );
    expect(tile.value, isFalse);
    await tester.tap(find.text('Highlight the word being read'));
    verify(() => settings.setHighlightSpokenWord(enabled: true)).called(1);
  });

  testWidgets('the settings search finds both', (tester) async {
    late List<String> anchors;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            anchors = [
              for (final entry in settingsSearchIndex(
                context,
                const AppSettings(),
              ))
                entry.anchor,
            ];
            return const SizedBox();
          },
        ),
      ),
    );
    expect(anchors, contains(AppearanceAnchors.tapToLookUp));
    expect(anchors, contains(AppearanceAnchors.highlightSpokenWord));
  });
}
