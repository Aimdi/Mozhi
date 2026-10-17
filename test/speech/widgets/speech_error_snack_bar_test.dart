import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/speech/speech_service.dart';
import 'package:mozhi/speech/widgets/speech_error_snack_bar.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';

const _consent = ConsentRequiredException(
  kind: ConsentKind.pair,
  destination: PublicInstanceDestination('mozhi.example'),
  engineId: 'mozhi:google',
  source: 'fr',
  target: 'fr',
);

void main() {
  group('showSpeechErrorSnackBar', () {
    Future<void> show(
      WidgetTester tester,
      Object error, {
      void Function(ConsentRequiredException consent)? onListenOnline,
    }) async {
      await tester.pumpApp(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSpeechErrorSnackBar(
                context,
                error,
                onListenOnline: onListenOnline,
              ),
              child: const Text('fail'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('fail'));
      // Let the snack bar slide in.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));
    }

    testWidgets('offers to listen via the instance', (tester) async {
      ConsentRequiredException? approved;

      await show(
        tester,
        const SpeechUnavailableException('fr', cause: _consent),
        onListenOnline: (consent) => approved = consent,
      );

      expect(find.textContaining('mozhi.example can read it'), findsOneWidget);
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).duration,
        const Duration(seconds: 10),
      );
      await tester.tap(find.text('Listen via mozhi.example'));
      expect(approved, _consent);
    });

    testWidgets('without a callback it does not mention the instance', (
      tester,
    ) async {
      await show(
        tester,
        const SpeechUnavailableException('fr', cause: _consent),
      );

      expect(find.textContaining('mozhi.example'), findsNothing);
      expect(find.byType(SnackBarAction), findsNothing);
    });

    testWidgets('shows other errors without an action', (tester) async {
      await show(tester, StateError('codec'), onListenOnline: (_) {});

      expect(find.byType(SnackBarAction), findsNothing);
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).duration,
        const Duration(seconds: 4),
      );
    });
  });
}
