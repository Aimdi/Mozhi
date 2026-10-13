import 'package:meta/meta.dart';

/// A language supported by a Mozhi engine.
///
/// JSON shape (Go struct without tags): `{"Name": "English", "Id": "en"}`.
/// The id `auto` means "detect language" and only appears in source lists.
@immutable
class MozhiLanguage {
  const new({required this.id, required this.name});

  factory fromJson(Map<String, dynamic> json) => MozhiLanguage(
    id: (json['Id'] ?? json['id'] ?? '') as String,
    name: (json['Name'] ?? json['name'] ?? '') as String,
  );

  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'Id': id, 'Name': name};

  @override
  bool operator ==(Object other) =>
      other is MozhiLanguage && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'MozhiLanguage($id, $name)';
}
