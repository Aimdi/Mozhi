import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/widgets/rating_bar.dart';
import 'package:mozhi/settings/models/app_settings.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  const intervals = {
    FsrsRating.again: Duration(minutes: 1),
    FsrsRating.hard: Duration(minutes: 6),
    FsrsRating.good: Duration(days: 1),
    FsrsRating.easy: Duration(days: 4),
  };

  for (final style in AppStyle.values) {
    for (final brightness in Brightness.values) {
      testWidgets('every rating text reads in ${style.name} '
          '${brightness.name}', (tester) async {
        final themes = AppThemes.fromSettings(AppSettings(style: style));
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.light ? themes.light : themes.dark,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: RatingBar(
                intervals: intervals,
                suggested: FsrsRating.good,
                onRate: (_) {},
              ),
            ),
          ),
        );
        for (final rating in FsrsRating.values) {
          final button = find.byKey(ValueKey('practice_rate_${rating.name}'));
          final material = tester.widget<Material>(
            find.descendant(of: button, matching: find.byType(Material)).first,
          );
          final background = material.color!;
          final texts = find.descendant(
            of: button,
            matching: find.byType(Text),
          );
          expect(texts, findsNWidgets(2));
          for (final element in texts.evaluate()) {
            final text = element.widget as Text;
            final color = DefaultTextStyle.of(element).style
                .merge(text.style)
                .color!;
            expect(
              _contrast(color, background),
              greaterThanOrEqualTo(4.5),
              reason: '${rating.name}: "${text.data}"',
            );
          }
        }
      });
    }
  }
}
