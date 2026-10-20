import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:mozhi/core/haptics.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';

class _MockSettingsCubit extends MockCubit<AppSettings>
    implements SettingsCubit;

void main() {
  group(Haptics, () {
    late List<String?> vibrations;

    setUp(() {
      vibrations = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') {
              vibrations.add(call.arguments as String?);
            }
            return null;
          });
    });

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    /// Pumps a widget and returns its context, below a [SettingsCubit]
    /// holding [settings] when given.
    Future<BuildContext> pump(
      WidgetTester tester, {
      AppSettings? settings,
    }) async {
      late BuildContext context;
      final probe = Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      );
      if (settings == null) {
        await tester.pumpWidget(probe);
      } else {
        final cubit = _MockSettingsCubit();
        when(() => cubit.state).thenReturn(settings);
        await tester.pumpWidget(
          BlocProvider<SettingsCubit>.value(value: cubit, child: probe),
        );
      }
      return context;
    }

    testWidgets('vibrates when haptic feedback is on', (tester) async {
      final context = await pump(tester, settings: const AppSettings());

      expect(Haptics.enabled(context), isTrue);
      Haptics.light(context);
      Haptics.selection(context);
      await tester.pump();

      expect(vibrations, [
        'HapticFeedbackType.lightImpact',
        'HapticFeedbackType.selectionClick',
      ]);
    });

    testWidgets('stays still when haptic feedback is off', (tester) async {
      final context = await pump(
        tester,
        settings: const AppSettings(hapticFeedback: false),
      );

      expect(Haptics.enabled(context), isFalse);
      Haptics.light(context);
      Haptics.selection(context);
      await tester.pump();

      expect(vibrations, isEmpty);
    });

    testWidgets('vibrates (the default) without a SettingsCubit', (
      tester,
    ) async {
      final context = await pump(tester);

      expect(Haptics.enabled(context), isTrue);
      Haptics.light(context);
      await tester.pump();

      expect(vibrations, ['HapticFeedbackType.lightImpact']);
    });
  });
}
