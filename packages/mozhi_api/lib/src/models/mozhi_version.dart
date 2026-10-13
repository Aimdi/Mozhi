import 'package:meta/meta.dart';

/// Result of `GET /api/version`:
/// `{"fiberversion": "v2.52.5", "goversion": "go1.23.1"}`.
@immutable
class MozhiVersion {
  const new({this.fiberVersion = '', this.goVersion = ''});

  factory fromJson(Map<String, dynamic> json) => MozhiVersion(
    fiberVersion: (json['fiberversion'] ?? '') as String,
    goVersion: (json['goversion'] ?? '') as String,
  );

  final String fiberVersion;
  final String goVersion;
}
