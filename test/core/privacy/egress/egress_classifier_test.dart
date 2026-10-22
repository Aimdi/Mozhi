import 'package:flutter_test/flutter_test.dart';
import 'package:mozhi/core/privacy/egress/egress.dart';

const _gemini =
    'https://generativelanguage.googleapis.com/v1beta/models/gemini:'
    'streamGenerateContent?alt=sse';

void main() {
  const classifier = EgressClassifier();

  EgressPurpose purposeOf(String url, [String method = 'GET']) =>
      classifier.purposeOf(Uri.parse(url), method: method);

  group('purposeOf', () {
    test('knows the endpoints of the backends', () {
      expect(
        purposeOf('https://mozhi.example/api/translate', 'POST'),
        EgressPurpose.translation,
      );
      expect(
        purposeOf('https://lt.example/detect', 'POST'),
        EgressPurpose.translation,
      );
      expect(
        purposeOf('https://api.deepl.com/v2/translate', 'POST'),
        EgressPurpose.translation,
      );
      expect(
        purposeOf('https://mozhi.example/api/tts?text=hola&lang=es'),
        EgressPurpose.speech,
      );
      expect(
        purposeOf('https://mozhi.example/api/image', 'POST'),
        EgressPurpose.image,
      );
      for (final url in [
        'https://api.openai.com/v1/chat/completions',
        'https://api.anthropic.com/v1/messages',
        'http://localhost:11434/api/chat',
        _gemini,
      ]) {
        expect(purposeOf(url, 'POST'), EgressPurpose.aiModel, reason: url);
      }
      for (final url in [
        'https://api.openai.com/v1/models',
        'http://localhost:11434/api/tags',
        'https://mozhi.example/api/engines',
        'https://mozhi.example/api/version',
        'https://lt.example/languages',
        'https://lt.example/frontend/settings',
        'https://api.deepl.com/v2/usage',
        'https://generativelanguage.googleapis.com/v1beta/models/gemini',
      ]) {
        expect(purposeOf(url), EgressPurpose.catalog, reason: url);
      }
    });

    test('glossaries carry content only when written', () {
      expect(
        purposeOf('https://api.deepl.com/v3/glossaries', 'POST'),
        EgressPurpose.translation,
      );
      expect(
        purposeOf('https://api.deepl.com/v3/glossaries'),
        EgressPurpose.catalog,
      );
    });

    test('model hosts are model downloads, whatever the path', () {
      for (final url in [
        'https://storage.googleapis.com/moz-fx-translations-data/models/a.gz',
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/x.bin',
        'https://cdn-lfs.huggingface.co/repos/x',
        'https://raw.githubusercontent.com/tesseract-ocr/tessdata/eng.traineddata',
        'https://github.com/tesseract-ocr/tessdata/raw/main/deu.traineddata',
      ]) {
        expect(purposeOf(url), EgressPurpose.modelDownload, reason: url);
      }
    });

    test('anything else is another request', () {
      expect(purposeOf('https://example.org/'), EgressPurpose.other);
    });
  });

  group('destinationOf', () {
    EgressDestination of(
      String url, [
      EgressPurpose purpose = EgressPurpose.translation,
    ]) => classifier.destinationOf(Uri.parse(url), purpose);

    test('this device, the local network and Tor/I2P', () {
      expect(
        of('http://localhost:11434/api/chat').kind,
        EgressDestinationKind.thisDevice,
      );
      expect(
        of('http://127.0.0.1:8080/').kind,
        EgressDestinationKind.thisDevice,
      );
      expect(of('http://[::1]:3000/').host, '::1');
      expect(of('http://[::1]:3000/').kind, EgressDestinationKind.thisDevice);
      expect(
        of('http://192.168.1.10:3000/api/translate'),
        const EgressDestination(
          kind: EgressDestinationKind.localNetwork,
          host: '192.168.1.10',
          port: 3000,
        ),
      );
      expect(
        of('http://mozhi.local/').kind,
        EgressDestinationKind.localNetwork,
      );
      expect(
        of('http://abcdef.onion/').kind,
        EgressDestinationKind.hiddenService,
      );
      expect(of('http://mozhi.i2p/').kind, EgressDestinationKind.hiddenService);
    });

    test('names known cloud providers, subdomains included', () {
      expect(
        of('https://api.openai.com/v1/chat/completions'),
        const EgressDestination(
          kind: EgressDestinationKind.cloudProvider,
          host: 'api.openai.com',
          name: 'OpenAI',
        ),
      );
      expect(of('https://my.openai.azure.com/x').name, 'Azure OpenAI');
      expect(
        of('https://API.Anthropic.com./v1/messages').host,
        'api.anthropic.com',
      );
      expect(of('https://api-free.deepl.com/v2/translate').name, 'DeepL');
    });

    test('model hosts, websites and public servers', () {
      expect(
        of('https://huggingface.co/x.bin', EgressPurpose.modelDownload),
        const EgressDestination(
          kind: EgressDestinationKind.modelHost,
          host: 'huggingface.co',
          name: 'Hugging Face',
        ),
      );
      expect(
        of('https://news.example/a', EgressPurpose.webPage).kind,
        EgressDestinationKind.website,
      );
      expect(
        of('https://mozhi.example:8443/api/translate'),
        const EgressDestination(
          kind: EgressDestinationKind.publicServer,
          host: 'mozhi.example',
          port: 8443,
        ),
      );
      // A default port is not shown.
      expect(of('https://mozhi.example:443/').port, isNull);
      expect(of('http://192.168.1.2:80/').port, isNull);
    });

    test('a website on the local network is still the local network', () {
      expect(
        of('http://192.168.1.1/', EgressPurpose.webPage).kind,
        EgressDestinationKind.localNetwork,
      );
    });
  });

  test('classify combines both and honours a given purpose', () {
    final (destination, purpose) = classifier.classify(
      Uri.parse('https://example.org/api/translate'),
      method: 'POST',
      purpose: EgressPurpose.webPage,
    );
    expect(purpose, EgressPurpose.webPage);
    expect(destination.kind, EgressDestinationKind.website);
    expect(
      classifier.classify(Uri.parse('https://mozhi.example/api/engines')).$2,
      EgressPurpose.catalog,
    );
  });

  test('normalizeHost and isLoopback', () {
    expect(EgressClassifier.normalizeHost(' Example.ORG. '), 'example.org');
    expect(EgressClassifier.normalizeHost('[::1]'), '::1');
    expect(EgressClassifier.isLoopback('LOCALHOST'), isTrue);
    expect(EgressClassifier.isLoopback('app.localhost'), isTrue);
    expect(EgressClassifier.isLoopback('127.0.0.2'), isTrue);
    expect(EgressClassifier.isLoopback('0:0:0:0:0:0:0:1'), isTrue);
    expect(EgressClassifier.isLoopback('192.168.1.2'), isFalse);
  });
}
