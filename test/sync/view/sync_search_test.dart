import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mozhi/settings/models/app_settings.dart';
import 'package:mozhi/settings/models/settings_category.dart';
import 'package:mozhi/settings/view/categories/backup_settings.dart';
import 'package:mozhi/settings/view/settings_search_index.dart';
import 'package:mozhi/settings/view/widgets/settings_search.dart';
import 'package:mozhi/sync/view/sync_settings_section.dart';

import '../../helpers/helpers.dart';
import '../helpers/sync_harness.dart';

void main() {
  testWidgets('the settings search finds sync in Backup & sync', (
    tester,
  ) async {
    final harness = SyncHarness();
    late List<SettingsSearchEntry> entries;
    await tester.pumpApp(
      harness.wrap(
        Builder(
          builder: (context) {
            entries = settingsSearchIndex(context, const AppSettings());
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final sync = entries.singleWhere((e) => e.anchor == SyncAnchors.sync);
    expect(sync.category, SettingsCategory.backup);
    expect(sync.title, 'Sync');
    expect(sync.matches('nextcloud'), isTrue);
    expect(sync.matches('turn off sync'), isTrue);
  });

  testWidgets('without a sync service it is not listed', (tester) async {
    late List<SettingsSearchEntry> entries;
    await tester.pumpApp(
      Builder(
        builder: (context) {
          entries = settingsSearchIndex(context, const AppSettings());
          return const SizedBox.shrink();
        },
      ),
    );
    expect(entries.where((e) => e.anchor == SyncAnchors.sync), isEmpty);
  });

  testWidgets('Backup & sync shows the sync section under its anchor', (
    tester,
  ) async {
    final harness = SyncHarness();
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpApp(
      harness.wrap(
        const Scaffold(
          body: SingleChildScrollView(
            child: BackupSettings(settings: AppSettings()),
          ),
        ),
      ),
    );
    await tester.runAsync(harness.service.load);
    await tester.pump();
    expect(
      find.byKey(SettingsAnchor.highlightKey(SyncAnchors.sync)),
      findsOneWidget,
    );
    expect(find.byKey(const Key('sync_set_up')), findsOneWidget);
  });
}
