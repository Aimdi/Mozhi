import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/view/widgets/link_launcher.dart';
import 'package:mozhi/speech/speech_error_message.dart';
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
      VoidCallback? onRetry,
    }) async {
      await tester.pumpApp(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSpeechErrorSnackBar(
                context,
                error,
                onListenOnline: onListenOnline,
                onRetry: onRetry,
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
      await tester.tap(find.text('Listen online'));
      expect(approved, _consent);
    });

    for (final width in [360.0, 400.0]) {
      testWidgets('fits a ${width.toInt()} dp wide screen', (tester) async {
        tester.view
          ..physicalSize = Size(width, 800)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await show(
          tester,
          const SpeechUnavailableException(
            'fr',
            cause: ConsentRequiredException(
              kind: ConsentKind.pair,
              destination: PublicInstanceDestination('mozhi.example.org'),
              engineId: 'mozhi:google',
              source: 'fr',
              target: 'fr',
            ),
          ),
          onListenOnline: (_) {},
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(SnackBarAction), findsOneWidget);
        expect(
          find.textContaining('mozhi.example.org can read it'),
          findsOneWidget,
        );
      });
    }

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

    group('when the servers failed', () {
      final error = SpeechUnavailableException(
        'fr',
        cause: AllInstancesFailedException(
          'boom',
          engine: TranslationEngine.mozhi('google', 'Google'),
          instances: const [MozhiInstance(url: 'https://mozhi.example')],
          statusCode: 502,
        ),
      );

      testWidgets('says so plainly and offers Retry', (tester) async {
        var retried = 0;
        await show(tester, error, onRetry: () => retried++);

        expect(
          find.textContaining("The volunteer servers couldn't read this"),
          findsOneWidget,
        );
        expect(find.textContaining('502'), findsNothing);
        expect(
          tester.widget<SnackBar>(find.byType(SnackBar)).duration,
          const Duration(seconds: 6),
        );
        await tester.tap(find.text('Retry'));
        expect(retried, 1);
      });

      testWidgets('without a callback it offers nothing', (tester) async {
        await show(tester, error);

        expect(
          find.textContaining("The volunteer servers couldn't read this"),
          findsOneWidget,
        );
        expect(find.byType(SnackBarAction), findsNothing);
      });
    });

    testWidgets('a voice that is missing offers no Retry', (tester) async {
      await show(
        tester,
        const SpeechUnavailableException('fr'),
        onRetry: () {},
      );

      expect(find.byType(SnackBarAction), findsNothing);
    });

    group('when the device has no speech engine', () {
      late List<Uri> opened;

      setUp(() {
        opened = [];
        final previous = LinkLauncher.launcher;
        LinkLauncher.launcher = (uri) async {
          opened.add(uri);
          return true;
        };
        addTearDown(() => LinkLauncher.launcher = previous);
      });

      testWidgets('says so and offers SherpaTTS', (tester) async {
        await show(
          tester,
          const SpeechUnavailableException('fr', noDeviceEngine: true),
          onRetry: () {},
        );

        expect(find.textContaining('no text-to-speech app'), findsOneWidget);
        expect(
          tester.widget<SnackBar>(find.byType(SnackBar)).duration,
          const Duration(seconds: 10),
        );
        await tester.tap(find.byKey(const Key('speech_get_engine')));
        await tester.pump();
        expect(opened, [speechGetEngineUrl]);
      });

      testWidgets('also when the instance is not offered', (tester) async {
        await show(
          tester,
          const SpeechUnavailableException(
            'fr',
            cause: _consent,
            noDeviceEngine: true,
          ),
        );

        expect(find.textContaining('mozhi.example'), findsNothing);
        expect(find.text('Get SherpaTTS'), findsOneWidget);
      });

      testWidgets('the instance comes first when offered', (tester) async {
        await show(
          tester,
          const SpeechUnavailableException(
            'fr',
            cause: _consent,
            noDeviceEngine: true,
          ),
          onListenOnline: (_) {},
        );

        expect(find.text('Listen online'), findsOneWidget);
        expect(find.text('Get SherpaTTS'), findsNothing);
      });
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
