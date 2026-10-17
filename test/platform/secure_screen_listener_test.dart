import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/platform/secure_screen.dart';
import 'package:mozhi/platform/secure_screen_listener.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

class _MockSecureScreen extends Mock implements SecureScreen;

void main() {
  group(SecureScreenListener, () {
    late _MockSettingsCubit settings;
    late _MockSecureScreen screen;
    late StreamController<AppSettings> changes;

    setUp(() {
      settings = _MockSettingsCubit();
      screen = _MockSecureScreen();
      changes = StreamController<AppSettings>.broadcast();
      addTearDown(changes.close);
      when(() => screen.setEnabled(enabled: any(named: 'enabled')))
          .thenAnswer((_) async {});
    });

    Future<void> pump(
      WidgetTester tester,
      AppSettings initial, {
      SecureScreen? secureScreen,
    }) {
      whenListen(settings, changes.stream, initialState: initial);
      return tester.pumpWidget(
        BlocProvider<SettingsCubit>.value(
          value: settings,
          child: SecureScreenListener(
            secureScreen: secureScreen ?? screen,
            child: const SizedBox(),
          ),
        ),
      );
    }

    testWidgets('protects the screen when inserted with it on', (tester) async {
      await pump(tester, const AppSettings(secureScreen: true));
      verify(() => screen.setEnabled(enabled: true)).called(1);
    });

    testWidgets('does nothing when inserted with it off', (tester) async {
      await pump(tester, const AppSettings());
      verifyNever(() => screen.setEnabled(enabled: any(named: 'enabled')));
    });

    testWidgets('follows every change of the setting', (tester) async {
      await pump(tester, const AppSettings());

      changes.add(const AppSettings(secureScreen: true));
      await tester.pump();
      verify(() => screen.setEnabled(enabled: true)).called(1);

      changes.add(const AppSettings(secureScreen: true, incognito: true));
      await tester.pump();
      verifyNever(() => screen.setEnabled(enabled: any(named: 'enabled')));

      changes.add(const AppSettings(incognito: true));
      await tester.pump();
      verify(() => screen.setEnabled(enabled: false)).called(1);
    });

    testWidgets('uses the shared SecureScreen by default', (tester) async {
      final previous = SecureScreen.instance;
      addTearDown(() => SecureScreen.instance = previous);
      SecureScreen.instance = screen;
      whenListen(
        settings,
        changes.stream,
        initialState: const AppSettings(secureScreen: true),
      );
      await tester.pumpWidget(
        BlocProvider<SettingsCubit>.value(
          value: settings,
          child: const SecureScreenListener(child: SizedBox()),
        ),
      );
      verify(() => screen.setEnabled(enabled: true)).called(1);
    });

    test('secureScreenChanged compares the setting only', () {
      expect(
        secureScreenChanged(
          const AppSettings(),
          const AppSettings(secureScreen: true),
        ),
        isTrue,
      );
      expect(
        secureScreenChanged(
          const AppSettings(),
          const AppSettings(incognito: true),
        ),
        isFalse,
      );
    });
  });
}
