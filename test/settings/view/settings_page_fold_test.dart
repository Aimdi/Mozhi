import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/view/settings_page.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

import 'helpers.dart';

/// The first [SettingsSection] of the selected category ([title] null: the
/// General settings, which have no heading).
Finder _section(String? title) => title == null
    ? find.byType(SettingsSection).first
    : find
          .ancestor(
            of: find
                .descendant(
                  of: find.byType(SettingsSection),
                  matching: find.text(title),
                )
                .first,
            matching: find.byType(SettingsSection),
          )
          .first;

/// The row of [category] in the list.
Finder _category(SettingsCategory category) =>
    find.byKey(SettingsView.categoryKey(category));

void main() {
  setUpAll(registerFallbacks);

  /// Pumps the settings page in a [size] window with [features], then a
  /// frame more (the split follows its position after the first layout).
  Future<void> pumpWithFeatures(
    WidgetTester tester, {
    required Size size,
    required List<DisplayFeature> features,
  }) async {
    tester
      ..setScreenSize(size)
      ..view.displayFeatures = features;
    addTearDown(tester.view.resetDisplayFeatures);
    await tester.pumpView(
      const SettingsPage(),
      settings: createSettingsCubit(),
      history: createHistoryCubit(),
      router: createRouter(),
    );
    await tester.pump();
  }

  group('SettingsPage on foldables', () {
    testWidgets('splits the two columns at a vertical hinge', (tester) async {
      await pumpWithFeatures(
        tester,
        size: const Size(1114, 2400),
        features: const [
          DisplayFeature(
            bounds: Rect.fromLTWH(540, 0, 34, 2400),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.unknown,
          ),
        ],
      );
      // The categories on one side, the selected one on the other.
      final list = tester.getRect(_category(SettingsCategory.general));
      final detail = tester.getRect(_section(null));
      expect(list.left, greaterThanOrEqualTo(0));
      expect(list.right, lessThanOrEqualTo(540));
      expect(detail.left, greaterThanOrEqualTo(574));
      expect(detail.right, lessThanOrEqualTo(1114));
    });

    testWidgets('uses two columns at a half-opened fold on a narrow window', (
      tester,
    ) async {
      await pumpWithFeatures(
        tester,
        size: const Size(690, 3000),
        features: const [
          DisplayFeature(
            bounds: Rect.fromLTWH(345, 0, 0, 3000),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
      );
      expect(find.byKey(const Key('settings_columns')), findsOneWidget);
      expect(
        tester.getRect(_category(SettingsCategory.general)).right,
        lessThanOrEqualTo(345),
      );
      expect(tester.getRect(_section(null)).left, greaterThanOrEqualTo(345));
    });

    testWidgets('keeps one column at a tabletop fold', (tester) async {
      await pumpWithFeatures(
        tester,
        size: const Size(412, 900),
        features: const [
          DisplayFeature(
            bounds: Rect.fromLTWH(0, 450, 412, 0),
            type: DisplayFeatureType.fold,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
      );
      expect(find.byKey(const Key('settings_columns')), findsNothing);
      // The list of categories alone.
      expect(find.byType(ListView), findsOneWidget);
      expect(find.byType(SettingsSection), findsNothing);
    });
  });
}
