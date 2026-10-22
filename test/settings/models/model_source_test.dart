import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/settings/models/model_source.dart';
import 'package:mozhi/settings/models/web_base_url.dart';

void main() {
  group(ModelSource, () {
    test('defaults to the original publishers outside a browser', () {
      expect(ModelSource.platformDefault, ModelSource.defaultHosts);
      expect(ModelSource.defaultHosts.mirror(), isNull);
      expect(ModelSource.defaultHosts.usesMirror, isFalse);
      expect(
        const ModelSource(fallbackToDefault: true).fallsBackToDefault,
        isFalse,
      );
    });

    test('a custom mirror is its normalised URL', () {
      const source = ModelSource(
        kind: ModelSourceKind.custom,
        customUrl: 'https://example.org/models/',
        fallbackToDefault: true,
      );
      expect(source.mirror(), Uri.parse('https://example.org/models/'));
      expect(source.usesMirror, isTrue);
      expect(source.fallsBackToDefault, isTrue);
      expect(const ModelSource(kind: ModelSourceKind.custom).mirror(), isNull);
    });

    test('this web server is models/ next to the web app', () {
      const source = ModelSource(kind: ModelSourceKind.thisServer);
      expect(
        source.mirror(appBase: Uri.parse('https://mozhi.example/app/')),
        Uri.parse('https://mozhi.example/app/models/'),
      );
      expect(
        source.mirror(
          appBase: Uri.parse('https://mozhi.example/index.html?x=1#/settings'),
        ),
        Uri.parse('https://mozhi.example/models/'),
      );
      // Outside a browser there is no such server.
      expect(webAppBaseUrl(), isNull);
      expect(source.mirror(), isNull);
      expect(source.mirror(appBase: Uri.parse('file:///app/')), isNull);
    });

    group('normalizeMirrorUrl', () {
      test('adds https:// and a trailing slash', () {
        expect(
          ModelSource.normalizeMirrorUrl(' example.org/models ').toString(),
          'https://example.org/models/',
        );
        expect(
          ModelSource.normalizeMirrorUrl('http://192.168.1.10:8080').toString(),
          'http://192.168.1.10:8080/',
        );
        expect(
          ModelSource.normalizeMirrorUrl('http://abc.onion/m/').toString(),
          'http://abc.onion/m/',
        );
      });

      test('is null for an address that is not accepted', () {
        for (final text in [
          '',
          'not a url',
          'ftp://example.org/',
          'http://example.org/models/',
          'https://user:pw@example.org/',
          'https://example.org/?key=1',
        ]) {
          expect(ModelSource.normalizeMirrorUrl(text), isNull, reason: text);
        }
      });
    });

    test('mirrorUrlProblem says why an address is refused', () {
      expect(ModelSource.mirrorUrlProblem('https://example.org/'), isNull);
      expect(ModelSource.mirrorUrlProblem('http://localhost:8000/'), isNull);
      expect(
        ModelSource.mirrorUrlProblem('https://'),
        ModelMirrorUrlProblem.invalid,
      );
      expect(
        ModelSource.mirrorUrlProblem('wss://example.org/'),
        ModelMirrorUrlProblem.invalid,
      );
      expect(
        ModelSource.mirrorUrlProblem('https://me@example.org/'),
        ModelMirrorUrlProblem.credentials,
      );
      expect(
        ModelSource.mirrorUrlProblem('https://example.org/#top'),
        ModelMirrorUrlProblem.query,
      );
      expect(
        ModelSource.mirrorUrlProblem('http://example.org/'),
        ModelMirrorUrlProblem.cleartext,
      );
    });

    group('JSON', () {
      test('round-trips', () {
        const sources = [
          ModelSource.defaultHosts,
          ModelSource(
            kind: ModelSourceKind.custom,
            customUrl: 'https://example.org/models/',
            fallbackToDefault: true,
          ),
          ModelSource(customUrl: 'https://example.org/models/'),
        ];
        for (final source in sources) {
          expect(ModelSource.fromJson(source.toJson()), source);
        }
        expect(ModelSource.defaultHosts.toJson(), {
          'kind': 'defaultHosts',
          'fallback': false,
        });
      });

      test('normalises the stored URL', () {
        expect(
          ModelSource.fromJson(const {'kind': 'custom', 'url': 'example.org'}),
          const ModelSource(
            kind: ModelSourceKind.custom,
            customUrl: 'https://example.org/',
          ),
        );
      });

      test('falls back to the platform default for what it cannot use', () {
        for (final json in <Map<String, dynamic>>[
          {},
          {'kind': 'nonsense'},
          {'kind': 'custom'},
          {'kind': 'custom', 'url': 'http://example.org/'},
          {'kind': 'custom', 'url': 3},
          // Only a web app has a server it came from.
          {'kind': 'thisServer'},
        ]) {
          expect(
            ModelSource.fromJson(json),
            ModelSource.platformDefault,
            reason: '$json',
          );
        }
      });
    });

    test('copyWith', () {
      const source = ModelSource(customUrl: 'https://a.example/');
      expect(source.copyWith(), source);
      expect(
        source.copyWith(
          kind: ModelSourceKind.custom,
          customUrl: 'https://b.example/',
          fallbackToDefault: true,
        ),
        const ModelSource(
          kind: ModelSourceKind.custom,
          customUrl: 'https://b.example/',
          fallbackToDefault: true,
        ),
      );
    });
  });
}
