import 'dart:async';

import 'package:mlkit_translator/mlkit_translator.dart';

/// In-memory [MlKitBindings] that records every call.
class FakeBindings implements MlKitBindings {
  new({Set<String>? downloaded}) : downloaded = {...?downloaded};

  /// Models "on the device".
  final Set<String> downloaded;

  /// Every call as `method:args`, in order.
  final List<String> calls = [];

  final List<FakeTextTranslator> translators = [];
  final List<FakeLanguageIdentifier> identifiers = [];

  bool downloadResult = true;
  bool deleteResult = true;
  String identified = 'en';

  /// When set, translators wait for this before answering.
  Completer<void>? translateGate;

  /// When set, `close` of translators and identifiers throws it.
  Exception? closeError;

  @override
  Future<bool> isModelDownloaded(String code) async {
    calls.add('check:$code');
    return downloaded.contains(code);
  }

  @override
  Future<bool> downloadModel(String code, {required bool wifiRequired}) async {
    calls.add('download:$code:wifi=$wifiRequired');
    if (downloadResult) downloaded.add(code);
    return downloadResult;
  }

  @override
  Future<bool> deleteModel(String code) async {
    calls.add('delete:$code');
    if (deleteResult) downloaded.remove(code);
    return deleteResult;
  }

  @override
  FakeTextTranslator createTranslator({
    required String source,
    required String target,
  }) {
    calls.add('create:$source>$target');
    final translator = FakeTextTranslator(source, target, this);
    translators.add(translator);
    return translator;
  }

  @override
  FakeLanguageIdentifier createLanguageIdentifier({
    required double confidenceThreshold,
  }) {
    calls.add('identifier:$confidenceThreshold');
    final identifier = FakeLanguageIdentifier(this);
    identifiers.add(identifier);
    return identifier;
  }
}

class FakeTextTranslator implements MlKitTextTranslator {
  new(this.source, this.target, this._bindings);

  final String source;
  final String target;
  final FakeBindings _bindings;
  final List<String> texts = [];
  bool closed = false;

  @override
  Future<String> translate(String text) async {
    texts.add(text);
    await _bindings.translateGate?.future;
    return '[$source>$target] $text';
  }

  @override
  Future<void> close() async {
    closed = true;
    final error = _bindings.closeError;
    if (error != null) throw error;
  }
}

class FakeLanguageIdentifier implements MlKitLanguageIdentifier {
  new(this._bindings);

  final FakeBindings _bindings;
  final List<String> texts = [];
  bool closed = false;

  @override
  Future<String> identify(String text) async {
    texts.add(text);
    return _bindings.identified;
  }

  @override
  Future<void> close() async {
    closed = true;
    final error = _bindings.closeError;
    if (error != null) throw error;
  }
}
