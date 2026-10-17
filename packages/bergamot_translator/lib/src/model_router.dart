import 'package:bergamot_translator/src/catalog.dart';
import 'package:meta/meta.dart';
import 'package:translation_repository/translation_repository.dart'
    show OfflineTranslator;

/// Maps the app's BCP-47 codes onto the [ModelCatalog]'s Mozilla codes and
/// finds the models for a translation: the direct model when Mozilla has
/// one, otherwise source -> English -> target (all Firefox models are to or
/// from English).
///
/// Mozilla codes are BCP-47 primary subtags except `zh_hant` (Traditional
/// Chinese; reported as `zh-Hant`) and `hbs` (Serbo-Croatian, which only
/// translates *into* English: Croatian, Bosnian and Serbian sources use it).
/// `nb` and `no` are the same Norwegian Bokmål model; `no` is reported.
@immutable
final class ModelRouter {
  new(this.catalog);

  static const english = 'en';

  final ModelCatalog catalog;

  /// Mozilla code -> app code, where they differ.
  static const _reported = {'zh_hant': 'zh-Hant', 'nb': 'no'};

  /// Languages with a model in both directions (plus English): what
  /// [OfflineTranslator.supportedLanguages] reports.
  late final Set<String> languages = Set.unmodifiable(
    sourceLanguages.intersection(targetLanguages),
  );

  /// Languages that can be translated from.
  late final Set<String> sourceLanguages = Set.unmodifiable({
    english,
    for (final model in catalog.models)
      if (model.target == english) ..._reportedAsSource(model.source),
  });

  /// Languages that can be translated into.
  late final Set<String> targetLanguages = Set.unmodifiable({
    english,
    for (final model in catalog.models)
      if (model.source == english) _report(model.target),
  });

  /// The Mozilla code of [code] as a source language, or null when no model
  /// translates from it. `auto`, empty and unknown codes return null.
  String? sourceCode(String code) {
    final key = _modelKey(code);
    if (key == null) return null;
    if (key == english) return english;
    if (catalog.model(key, english) != null) return key;
    if (_serboCroatian.contains(key) && catalog.model(_hbs, english) != null) {
      return _hbs;
    }
    return null;
  }

  /// The Mozilla code of [code] as a target language, or null.
  String? targetCode(String code) {
    final key = _modelKey(code);
    if (key == null) return null;
    if (key == english) return english;
    return catalog.model(english, key) != null ? key : null;
  }

  /// The models that translate [source] into [target] (app codes): one for
  /// a direct pair or a pair with English, two when pivoting through
  /// English, none when both are the same language. Null when either
  /// language has no model.
  List<CatalogModel>? route(String source, String target) {
    final from = sourceCode(source);
    final to = targetCode(target);
    if (from == null || to == null) return null;
    if (from == to || (from == _hbs && _modelKey(target) == _hbs)) {
      return const [];
    }
    final direct = catalog.model(from, to);
    if (direct != null) return [direct];
    final first = catalog.model(from, english);
    final second = catalog.model(english, to);
    if (first == null || second == null) return null;
    return [first, second];
  }

  /// The models that make [code] usable offline (both directions with
  /// English, where Mozilla has them). Empty for English and unknown codes.
  List<CatalogModel> modelsFor(String code) {
    final key = _modelKey(code);
    if (key == null || key == english) return const [];
    final from = sourceCode(code);
    return [
      if (from != null && from != english) catalog.model(from, english)!,
      ?catalog.model(english, key),
    ];
  }

  /// The app code reported for a model's [modelCode].
  static String reportedCode(String modelCode) => _report(modelCode);

  static String _report(String modelCode) => _reported[modelCode] ?? modelCode;

  Iterable<String> _reportedAsSource(String modelCode) => modelCode == _hbs
      ? _serboCroatian.where((code) => catalog.model(english, code) != null)
      : [_report(modelCode)];

  static const _hbs = 'hbs';
  static const _serboCroatian = {'hr', 'bs', 'sr'};

  /// Legacy and alternative primary subtags -> Mozilla codes.
  static const _aliases = {
    'iw': 'he',
    'in': 'id',
    'fil': 'tl',
    'nob': 'nb',
    'no': 'nb',
    'cnr': 'sr',
    'sh': 'hbs',
    'zsm': 'ms',
    'pes': 'fa',
    'arb': 'ar',
    'cmn': 'zh',
    'eng': 'en',
    'deu': 'de',
    'fra': 'fr',
    'spa': 'es',
  };

  static const _traditional = {'hant', 'tw', 'hk', 'mo'};
  static const _excluded = {'auto', 'und', 'zh-yue', 'yue', 'lzh'};

  /// Normalised Mozilla key for an app code: `pt-BR` -> `pt`,
  /// `zh-TW`/`zh-Hant` -> `zh_hant`, `zh-CN`/`zh-Hans` -> `zh`, `iw` ->
  /// `he`, `no` -> `nb`. Null for `auto`, empty and excluded codes.
  static String? _modelKey(String code) {
    final key = code.trim().replaceAll('_', '-').toLowerCase();
    if (key.isEmpty) return null;
    if (_excluded.any((e) => key == e || key.startsWith('$e-'))) return null;
    final parts = key.split('-').where((part) => part.isNotEmpty).toList();
    final primary = _aliases[parts.first] ?? parts.first;
    if (primary == 'zh') {
      return parts.skip(1).any(_traditional.contains) ? 'zh_hant' : 'zh';
    }
    if (primary == 'nb') return 'nb';
    return primary;
  }
}
