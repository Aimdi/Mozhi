import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/view/widgets/settings_section.dart';

/// Independent WCAG 2.x contrast computation from 8-bit sRGB channels, so
/// the test does not just repeat the widget's own arithmetic.
double _wcagContrast(Color a, Color b) {
  double channel(double c) {
    final v = (c * 255).round() / 255;
    return v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  double luminance(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);

  final la = luminance(a);
  final lb = luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

const _seeds = <String, Color>{
  'indigo': Color(0xFF3F51B5),
  'amber': Color(0xFFFFB300),
  'green': Color(0xFF43A047),
  'red': Color(0xFFD32F2F),
  'teal': Color(0xFF00897B),
  'pink': Color(0xFFD81B60),
};

/// Every accent the app passes to [StatusBadge].
Map<String, Color> _accents(ColorScheme scheme) => {
  'success': scheme.success,
  'warning': scheme.warning,
  'error': scheme.error,
  'primary': scheme.primary,
  'tertiary': scheme.tertiary,
  'onSurfaceVariant': scheme.onSurfaceVariant,
};

void main() {
  group('StatusBadge contrast', () {
    for (final MapEntry(key: seedName, value: seed) in _seeds.entries) {
      for (final brightness in Brightness.values) {
        test('text and icon reach 4.5:1 ($seedName, ${brightness.name})', () {
          final scheme = ColorScheme.fromSeed(
            seedColor: seed,
            brightness: brightness,
          );
          for (final MapEntry(key: name, value: accent) in _accents(
            scheme,
          ).entries) {
            final (:background, :foreground) = StatusBadge.colorsFor(
              accent,
              scheme,
            );
            expect(background.a, 1, reason: '$name background is opaque');
            expect(
              _wcagContrast(foreground, background),
              greaterThanOrEqualTo(4.5),
              reason: '$name badge on $seedName/${brightness.name}',
            );
          }
        });
      }
    }

    test('pure black dark theme', () {
      final scheme = ColorScheme.fromSeed(
        seedColor: _seeds['indigo']!,
        brightness: Brightness.dark,
      ).copyWith(surface: Colors.black, surfaceContainerLow: Colors.black);
      for (final accent in _accents(scheme).values) {
        final (:background, :foreground) = StatusBadge.colorsFor(
          accent,
          scheme,
        );
        expect(
          _wcagContrast(foreground, background),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('keeps the accent when it already contrasts enough', () {
      final scheme = ColorScheme.fromSeed(seedColor: _seeds['indigo']!);
      final (:foreground, background: _) = StatusBadge.colorsFor(
        scheme.error,
        scheme,
      );
      expect(foreground, scheme.error);
    });

    test('contrastRatio matches the WCAG formula', () {
      expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
      expect(contrastRatio(Colors.white, Colors.white), closeTo(1, 0.01));
      expect(
        contrastRatio(const Color(0xFF146C2E), Colors.white),
        closeTo(_wcagContrast(const Color(0xFF146C2E), Colors.white), 0.05),
      );
    });

    for (final brightness in Brightness.values) {
      testWidgets('rendered badges are readable (${brightness.name})', (
        tester,
      ) async {
        final theme = ThemeData(
          colorSchemeSeed: _seeds['indigo'],
          brightness: brightness,
        );
        final accents = _accents(theme.colorScheme);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Column(
                children: [
                  for (final MapEntry(:key, :value) in accents.entries)
                    StatusBadge(label: key, color: value, icon: Icons.circle),
                ],
              ),
            ),
          ),
        );
        for (final name in accents.keys) {
          final badge = find.ancestor(
            of: find.text(name),
            matching: find.byType(StatusBadge),
          );
          final box = tester.widget<DecoratedBox>(
            find.descendant(of: badge, matching: find.byType(DecoratedBox)),
          );
          final background = (box.decoration as BoxDecoration).color!;
          final text = tester.widget<Text>(find.text(name)).style!.color!;
          final icon = tester
              .widget<Icon>(
                find.descendant(of: badge, matching: find.byType(Icon)),
              )
              .color!;
          expect(
            _wcagContrast(text, background),
            greaterThanOrEqualTo(4.5),
            reason: '$name text',
          );
          expect(
            _wcagContrast(icon, background),
            greaterThanOrEqualTo(3),
            reason: '$name icon',
          );
        }
      });
    }

    testWidgets('a semantics label replaces the visible label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: StatusBadge(
                label: '120 ms',
                color: Colors.green,
                semanticsLabel: '120 ms, fast',
              ),
            ),
          ),
        ),
      );
      expect(find.semantics.byLabel('120 ms, fast'), findsOne);
      expect(find.semantics.byLabel('120 ms'), findsNothing);
      handle.dispose();
    });
  });
}
