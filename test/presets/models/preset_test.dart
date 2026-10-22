import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/presets/models/preset.dart';
import 'package:translation_repository/translation_repository.dart';

void main() {
  group('BuiltInPreset', () {
    test('has the documented example settings', () {
      expect(BuiltInPreset.emailFormal.options.formality, Formality.more);
      expect(BuiltInPreset.emailFormal.options.context, isNotEmpty);
      expect(BuiltInPreset.chatCasual.options.formality, Formality.less);
      expect(BuiltInPreset.simpleA2.options.readingLevel, ReadingLevel.a2);
    });
  });

  group('Preset', () {
    const options = TranslationOptions(
      style: TranslationStyle.literal,
      formality: Formality.preferMore,
      readingLevel: ReadingLevel.b1,
      speakerGender: Gender.feminine,
      addresseeGender: Gender.masculine,
      context: 'Legal letter',
      preserveFormatting: false,
    );
    const preset = Preset(id: 'p1', name: 'Legal', options: options);

    test('example uses a stable id and empty name', () {
      final example = Preset.example(BuiltInPreset.chatCasual);
      expect(example.id, 'builtin-chatCasual');
      expect(example.name, isEmpty);
      expect(example.builtIn, BuiltInPreset.chatCasual);
      expect(example.options, BuiltInPreset.chatCasual.options);
    });

    test('round-trips through JSON', () {
      final json = preset.toJson();
      expect(json['id'], 'p1');
      expect(json['name'], 'Legal');
      expect(json.containsKey('builtIn'), isFalse);
      expect(Preset.fromJson(json), preset);
      final example = Preset.example(BuiltInPreset.simpleA2);
      expect(example.toJson()['builtIn'], 'simpleA2');
      expect(Preset.fromJson(example.toJson()), example);
    });

    test('toJson drops glossary and instructions', () {
      const withExtras = Preset(
        id: 'x',
        options: TranslationOptions(
          glossary: {'a': 'b'},
          instructions: 'Shorter',
        ),
      );
      final json = withExtras.toJson()['options'] as Map<String, dynamic>;
      expect(json.containsKey('glossary'), isFalse);
      expect(json.containsKey('instructions'), isFalse);
    });

    test('fromJson is tolerant', () {
      final parsed = Preset.fromJson(const {
        'id': 'p2',
        'name': 42,
        'builtIn': 'unknown',
        'options': {
          'formality': 'formal',
          'readingLevel': 'zz',
          'glossary': {'a': 'b'},
          'future': true,
        },
        'extra': 'ignored',
      });
      expect(parsed.name, isEmpty);
      expect(parsed.builtIn, isNull);
      expect(parsed.options.formality, Formality.more);
      expect(parsed.options.readingLevel, ReadingLevel.standard);
      expect(parsed.options.glossary, isEmpty);
      expect(
        Preset.fromJson(const {'id': 'p3', 'options': 'nope'}).options,
        const TranslationOptions(),
      );
    });

    test('fromJson throws without an id', () {
      expect(() => Preset.fromJson(const {}), throwsFormatException);
      expect(() => Preset.fromJson(const {'id': ' '}), throwsFormatException);
      expect(() => Preset.fromJson(const {'id': 3}), throwsFormatException);
    });

    test('settingsOf strips glossary and instructions only', () {
      const value = TranslationOptions(
        formality: Formality.less,
        glossary: {'a': 'b'},
        instructions: 'x',
      );
      expect(
        Preset.settingsOf(value),
        const TranslationOptions(formality: Formality.less),
      );
      const plain = TranslationOptions(formality: Formality.less);
      expect(identical(Preset.settingsOf(plain), plain), isTrue);
    });

    test('appliesTo ignores glossary and instructions', () {
      expect(
        preset.appliesTo(
          options.copyWith(glossary: {'a': 'b'}, instructions: 'x'),
        ),
        isTrue,
      );
      expect(preset.appliesTo(options.copyWith(context: 'Other')), isFalse);
    });

    test('copyWith keeps builtIn and replaces fields', () {
      final example = Preset.example(BuiltInPreset.emailFormal);
      final renamed = example.copyWith(name: 'Mail', id: 'new');
      expect(renamed.id, 'new');
      expect(renamed.name, 'Mail');
      expect(renamed.builtIn, BuiltInPreset.emailFormal);
      expect(renamed.options, example.options);
      expect(example.copyWith(options: options).options, options);
    });

    test('equality ignores glossary in options', () {
      expect(
        const Preset(
          id: 'a',
          options: TranslationOptions(glossary: {'x': 'y'}),
        ),
        const Preset(id: 'a'),
      );
    });
  });

  group('PresetCollection', () {
    const a = Preset(id: 'a', name: 'A');
    const b = Preset(
      id: 'b',
      name: 'B',
      options: TranslationOptions(formality: Formality.more),
    );

    test('examples contain every built-in preset', () {
      final examples = PresetCollection.examples();
      expect(examples.presets.map((p) => p.builtIn), BuiltInPreset.values);
      expect(examples.defaultId, isNull);
    });

    test('byId and defaultPreset', () {
      const collection = PresetCollection(presets: [a, b], defaultId: 'b');
      expect(collection.byId('a'), a);
      expect(collection.byId('zz'), isNull);
      expect(collection.byId(null), isNull);
      expect(collection.defaultPreset, b);
      expect(const PresetCollection(presets: [a]).defaultPreset, isNull);
    });

    test('toJson writes the version and only a valid default id', () {
      const collection = PresetCollection(presets: [a, b], defaultId: 'b');
      final json = collection.toJson();
      expect(json['version'], PresetCollection.version);
      expect(json['defaultId'], 'b');
      expect(json['presets'], hasLength(2));
      expect(
        const PresetCollection(presets: [a], defaultId: 'gone').toJson(),
        isNot(contains('defaultId')),
      );
    });

    test('tryParse round-trips', () {
      const collection = PresetCollection(presets: [a, b], defaultId: 'b');
      expect(PresetCollection.tryParse(collection.toJson()), collection);
    });

    test('tryParse accepts a bare list and newer versions', () {
      expect(
        PresetCollection.tryParse([a.toJson()]),
        const PresetCollection(presets: [a]),
      );
      expect(
        PresetCollection.tryParse({
          'version': 99,
          'presets': [b.toJson()],
          'defaultId': 'b',
          'somethingNew': {'x': 1},
        }),
        const PresetCollection(presets: [b], defaultId: 'b'),
      );
    });

    test('tryParse skips invalid entries, duplicates and stale defaults', () {
      final parsed = PresetCollection.tryParse({
        'presets': [
          a.toJson(),
          'garbage',
          {'name': 'no id'},
          {...a.toJson(), 'name': 'duplicate'},
          b.toJson(),
        ],
        'defaultId': 'missing',
      });
      expect(parsed, const PresetCollection(presets: [a, b]));
      expect(
        PresetCollection.tryParse({
          'presets': [a.toJson()],
          'defaultId': 5,
        })!.defaultId,
        isNull,
      );
    });

    test('tryParse returns null for other shapes', () {
      expect(PresetCollection.tryParse(null), isNull);
      expect(PresetCollection.tryParse('x'), isNull);
      expect(PresetCollection.tryParse({'presets': 'x'}), isNull);
    });
  });

  group('change times', () {
    final at = DateTime.utc(2026, 10, 20, 9, 30);
    final stamped = Preset(id: 'a', name: 'A', updatedAt: at);

    test('a preset writes its updatedAt (UTC) only when it has one', () {
      expect(const Preset(id: 'a').toJson(), isNot(contains('updatedAt')));
      expect(
        Preset(id: 'a', updatedAt: at.toLocal()).toJson()['updatedAt'],
        '2026-10-20T09:30:00.000Z',
      );
    });

    test('a preset reads its updatedAt back, ignoring invalid ones', () {
      expect(Preset.fromJson(stamped.toJson()).updatedAt, at);
      expect(
        Preset.fromJson(const {'id': 'a', 'updatedAt': 'soon'}).updatedAt,
        isNull,
      );
      expect(
        Preset.fromJson(const {'id': 'a', 'updatedAt': 5}).updatedAt,
        isNull,
      );
      expect(Preset.fromJson(const {'id': 'a'}).updatedAt, isNull);
    });

    test('modifiedAt falls back to the epoch', () {
      expect(stamped.modifiedAt, at);
      expect(const Preset(id: 'a').modifiedAt, DateTime.utc(1970));
    });

    test('are not part of equality', () {
      expect(stamped, const Preset(id: 'a', name: 'A'));
    });

    test('copyWith keeps or sets updatedAt', () {
      final later = at.add(const Duration(days: 1));
      expect(stamped.copyWith(name: 'B').updatedAt, at);
      expect(stamped.copyWith(updatedAt: later).updatedAt, later);
    });

    test('withoutChangeTime drops it', () {
      const plain = Preset(id: 'a', name: 'A');
      expect(stamped.withoutChangeTime().updatedAt, isNull);
      expect(stamped.withoutChangeTime(), stamped);
      expect(identical(plain.withoutChangeTime(), plain), isTrue);
    });

    test('a collection round-trips its change times', () {
      final collection = PresetCollection(
        presets: [stamped],
        defaultId: 'a',
        orderUpdatedAt: at,
        defaultUpdatedAt: at.add(const Duration(hours: 1)),
      );
      final json = collection.toJson();
      expect(json['orderUpdatedAt'], '2026-10-20T09:30:00.000Z');
      expect(json['defaultUpdatedAt'], '2026-10-20T10:30:00.000Z');
      final parsed = PresetCollection.tryParse(json)!;
      expect(parsed.orderUpdatedAt, at);
      expect(parsed.defaultUpdatedAt, at.add(const Duration(hours: 1)));
      expect(parsed.presets.single.updatedAt, at);
    });

    test('a collection without change times writes and reads none', () {
      const collection = PresetCollection(presets: [Preset(id: 'a')]);
      final json = collection.toJson();
      expect(json, isNot(contains('orderUpdatedAt')));
      expect(json, isNot(contains('defaultUpdatedAt')));
      final parsed = PresetCollection.tryParse({
        ...json,
        'orderUpdatedAt': 'later',
      })!;
      expect(parsed.orderUpdatedAt, isNull);
      expect(parsed.defaultUpdatedAt, isNull);
      expect(
        PresetCollection.tryParse([const Preset(id: 'a').toJson()])!
            .orderUpdatedAt,
        isNull,
      );
    });

    test('a collection compares without its change times', () {
      expect(
        PresetCollection(
          presets: const [Preset(id: 'a')],
          orderUpdatedAt: at,
          defaultUpdatedAt: at,
        ),
        const PresetCollection(presets: [Preset(id: 'a')]),
      );
    });
  });
}
