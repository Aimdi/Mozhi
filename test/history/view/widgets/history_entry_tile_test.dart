import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/history/models/history_entry.dart';
import 'package:mozhi/history/view/widgets/history_entry_tile.dart';
import 'package:mozhi/settings/cubit/settings_cubit.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../../helpers/helpers.dart';
import '../../../settings/view/helpers.dart' show createSettingsCubit;

final _entry = HistoryEntry(
  id: '1',
  text: 'Bonjour',
  translation: 'Hello',
  source: Language.auto,
  target: const Language(code: 'en', name: 'English'),
  engineId: 'mozhi:google',
  engineName: 'Google',
  createdAt: DateTime.now(),
  detectedSource: 'fr',
);

const _pair = '\u2068French (detected)\u2069 → \u2068English\u2069';

void main() {
  group(HistoryEntryTile, () {
    Future<void> pump(
      WidgetTester tester,
      double width, {
      SettingsCubit? settings,
    }) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final Widget page = Scaffold(
        body: ListView(
          children: [
            HistoryEntryTile(
              entry: _entry,
              onTap: () {},
              onToggleFavorite: () {},
              onDelete: () {},
            ),
          ],
        ),
      );
      await tester.pumpApp(
        settings == null
            ? page
            : BlocProvider<SettingsCubit>.value(value: settings, child: page),
      );
    }

    testWidgets('puts the pair and the meta on one line when they fit', (
      tester,
    ) async {
      await pump(tester, 800);
      expect(find.text(_pair), findsOneWidget);
      expect(find.text(' · Google · now'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(' · Google · now')).dy,
        tester.getTopLeft(find.text(_pair)).dy,
      );
    });

    testWidgets('moves the meta below a pair that would be cut', (
      tester,
    ) async {
      await pump(tester, 400);
      expect(tester.takeException(), isNull);
      final pair = tester.renderObject<RenderParagraph>(find.text(_pair));
      expect(pair.didExceedMaxLines, isFalse);
      expect(find.text('Google · now'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Google · now')).dy,
        greaterThan(tester.getTopLeft(find.text(_pair)).dy),
      );
    });

    for (final enabled in [true, false]) {
      testWidgets('a long press opens the menu, vibrating only with haptic '
          'feedback on (${enabled ? 'on' : 'off'})', (tester) async {
        final haptics = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method.startsWith('HapticFeedback')) {
              haptics.add(call.method);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await pump(
          tester,
          800,
          settings: createSettingsCubit(AppSettings(hapticFeedback: enabled)),
        );

        await tester.longPress(find.text('Bonjour'));
        await tester.pumpAndSettle();

        expect(find.text('Delete'), findsOneWidget);
        expect(haptics, enabled ? ['HapticFeedback.vibrate'] : isEmpty);
      });
    }
  });
}
