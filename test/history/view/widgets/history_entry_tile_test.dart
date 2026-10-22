import 'package:flutter/gestures.dart' show PointerDeviceKind;
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
      HistoryEntry? entry,
      String query = '',
      bool selected = false,
      VoidCallback? onShowDetails,
      VoidCallback? onDelete,
      VoidCallback? onToggleFavorite,
      double textScale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final Widget page = MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: ListView(
            children: [
              HistoryEntryTile(
                entry: entry ?? _entry,
                query: query,
                selected: selected,
                onShowDetails: onShowDetails,
                onTap: () {},
                onToggleFavorite: onToggleFavorite ?? () {},
                onDelete: onDelete ?? () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpApp(
        settings == null
            ? page
            : BlocProvider<SettingsCubit>.value(value: settings, child: page),
      );
    }

    testWidgets('shows the source over its translation and a pair tag', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, 412);
      final source = tester.getRect(find.text('Bonjour'));
      final translation = tester.getRect(find.text('Hello'));
      expect(translation.top, greaterThanOrEqualTo(source.bottom));
      final context = tester.element(find.text('Hello'));
      final theme = Theme.of(context);
      expect(
        tester.widget<Text>(find.text('Hello')).style?.color,
        theme.colorScheme.primary,
      );
      expect(
        tester.widget<Text>(find.text('Bonjour')).style?.fontSize,
        theme.textTheme.bodyLarge?.fontSize,
      );
      // A short tag, read as the whole pair.
      expect(find.text('\u2068FR\u2069 → \u2068EN\u2069'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Bonjour')).label,
        'Bonjour\nHello\n$_pair',
      );
      // The engine and the time are left to the details.
      expect(find.textContaining('Google'), findsNothing);
      handle.dispose();
    });

    testWidgets('is compact: about nine rows fit a phone screen', (
      tester,
    ) async {
      await pump(tester, 412);
      final height = tester.getSize(find.byType(HistoryEntryTile)).height;
      expect(height, lessThanOrEqualTo(72));
      // Still a 48 dp target.
      expect(height, greaterThanOrEqualTo(48));
    });

    testWidgets('fits 320dp at 200% text', (tester) async {
      await pump(tester, 320, textScale: 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('names a custom target in the tag and an unknown source '
        'with a question mark', (tester) async {
      await pump(
        tester,
        412,
        entry: HistoryEntry(
          id: '2',
          text: 'Hello',
          translation: 'Ahoy',
          source: Language.auto,
          target: const Language.custom('Pirate'),
          engineId: 'ai:p1',
          engineName: 'Claude',
          createdAt: DateTime.now(),
        ),
      );
      expect(find.text('\u2068?\u2069 → \u2068Pirate\u2069'), findsOneWidget);
    });

    testWidgets('highlights the search in both lines', (tester) async {
      await pump(tester, 412, query: 'LL');
      List<TextSpan> matches(String text) {
        final rich = tester.widget<RichText>(
          find.byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText() == text,
          ),
        );
        final spans = <TextSpan>[];
        rich.text.visitChildren((span) {
          if (span is TextSpan && span.style?.backgroundColor != null) {
            spans.add(span);
          }
          return true;
        });
        return spans;
      }

      expect(matches('Hello').map((s) => s.text), ['ll']);
      expect(matches('Hello').single.locale, const Locale('en'));
      expect(matches('Bonjour'), isEmpty);
    });

    testWidgets('marks the row shown in the details', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, 412, selected: true);
      final material = tester.widget<Material>(
        find
            .ancestor(
              of: find.byType(InkWell).first,
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color?.a, greaterThan(0));
      expect(
        tester.getSemantics(find.byType(InkWell).first),
        isSemantics(isSelected: true, hasSelectedState: true),
      );
      handle.dispose();
    });

    testWidgets('a mouse over the row shows copy, share and delete', (
      tester,
    ) async {
      var deleted = 0;
      await pump(tester, 800, onDelete: () => deleted++);
      expect(find.byTooltip('Copy'), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Bonjour')));
      await tester.pump();
      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(find.byTooltip('Share'), findsOneWidget);
      expect(find.byKey(HistoryEntryTile.pairTagKey), findsNothing);
      await tester.tap(find.byTooltip('Delete'));
      expect(deleted, 1);

      await mouse.moveTo(const Offset(400, 700));
      await tester.pump();
      expect(find.byTooltip('Copy'), findsNothing);
      expect(find.byKey(HistoryEntryTile.pairTagKey), findsOneWidget);
    });

    testWidgets('keyboard focus in the row shows them too', (tester) async {
      await pump(tester, 800);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(find.byTooltip('Copy'), findsOneWidget);
    });

    testWidgets('the menu has copy, share, details, favourite and delete', (
      tester,
    ) async {
      var details = 0;
      var favorites = 0;
      var deleted = 0;
      await pump(
        tester,
        800,
        onShowDetails: () => details++,
        onToggleFavorite: () => favorites++,
        onDelete: () => deleted++,
      );
      Future<void> pick(String item) async {
        await tester.tap(find.byTooltip('More actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(item).last);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      for (final item in [
        'Copy',
        'Share',
        'Details',
        'Add to favorites',
        'Delete',
      ]) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await pick('Details');
      await pick('Add to favorites');
      await pick('Delete');
      expect((details, favorites, deleted), (1, 1, 1));
    });

    testWidgets('the menu has no Details without a place to show them', (
      tester,
    ) async {
      await pump(tester, 800);
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.text('Details'), findsNothing);
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
