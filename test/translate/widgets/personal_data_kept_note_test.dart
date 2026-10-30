import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/translate/widgets/personal_data_kept_note.dart';

import '../../helpers/helpers.dart';

void main() {
  group('PersonalDataKeptNote', () {
    testWidgets('says how many items were kept, with what that means', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpApp(
        const Scaffold(body: PersonalDataKeptNote(count: 3)),
      );
      expect(find.text('3 items kept on this device'), findsOneWidget);
      expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
      final note = find.bySemanticsLabel('3 items kept on this device');
      expect(note, findsOneWidget);
      expect(
        tester.getSemantics(note).hint,
        'Email addresses, phone numbers and account numbers were replaced '
        'before the text left the device',
      );
      semantics.dispose();
    });

    testWidgets('shows nothing when nothing was kept', (tester) async {
      await tester.pumpApp(
        const Scaffold(body: PersonalDataKeptNote(count: 0)),
      );
      expect(find.textContaining('kept on this device'), findsNothing);
      expect(find.byIcon(Icons.shield_outlined), findsNothing);
    });
  });
}
