import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/platform/download_foreground_service.dart';

final class _FakeDownloadForegroundService
    implements DownloadForegroundService {
  final List<String> events = [];
  final StreamController<void> _cancels = StreamController<void>.broadcast();

  @override
  Stream<void> get cancelRequests => _cancels.stream;

  void triggerCancel() => _cancels.add(null);

  @override
  Future<void> start({required String title, int? progress}) async {
    events.add('start:$title:$progress');
  }

  @override
  Future<void> update({required String title, int? progress}) async {
    events.add('update:$title:$progress');
  }

  @override
  Future<void> stop() async {
    events.add('stop');
  }

  Future<void> dispose() => _cancels.close();
}

void main() {
  group('DownloadForegroundCoordinator', () {
    late _FakeDownloadForegroundService service;
    late DownloadForegroundCoordinator coordinator;

    setUp(() {
      service = _FakeDownloadForegroundService();
      coordinator = DownloadForegroundCoordinator(service: service);
    });

    tearDown(() async {
      await coordinator.dispose();
      await service.dispose();
    });

    test('starts, throttles progress updates and stops', () async {
      final result = await coordinator.track<String>(
        label: 'Gemma 4',
        run: (report) async {
          report(0.101);
          report(0.109); // Same whole percent -> ignored
          report(0.55);
          return 'ok';
        },
      );
      expect(result, 'ok');
      expect(coordinator.activeCount, 0);
      expect(service.events, [
        'start:Gemma 4:null',
        'update:Gemma 4:10',
        'update:Gemma 4:55',
        'stop',
      ]);
    });

    test('reference-counts overlapping downloads', () async {
      final firstDone = Completer<void>();
      final secondDone = Completer<void>();

      final first = coordinator.track<void>(
        label: 'Model A',
        run: (report) async {
          report(0.5);
          await firstDone.future;
        },
      );
      final second = coordinator.track<void>(
        label: 'Model B',
        run: (report) async {
          report(0.5);
          await secondDone.future;
        },
      );

      expect(coordinator.activeCount, 2);
      expect(service.events.first, 'start:Model A:null');
      expect(service.events, contains('update:Model A (+1):50'));

      firstDone.complete();
      await first;
      expect(coordinator.activeCount, 1);
      expect(service.events.last, isNot('stop'));

      secondDone.complete();
      await second;
      expect(coordinator.activeCount, 0);
      expect(service.events.last, 'stop');
    });

    test('routes notification cancel to active downloads', () async {
      var cancelled = false;
      final blocker = Completer<void>();
      final running = coordinator.track<void>(
        label: 'Whisper Small',
        onCancel: () async {
          cancelled = true;
          if (!blocker.isCompleted) blocker.complete();
        },
        run: (_) => blocker.future,
      );

      service.triggerCancel();
      await running;
      expect(cancelled, isTrue);
      expect(service.events.last, 'stop');
    });
  });

  group('Android ModelDownloadService wiring', () {
    test('declares dataSync foreground service and plugin registration', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(
        manifest,
        contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
      );
      expect(manifest, contains('android:name=".ModelDownloadService"'));
      expect(manifest, contains('android:foregroundServiceType="dataSync"'));

      final mainActivity = File(
        'android/app/src/main/kotlin/io/github/aimdi/mozhi/MainActivity.kt',
      ).readAsStringSync();
      expect(mainActivity, contains('ModelDownloadPlugin()'));

      final plugin = File(
        'android/app/src/main/kotlin/io/github/aimdi/mozhi/ModelDownloadPlugin.kt',
      ).readAsStringSync();
      expect(
        plugin,
        contains(MethodChannelDownloadForegroundService.channelName),
      );
    });
  });
}
