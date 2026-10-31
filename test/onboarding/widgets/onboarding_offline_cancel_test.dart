import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/offline/cubit/offline_models_cubit.dart';
import 'package:mozhi/onboarding/onboarding.dart';

import '../../helpers/helpers.dart';

void main() {
  const french = OfflineLanguage(code: 'fr', name: 'French');
  final cancel = find.byKey(const Key('offline_cancel_download'));

  group('OnboardingOfflineLanguageRow Cancel', () {
    late List<String> calls;

    setUp(() => calls = []);

    Future<void> pump(
      WidgetTester tester, {
      OfflineModelOperation pending = OfflineModelOperation.download,
      bool cancellable = true,
      bool cancelling = false,
    }) => tester.pumpApp(
      Scaffold(
        body: OnboardingOfflineLanguageRow(
          language: french,
          downloaded: pending == OfflineModelOperation.delete,
          pending: pending,
          progress: 0.5,
          onDownload: () => calls.add('download'),
          onDelete: () => calls.add('delete'),
          onCancel: cancellable ? () => calls.add('cancel') : null,
          cancelling: cancelling,
        ),
      ),
    );

    testWidgets('sits next to the progress of a download', (tester) async {
      await pump(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('50%'), findsOneWidget);
      expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
      await tester.tap(cancel);
      expect(calls, ['cancel']);
    });

    testWidgets('says Stopping… and is disabled while stopping', (
      tester,
    ) async {
      await pump(tester, cancelling: true);
      expect(find.textContaining('Stopping…'), findsOneWidget);
      expect(tester.widget<TextButton>(cancel).onPressed, isNull);
    });

    testWidgets('is not offered for a deletion or without onCancel', (
      tester,
    ) async {
      await pump(tester, pending: OfflineModelOperation.delete);
      expect(cancel, findsNothing);
      await pump(tester, cancellable: false);
      expect(cancel, findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
