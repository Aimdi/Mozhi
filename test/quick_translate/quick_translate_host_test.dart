import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/l10n/l10n.dart';
import 'package:mozhi/quick_translate/quick_translate_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(QuickTranslateHost.channelName);
  late List<MethodCall> calls;

  void answer(Future<Object?> Function(MethodCall call) handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            calls.add(call);
            return handler(call);
          });

  setUp(() {
    calls = [];
    answer((_) async => null);
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  QuickTranslateHost host(String route) =>
      QuickTranslateHost(initialRoute: () => route);

  test('is active only when started at its route', () {
    expect(host(QuickTranslateHost.location).isActive, isTrue);
    expect(host('${QuickTranslateHost.location}?x=1').isActive, isTrue);
    expect(host('/').isActive, isFalse);
    expect(host('/translate').isActive, isFalse);
    expect(host('::').isActive, isFalse);
    // The app's own window by default.
    expect(QuickTranslateHost().isActive, isFalse);
    expect(QuickTranslateHost.instance.isActive, isFalse);
  });

  test('asks the window to close and to open the app', () async {
    final window = host(QuickTranslateHost.location);

    await window.close();
    await window.openTextInApp('hola');
    await window.openLocationInApp('/settings/offline');

    expect(calls.map((c) => c.method), ['close', 'openInApp', 'openInApp']);
    expect(calls[1].arguments, {'text': 'hola'});
    expect(calls[2].arguments, {'location': '/settings/offline'});
  });

  test('does nothing in the main window', () async {
    final window = host('/');
    await window.close();
    await window.openTextInApp('hola');
    expect(calls, isEmpty);
  });

  test('ignores a missing or closing window', () async {
    final window = host(QuickTranslateHost.location);
    answer((_) async => throw PlatformException(code: 'gone'));
    await window.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await window.openTextInApp('hola');
    expect(calls, hasLength(1));
  });

  testWidgets('its page is transparent and named', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        home: QuickTranslateHostView(),
      ),
    );

    expect(find.bySemanticsLabel('Quick translate'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(QuickTranslateHostView),
        matching: find.byType(Material),
      ),
      findsNothing,
    );
    handle.dispose();
  });
}
