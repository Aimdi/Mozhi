@Timeout(Duration(seconds: 60))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/presets/widgets/preset_options_form.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';
import '../helpers.dart';

class _Host extends StatefulWidget {
  const new({required this.changes});

  final List<TranslationOptions> changes;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  TranslationOptions value = const TranslationOptions(context: 'Start');

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      children: [
        TextButton(
          onPressed: () =>
              setState(() => value = value.copyWith(context: 'External')),
          child: const Text('external'),
        ),
        PresetOptionsForm(
          value: value,
          onChanged: (options) {
            widget.changes.add(options);
            setState(() => value = options);
          },
        ),
      ],
    ),
  );
}

void main() {
  testWidgets('PresetOptionsForm reports every control', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <TranslationOptions>[];
    await tester.pumpApp(_Host(changes: changes));

    await tester.tap(find.text('Literal'));
    await settle(tester);
    expect(changes.last.style, TranslationStyle.literal);

    await tester.tap(find.byKey(const Key('preset_form_formality_preferLess')));
    await settle(tester);
    expect(changes.last.formality, Formality.preferLess);

    await tester.tap(find.byKey(const Key('preset_form_reading_level')));
    await settle(tester);
    await tester.tap(find.text('B1 · Intermediate').last);
    await settle(tester);
    expect(changes.last.readingLevel, ReadingLevel.b1);

    await tester.tap(find.byKey(const Key('preset_form_speaker_feminine')));
    await settle(tester);
    expect(changes.last.speakerGender, Gender.feminine);

    await tester.tap(find.byKey(const Key('preset_form_addressee_neutral')));
    await settle(tester);
    expect(changes.last.addresseeGender, Gender.neutral);

    await tester.enterText(
      find.byKey(const Key('preset_form_context')),
      'Formal letter',
    );
    await settle(tester);
    expect(changes.last.context, 'Formal letter');

    await tester.tap(find.byKey(const Key('preset_form_formatting')));
    await settle(tester);
    expect(changes.last.preserveFormatting, isFalse);

    // External changes update the context field.
    await tester.tap(find.text('external'));
    await settle(tester);
    expect(find.text('External'), findsOneWidget);
    expect(changes.last.style, TranslationStyle.literal);
  });
}
