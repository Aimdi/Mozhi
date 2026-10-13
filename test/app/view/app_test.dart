import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/app/app.dart';

void main() {
  group('App', () {
    testWidgets('renders', (tester) async {
      await tester.pumpWidget(const App());
      expect(find.byType(App), findsOneWidget);
    });
  });
}
