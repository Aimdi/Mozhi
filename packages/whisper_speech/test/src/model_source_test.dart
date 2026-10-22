import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_speech/whisper_speech.dart';

void main() {
  final model = WhisperCatalogModel(
    id: 'tiny',
    name: 'ggml-tiny.bin',
    url: Uri.parse(
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin',
    ),
    size: 10,
    sha1: 'a' * 40,
  );

  group(whisperMirrorUrl, () {
    test('puts the file under whisper/ with its published name', () {
      for (final base in [
        'https://example.org/models/',
        'https://example.org/models',
      ]) {
        expect(
          whisperMirrorUrl(Uri.parse(base), model).toString(),
          'https://example.org/models/whisper/ggml-tiny.bin',
          reason: base,
        );
      }
      expect(
        whisperMirrorUrl(Uri.parse('http://[::1]:8080'), model).toString(),
        'http://[::1]:8080/whisper/ggml-tiny.bin',
      );
    });

    test('rejects what is not an http(s) base URL', () {
      for (final base in [
        'file:///models/',
        'models/',
        'https://example.org/?x=1',
        'https://example.org/#x',
      ]) {
        expect(
          () => whisperMirrorUrl(Uri.parse(base), model),
          throwsArgumentError,
          reason: base,
        );
      }
    });
  });

  test('rejects an unsafe file name', () {
    final unsafe = WhisperCatalogModel(
      id: 'x',
      name: '..',
      url: model.url,
      size: 1,
      sha1: 'a' * 40,
    );
    expect(
      () => whisperMirrorUrl(Uri.parse('https://m.example/'), unsafe),
      throwsArgumentError,
    );
  });

  group(whisperDownloadUrls, () {
    final mirror = Uri.parse('https://mirror.example/');
    final copy = whisperMirrorUrl(mirror, model);

    test('is the catalog URL without a mirror', () {
      expect(whisperDownloadUrls(model), [model.url]);
      expect(whisperDownloadUrls(model, fallbackToDefault: true), [model.url]);
    });

    test('is the mirror copy, then the catalog URL with the fallback', () {
      expect(whisperDownloadUrls(model, mirror: mirror), [copy]);
      expect(
        whisperDownloadUrls(model, mirror: mirror, fallbackToDefault: true),
        [copy, model.url],
      );
    });
  });

  test('the mirror folder', () => expect(whisperMirrorFolder, 'whisper'));
}
