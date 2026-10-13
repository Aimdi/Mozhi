import 'package:meta/meta.dart';

/// A selectable language.
///
/// [code] is an engine/BCP-47-ish code (`en`, `pt-BR`, `zh-CN`, `auto`).
/// For AI engines the target may also be a *custom* free-form "language"
/// such as `Pirate speak` or `LinkedIn Speak`; then [isCustom] is true and
/// [code] equals [name].
@immutable
class Language {
  const new({
    required this.code,
    required this.name,
    this.nativeName,
    this.isCustom = false,
  });

  factory fromJson(Map<String, dynamic> json) => Language(
    code: json['code'] as String,
    name: json['name'] as String,
    nativeName: json['nativeName'] as String?,
    isCustom: json['isCustom'] as bool? ?? false,
  );

  /// A custom free-form target (AI engines only).
  const new custom(String text)
    : code = text,
      name = text,
      nativeName = null,
      isCustom = true;

  /// The "Detect language" pseudo language.
  static const auto = Language(code: 'auto', name: 'Detect language');

  final String code;
  final String name;
  final String? nativeName;
  final bool isCustom;

  bool get isAuto => code == 'auto';

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    if (nativeName != null) 'nativeName': nativeName,
    if (isCustom) 'isCustom': true,
  };

  @override
  bool operator ==(Object other) =>
      other is Language && other.code == code && other.isCustom == isCustom;

  @override
  int get hashCode => Object.hash(code, isCustom);

  @override
  String toString() => 'Language($code)';
}
