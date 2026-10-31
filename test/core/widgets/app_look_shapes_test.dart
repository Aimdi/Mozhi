import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/conversation/widgets/conversation_session_dock.dart';
import 'package:mozhi/core/qr/qr_code_view.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/consent_prompt.dart';
import 'package:mozhi/onboarding/widgets/onboarding_badge.dart';
import 'package:mozhi/onboarding/widgets/progress_dots.dart';
import 'package:mozhi/proofread/widgets/proofread_result_section.dart';
import 'package:mozhi/usage/models/models.dart';
import 'package:mozhi/usage/widgets/usage_bars.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';

/// The shapes of a representative set of widgets that read their corners
/// from [AppLook]: square in the terminal look, the [AppRadius] values in
/// the classic look.
void main() {
  final scheme = ColorScheme.fromSeed(seedColor: kDefaultAccent);

  Future<void> pump(WidgetTester tester, AppLook? look) => tester.pumpApp(
    const Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            OnboardingBadge(label: 'Badge', color: Colors.green),
            ProofreadPill(label: 'Pill'),
            ConversationBetaBadge(),
            ComposerCard(child: Text('composer')),
            ComposerBar(children: [Text('bar')]),
            OnboardingProgressDots(count: 3, current: 1),
            UsageBar(fraction: 0.5),
            SizedBox(
              width: 200,
              child: UsageHistoryChart(
                months: [UsageMonth(2026, 9), UsageMonth(2026, 10)],
                values: [10, 20],
              ),
            ),
            DestinationChip(destination: OnDeviceDestination()),
            QrCodeView(data: 'mozhi', semanticLabel: 'QR', size: 120),
          ],
        ),
      ),
    ),
    theme: look == null ? null : buildAppTheme(scheme, look: look),
  );

  BorderRadiusGeometry? boxRadius(WidgetTester tester, Finder of) {
    final box = tester.widget<DecoratedBox>(
      find.descendant(of: of, matching: find.byType(DecoratedBox)).first,
    );
    return (box.decoration as BoxDecoration).borderRadius;
  }

  ShapeBorder shapeOf(WidgetTester tester, Finder of) {
    final box = tester.widget<DecoratedBox>(
      find.descendant(of: of, matching: find.byType(DecoratedBox)).first,
    );
    return (box.decoration as ShapeDecoration).shape;
  }

  BorderRadiusGeometry? composerRadius(WidgetTester tester) {
    final card = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(ComposerCard),
        matching: find.byType(AnimatedContainer),
      ),
    );
    return (card.decoration! as BoxDecoration).borderRadius;
  }

  BorderRadiusGeometry? dotRadius(WidgetTester tester) {
    final dot = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('onboarding-dot-0')),
    );
    return (dot.decoration! as BoxDecoration).borderRadius;
  }

  BorderRadiusGeometry clipRadius(WidgetTester tester, Type type) => tester
      .widget<ClipRRect>(
        find.descendant(
          of: find.byType(type),
          matching: find.byType(ClipRRect),
        ),
      )
      .borderRadius;

  UsageHistoryPainter chartPainter(WidgetTester tester) =>
      tester
              .widget<CustomPaint>(
                find.descendant(
                  of: find.byType(UsageHistoryChart),
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is CustomPaint &&
                        widget.painter is UsageHistoryPainter,
                  ),
                ),
              )
              .painter!
          as UsageHistoryPainter;

  BorderRadius? chipInkRadius(WidgetTester tester) => tester
      .widget<InkWell>(
        find.descendant(
          of: find.byType(DestinationChip),
          matching: find.byType(InkWell),
        ),
      )
      .borderRadius;

  void expectClassic(WidgetTester tester) {
    expect(
      boxRadius(tester, find.byType(OnboardingBadge)),
      const BorderRadius.all(Radius.circular(AppRadius.badge)),
    );
    expect(shapeOf(tester, find.byType(ProofreadPill)), isA<StadiumBorder>());
    expect(
      shapeOf(tester, find.byType(ConversationBetaBadge)),
      const StadiumBorder(),
    );
    expect(
      composerRadius(tester),
      const BorderRadius.all(Radius.circular(ComposerCard.radius)),
    );
    expect(shapeOf(tester, find.byType(ComposerBar)), isA<StadiumBorder>());
    expect(dotRadius(tester), BorderRadius.circular(4));
    expect(clipRadius(tester, UsageBar), BorderRadius.circular(4));
    expect(chartPainter(tester).rounded, isTrue);
    expect(chipInkRadius(tester), BorderRadius.circular(999));
    expect(clipRadius(tester, QrCodeView), BorderRadius.circular(8));
  }

  group('AppLook shapes', () {
    testWidgets('classic look without a themed app: unchanged', (tester) async {
      await pump(tester, null);
      expectClassic(tester);
    });

    testWidgets('classic look: unchanged', (tester) async {
      await pump(tester, AppLook.classic);
      expectClassic(tester);
    });

    testWidgets('terminal look: square', (tester) async {
      await pump(tester, AppLook.terminal);
      expect(
        boxRadius(tester, find.byType(OnboardingBadge)),
        BorderRadius.zero,
      );
      expect(
        shapeOf(tester, find.byType(ProofreadPill)),
        isA<RoundedRectangleBorder>().having(
          (shape) => shape.borderRadius,
          'borderRadius',
          BorderRadius.zero,
        ),
      );
      expect(
        shapeOf(tester, find.byType(ConversationBetaBadge)),
        const RoundedRectangleBorder(),
      );
      expect(composerRadius(tester), BorderRadius.zero);
      expect(
        shapeOf(tester, find.byType(ComposerBar)),
        isA<RoundedRectangleBorder>().having(
          (shape) => shape.side.color,
          'side colour',
          isNot(Colors.transparent),
        ),
      );
      expect(dotRadius(tester), BorderRadius.zero);
      expect(clipRadius(tester, UsageBar), BorderRadius.zero);
      expect(chartPainter(tester).rounded, isFalse);
      expect(chipInkRadius(tester), BorderRadius.zero);
      expect(clipRadius(tester, QrCodeView), BorderRadius.zero);
    });
  });
}
