import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/app/theme.dart';
import 'package:mozhi/core/widgets/composer_card.dart';
import 'package:mozhi/core/widgets/x_ui.dart';
import 'package:translation_repository/translation_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  /// The decoration of the [ComposerCard]'s box.
  BoxDecoration cardDecoration(WidgetTester tester) =>
      tester
              .widget<AnimatedContainer>(
                find.descendant(
                  of: find.byType(ComposerCard),
                  matching: find.byType(AnimatedContainer),
                ),
              )
              .decoration!
          as BoxDecoration;

  group('composerFill', () {
    test('is a shade off the page while quiet text stays readable', () {
      final light = ColorScheme.fromSeed(seedColor: kDefaultAccent);
      expect(
        composerFill(light, AppPalette.fromScheme(light).secondaryText),
        light.surfaceContainerLow,
      );
    });

    test('is the page itself when the shade would cost contrast', () {
      final scheme = ColorScheme.fromSeed(seedColor: kDefaultAccent)
          .copyWith(surfaceContainerLow: const Color(0xFF777777));
      expect(composerFill(scheme, const Color(0xFF808080)), scheme.surface);
    });
  });

  group('composerMotion', () {
    testWidgets('is short, and none with reduced motion', (tester) async {
      late Duration normal;
      late Duration reduced;
      await tester.pumpApp(
        Column(
          children: [
            Builder(
              builder: (context) {
                normal = composerMotion(context);
                return const SizedBox();
              },
            ),
            MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: Builder(
                builder: (context) {
                  reduced = composerMotion(context);
                  return const SizedBox();
                },
              ),
            ),
          ],
        ),
      );
      expect(normal, const Duration(milliseconds: 200));
      expect(reduced, Duration.zero);
    });
  });

  group('ComposerCard', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      bool outlined = true,
      bool expand = false,
      List<Widget> actions = const [],
      VoidCallback? onTap,
      FocusNode? focusNode,
      EdgeInsetsGeometry margin = EdgeInsets.zero,
    }) => tester.pumpApp(
      Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 360,
            height: expand ? 500 : null,
            child: ComposerCard(
              outlined: outlined,
              expand: expand,
              onTap: onTap,
              actions: actions,
              margin: margin,
              bar: const ComposerBar(
                key: Key('bar'),
                children: [SizedBox(width: 48, height: 48)],
              ),
              child: TextField(key: const Key('field'), focusNode: focusNode),
            ),
          ),
        ),
      ),
    );

    testWidgets('is an outlined, filled card with the sheet radius', (
      tester,
    ) async {
      await pumpCard(tester);

      final decoration = cardDecoration(tester);
      final scheme = Theme.of(tester.element(find.byType(ComposerCard)))
          .colorScheme;
      expect(
        decoration.borderRadius,
        const BorderRadius.all(Radius.circular(AppRadius.sheet)),
      );
      expect(
        decoration.border,
        Border.fromBorderSide(BorderSide(color: scheme.outline)),
      );
      expect(decoration.color, isNot(Colors.transparent));
      expect(decoration.color!.a, 1);
      expect(ComposerCard.radius, AppRadius.sheet);
      // The bar sits under the field.
      expect(
        tester.getRect(find.byKey(const Key('bar'))).top,
        greaterThanOrEqualTo(
          tester.getRect(find.byKey(const Key('field'))).bottom,
        ),
      );
    });

    testWidgets('turns flat without its outline and fill', (tester) async {
      await pumpCard(tester, outlined: false, expand: true);

      final decoration = cardDecoration(tester);
      expect(decoration.border, const Border.fromBorderSide(BorderSide.none));
      expect(decoration.color!.a, 0);
      // The field's row fills the height; the bar sits at the bottom.
      expect(
        tester.getRect(find.byKey(const Key('bar'))).bottom,
        moreOrLessEquals(
          tester.getRect(find.byType(ComposerCard)).bottom - 8,
          epsilon: 0.5,
        ),
      );
    });

    testWidgets('puts accent actions at the top end', (tester) async {
      await pumpCard(
        tester,
        actions: [
          IconButton(
            key: const Key('mic'),
            onPressed: () {},
            icon: const Icon(Icons.mic),
          ),
        ],
      );

      final mic = tester.getRect(find.byKey(const Key('mic')));
      final field = tester.getRect(find.byKey(const Key('field')));
      expect(mic.left, greaterThanOrEqualTo(field.right));
      expect(mic.top, lessThanOrEqualTo(field.top + 1));
      final iconColor = IconTheme.of(
        tester.element(
          find.descendant(
            of: find.byKey(const Key('mic')),
            matching: find.byType(Icon),
          ),
        ),
      ).color;
      expect(
        iconColor,
        Theme.of(tester.element(find.byType(ComposerCard))).colorScheme.primary,
      );
    });

    testWidgets('leaves the actions out when there are none', (tester) async {
      await pumpCard(tester);
      expect(find.byKey(const Key('composer_actions')), findsNothing);
    });

    testWidgets('taps on its empty space call onTap', (tester) async {
      var taps = 0;
      await pumpCard(tester, onTap: () => taps++);

      final card = tester.getRect(find.byType(ComposerCard));
      await tester.tapAt(card.topRight + const Offset(-4, 4));
      expect(taps, 1);
    });

    testWidgets('keeps its margin inside, where taps count too', (
      tester,
    ) async {
      var taps = 0;
      await pumpCard(
        tester,
        onTap: () => taps++,
        margin: const EdgeInsets.all(12),
      );

      final card = tester.getRect(find.byType(ComposerCard));
      final box = tester.getRect(
        find
            .descendant(
              of: find.byType(ComposerCard),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(box, card.deflate(12));
      await tester.tapAt(card.topLeft + const Offset(4, 4));
      expect(taps, 1);
    });

    testWidgets('animates a change of its margin', (tester) async {
      await pumpCard(tester, margin: const EdgeInsets.all(12));
      final docked = tester.getRect(find.byType(ComposerCard));
      await pumpCard(tester);
      // Not yet there.
      await tester.pump(const Duration(milliseconds: 100));
      final halfway = tester.getRect(
        find
            .descendant(
              of: find.byType(ComposerCard),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(halfway.width, greaterThan(docked.width - 24));
      expect(halfway.width, lessThan(docked.width));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(
          find
              .descendant(
                of: find.byType(ComposerCard),
                matching: find.byType(DecoratedBox),
              )
              .first,
        ),
        tester.getRect(find.byType(ComposerCard)),
      );
    });

    testWidgets('keeps the field, its focus and text when it turns flat', (
      tester,
    ) async {
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await pumpCard(
        tester,
        onTap: focusNode.requestFocus,
        focusNode: focusNode,
      );
      await tester.tap(find.byKey(const Key('field')));
      await tester.enterText(find.byKey(const Key('field')), 'hello');
      final editable = tester.state(find.byType(EditableText));

      await pumpCard(
        tester,
        outlined: false,
        expand: true,
        focusNode: focusNode,
      );
      await tester.pumpAndSettle();

      expect(tester.state(find.byType(EditableText)), same(editable));
      expect(focusNode.hasFocus, isTrue);
      expect(find.text('hello'), findsOneWidget);
    });
  });

  group('ComposerBar', () {
    testWidgets('divides its parts with hairlines in an outlined pill', (
      tester,
    ) async {
      await tester.pumpApp(
        const Scaffold(
          body: SizedBox(
            width: 300,
            child: ComposerBar(
              children: [
                SizedBox(key: Key('a'), width: 48, height: 48),
                SizedBox(key: Key('b'), width: 48, height: 48),
                Expanded(child: SizedBox(key: Key('c'), height: 48)),
              ],
            ),
          ),
        ),
      );

      expect(find.byType(ComposerBarDivider), findsNWidgets(2));
      // The last part takes the rest of the width.
      expect(
        tester.getRect(find.byKey(const Key('c'))).right,
        moreOrLessEquals(299, epsilon: 0.5),
      );
      final shape = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(ComposerBar),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final border = (shape.decoration as ShapeDecoration).shape;
      expect(border, isA<StadiumBorder>());
      // A control's outline (3:1), not a separator hairline.
      final scheme = Theme.of(tester.element(find.byType(ComposerBar)))
          .colorScheme;
      expect((border as StadiumBorder).side.color, scheme.outline);
    });

    testWidgets('mirrors in right-to-left layouts', (tester) async {
      await tester.pumpApp(
        const Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: SizedBox(
              width: 300,
              child: ComposerBar(
                children: [
                  SizedBox(key: Key('a'), width: 48, height: 48),
                  Expanded(child: SizedBox(key: Key('b'), height: 48)),
                ],
              ),
            ),
          ),
        ),
      );

      expect(
        tester.getCenter(find.byKey(const Key('a'))).dx,
        greaterThan(tester.getCenter(find.byKey(const Key('b'))).dx),
      );
    });
  });

  group('ComposerOptionsButton', () {
    testWidgets('is a tune button with a dot while modified', (tester) async {
      var presses = 0;
      Future<void> pump({required bool modified}) => tester.pumpApp(
        Scaffold(
          body: ComposerOptionsButton(
            tooltip: 'Options',
            modified: modified,
            onPressed: () => presses++,
          ),
        ),
      );

      await pump(modified: false);
      expect(find.byIcon(Icons.tune), findsOneWidget);
      expect(find.byTooltip('Options'), findsOneWidget);
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
      await tester.tap(find.byType(ComposerOptionsButton));
      expect(presses, 1);

      await pump(modified: true);
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isTrue);
      expect(
        tester.getSize(find.byType(IconButton)).height,
        greaterThanOrEqualTo(48),
      );
    });
  });

  group('ComposerGoButton', () {
    Future<void> pumpGo(
      WidgetTester tester, {
      VoidCallback? onPressed,
      bool busy = false,
      String? tooltip,
    }) => tester.pumpApp(
      Scaffold(
        body: Center(
          child: ComposerGoButton(
            label: 'Look up',
            tooltip: tooltip,
            busy: busy,
            onPressed: onPressed,
          ),
        ),
      ),
    );

    Finder tooltipWith(String message) => find.byWidgetPredicate(
      (widget) => widget is Tooltip && widget.message == message,
    );

    testWidgets('is a filled arrow named by its label', (tester) async {
      final semantics = tester.ensureSemantics();
      var presses = 0;
      await pumpGo(tester, onPressed: () => presses++);

      expect(find.byIcon(ComposerGoButton.defaultIcon), findsOneWidget);
      expect(ComposerGoButton.defaultIcon, Icons.arrow_forward_rounded);
      expect(
        tester.getSemantics(find.byType(IconButton)),
        isSemantics(label: 'Look up', isButton: true, isEnabled: true),
      );
      expect(tooltipWith('Look up'), findsOneWidget);
      expect(find.byKey(const Key('composer_go_progress')), findsNothing);
      expect(
        tester.getSize(find.byType(IconButton)).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byType(IconButton));
      expect(presses, 1);
      semantics.dispose();
    });

    testWidgets('shows its own tooltip, a ring while busy, and greys out '
        'while disabled', (tester) async {
      await pumpGo(tester, busy: true, tooltip: 'Look up (Enter)');

      expect(tooltipWith('Look up (Enter)'), findsOneWidget);
      expect(find.byKey(const Key('composer_go_progress')), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
    });

    testWidgets('is a 40 dp circle in a 48 dp target that fits its bar', (
      tester,
    ) async {
      await tester.pumpApp(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: ComposerBar(
                children: [
                  const Expanded(child: SizedBox(height: 20)),
                  ComposerGoButton(label: 'Look up', onPressed: () {}),
                ],
              ),
            ),
          ),
        ),
      );

      final target = tester.getSize(find.byType(ComposerGoButton));
      expect(target, const Size.square(ComposerGoButton.targetSize));
      final bar = tester.getRect(find.byType(ComposerBar));
      final button = tester.getRect(find.byType(ComposerGoButton));
      expect(bar.contains(button.topLeft), isTrue);
      expect(bar.contains(button.bottomRight - const Offset(1, 1)), isTrue);
    });

    testWidgets('keeps the circle at any visual density', (tester) async {
      await tester.pumpApp(
        Theme(
          data: ThemeData(visualDensity: VisualDensity.compact),
          child: Scaffold(
            body: Center(
              child: ComposerGoButton(label: 'Look up', onPressed: () {}),
            ),
          ),
        ),
      );

      expect(
        tester.getSize(find.byType(ComposerGoButton)),
        const Size.square(ComposerGoButton.targetSize),
      );
      final style = tester.widget<IconButton>(find.byType(IconButton)).style!;
      expect(
        style.fixedSize?.resolve({}),
        const Size.square(ComposerGoButton.visualSize),
      );
    });

    test('a disabled go button has no fill, a stop button is tonal', () {
      final scheme = ColorScheme.fromSeed(seedColor: kDefaultAccent);
      final filled = ComposerGoButton.styleOf(scheme);
      expect(
        filled.backgroundColor?.resolve({WidgetState.disabled}),
        Colors.transparent,
      );
      expect(filled.backgroundColor?.resolve({}), scheme.primary);
      final tonal = ComposerGoButton.styleOf(scheme, tonal: true);
      expect(tonal.backgroundColor?.resolve({}), scheme.secondaryContainer);
    });
  });

  group('ComposerEngineChip', () {
    const claude = TranslationEngine(
      id: 'ai:claude',
      kind: EngineKind.ai,
      name: 'Claude',
      subtitle: 'claude-sonnet',
    );
    const local = TranslationEngine(
      id: 'ai:ollama',
      kind: EngineKind.ai,
      name: 'Ollama',
      subtitle: 'llama3',
      isLocal: true,
    );

    Future<void> pumpChip(
      WidgetTester tester, {
      List<TranslationEngine> engines = const [claude, local],
      ValueChanged<TranslationEngine>? onSelected,
      VoidCallback? onManage,
      double textScale = 1,
      TranslationEngine engine = claude,
    }) => tester.pumpApp(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          appBar: AppBar(
            title: ComposerEngineChip(
              engine: engine,
              engines: engines,
              onSelected: onSelected,
              onManage: onManage,
            ),
          ),
        ),
      ),
    );

    testWidgets('shows the model and its subtitle, named for screen readers', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpChip(tester, onSelected: (_) {});

      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('claude-sonnet'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const Key('composer_engine_chip'))),
        isSemantics(label: 'AI model: Claude', isButton: true),
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip && widget.message == 'Choose the AI model',
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(const Key('composer_engine_chip'))).height,
        greaterThanOrEqualTo(48),
      );
      semantics.dispose();
    });

    testWidgets('drops the subtitle with large text', (tester) async {
      await pumpChip(tester, onSelected: (_) {}, textScale: 1.5);

      expect(find.text('claude-sonnet'), findsNothing);
    });

    testWidgets('marks a local model with its own icon', (tester) async {
      await pumpChip(tester, engine: local, onSelected: (_) {});

      expect(find.byIcon(Icons.memory), findsOneWidget);
    });

    testWidgets('picks another model from its menu', (tester) async {
      TranslationEngine? picked;
      var managed = 0;
      await pumpChip(
        tester,
        onSelected: (engine) => picked = engine,
        onManage: () => managed++,
      );

      await tester.tap(find.byKey(const Key('composer_engine_chip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer_engine:ai:claude')), findsOne);
      expect(find.text('llama3'), findsOneWidget);
      expect(find.text('AI providers'), findsOneWidget);
      await tester.tap(find.byKey(const Key('composer_engine:ai:ollama')));
      await tester.pumpAndSettle();
      expect(picked, local);

      await tester.tap(find.byKey(const Key('composer_engine_chip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('composer_engine_manage')));
      await tester.pumpAndSettle();
      expect(managed, 1);
    });

    testWidgets('only links the provider settings with a single model', (
      tester,
    ) async {
      await pumpChip(
        tester,
        engines: const [claude],
        onSelected: (_) {},
        onManage: () {},
      );

      await tester.tap(find.byKey(const Key('composer_engine_chip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer_engine:ai:claude')), findsNothing);
      expect(find.byKey(const Key('composer_engine_manage')), findsOneWidget);
    });

    testWidgets('is disabled with nothing to offer', (tester) async {
      await pumpChip(tester, engines: const [claude]);

      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('composer_engine_chip')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('closes its open menu when pressed again', (tester) async {
      await pumpChip(tester, onSelected: (_) {});

      await tester.tap(find.byKey(const Key('composer_engine_chip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer_engine:ai:claude')), findsOne);
      final chip = tester.widget<TextButton>(
        find.byKey(const Key('composer_engine_chip')),
      );
      chip.onPressed!();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer_engine:ai:claude')), findsNothing);
    });
  });

  group('ComposerAppBarTitle', () {
    Future<void> pumpTitle(WidgetTester tester, double width, {Widget? chip}) {
      tester.view
        ..physicalSize = Size(width, 600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      return tester.pumpApp(
        Scaffold(
          appBar: AppBar(
            title: ComposerAppBarTitle(title: 'Dictionary', chip: chip),
          ),
        ),
      );
    }

    const chip = SizedBox(key: Key('chip'), width: 120, height: 40);

    testWidgets('is the title alone without a chip', (tester) async {
      await pumpTitle(tester, 400);

      expect(find.text('Dictionary'), findsOneWidget);
    });

    testWidgets('is only the chip on phones', (tester) async {
      await pumpTitle(tester, 400, chip: chip);

      expect(find.text('Dictionary'), findsNothing);
      expect(find.byKey(const Key('chip')), findsOneWidget);
    });

    testWidgets('puts the chip beside the title on large screens', (
      tester,
    ) async {
      await pumpTitle(tester, 1000, chip: chip);

      expect(find.text('Dictionary'), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const Key('chip'))).left,
        greaterThan(tester.getRect(find.text('Dictionary')).right),
      );
    });
  });

  group('ComposerLayout', () {
    Future<void> pumpLayout(
      WidgetTester tester, {
      required bool docked,
      bool wide = false,
      Size size = const Size(400, 800),
    }) {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      return tester.pumpApp(
        Scaffold(
          body: ComposerLayout(
            docked: docked,
            wide: wide,
            hero: const SizedBox(key: Key('hero'), height: 100, width: 100),
            composer: ComposerCard(
              key: const Key('composer'),
              outlined: docked,
              expand: !docked,
              child: const SizedBox(height: 60),
            ),
          ),
        ),
      );
    }

    testWidgets('docks the composer under the greeting', (tester) async {
      await pumpLayout(tester, docked: true);

      final hero = tester.getRect(find.byKey(const Key('hero')));
      final composer = tester.getRect(find.byKey(const Key('composer')));
      expect(hero.bottom, lessThan(composer.top));
      // At the bottom, with a margin.
      expect(composer.bottom, moreOrLessEquals(800 - 12, epsilon: 0.5));
      expect(composer.left, 12);
    });

    testWidgets('lets the composer fill the screen once active', (
      tester,
    ) async {
      await pumpLayout(tester, docked: false);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('hero')), findsNothing);
      final composer = tester.getRect(find.byKey(const Key('composer')));
      expect(composer.top, 0);
      expect(composer.height, 800);
      expect(composer.left, 0);
    });

    testWidgets('centres a narrow card under the greeting on large screens', (
      tester,
    ) async {
      await pumpLayout(
        tester,
        docked: true,
        wide: true,
        size: const Size(1400, 900),
      );

      final hero = tester.getRect(find.byKey(const Key('hero')));
      final composer = tester.getRect(find.byKey(const Key('composer')));
      expect(composer.width, ComposerLayout.maxColumnWidth);
      expect(composer.center.dx, moreOrLessEquals(700, epsilon: 0.5));
      expect(composer.top - hero.bottom, lessThan(20));
      // Above the middle: a spacer under it.
      expect(composer.bottom, lessThan(800));
    });

    test('needs more room for the greeting at larger text', () {
      expect(ComposerLayout.heroMinHeight(1), 420);
      expect(ComposerLayout.heroMinHeight(2), 540);
      expect(ComposerLayout.heroMinHeight(3), 540);
      expect(ComposerLayout.heroMinHeight(0.8), 420);
    });
  });
}
