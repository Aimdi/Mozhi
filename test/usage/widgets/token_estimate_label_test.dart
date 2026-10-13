import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/usage/usage.dart';

import '../../helpers/helpers.dart';

void main() {
  testWidgets('hides the estimate for short texts', (tester) async {
    await tester.pumpApp(const TokenEstimateLabel(text: 'Hello'));
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('shows the estimate for long texts', (tester) async {
    await tester.pumpApp(TokenEstimateLabel(text: 'a' * 4000));
    expect(find.text('≈ 1,000 tokens'), findsOneWidget);
  });

  testWidgets('counts CJK characters as tokens', (tester) async {
    await tester.pumpApp(
      TokenEstimateLabel(text: '你好' * 300, minCharacters: 10),
    );
    expect(find.text('≈ 600 tokens'), findsOneWidget);
  });

  testWidgets('uses the singular and a custom style', (tester) async {
    const style = TextStyle(fontSize: 31);
    await tester.pumpApp(
      const TokenEstimateLabel(text: 'abc', minCharacters: 1, style: style),
    );
    expect(find.text('≈ 1 token'), findsOneWidget);
    expect(tester.widget<Text>(find.byType(Text)).style, style);
  });

  testWidgets('shows nothing for empty text', (tester) async {
    await tester.pumpApp(const TokenEstimateLabel(text: '', minCharacters: 0));
    expect(find.byType(Text), findsNothing);
  });
}
