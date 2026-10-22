import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/backup/models/backup_section.dart';
import 'package:mozhi/practice/data/fsrs.dart';
import 'package:mozhi/practice/data/practice_backup_section.dart';
import 'package:mozhi/practice/data/practice_repository.dart';

import '../helpers.dart';

void main() {
  group(PracticeBackupSection, () {
    test('exports, counts and restores the progress', () async {
      final fixture = PracticeFixture(favorites: [favorite('1')]);
      final card = (await fixture.practice.deck(appLanguage: 'en'))
          .items
          .first
          .card;
      final now = fixture.clock.now;
      await fixture.practice.saveCard(
        card.reviewed(
          FsrsRating.good,
          FsrsScheduler().review(card.fsrs, FsrsRating.good, now),
          now,
        ),
      );
      final section = PracticeBackupSection(fixture.practice);
      expect(section.id, 'practice');
      expect(PracticeBackupSection.sectionId, 'practice');
      expect(section.version, PracticeRepository.backupVersion);
      final data = await section.export(includeSecrets: true);
      expect(section.countItems(data, version: 1), 1);
      expect(await section.countLocalItems(), 1);

      final other = PracticeFixture();
      final restored = PracticeBackupSection(other.practice);
      await restored.restore(data, version: 1, mode: BackupRestoreMode.merge);
      expect(await other.practice.reviewedCount(), 1);
      await restored.restore(
        {'cards': <Object?>[]},
        version: 1,
        mode: BackupRestoreMode.replace,
      );
      expect(await other.practice.reviewedCount(), 0);
      await expectLater(
        restored.restore(data, version: 9, mode: BackupRestoreMode.replace),
        throwsFormatException,
      );
    });
  });
}
