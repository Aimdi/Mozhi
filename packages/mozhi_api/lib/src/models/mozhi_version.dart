import 'package:meta/meta.dart';
import 'package:mozhi_api/src/models/json_readers.dart';

/// Result of `GET /api/version`:
/// `{"fiberversion": "v2.52.5", "goversion": "go1.23.1"}`.
@immutable
class MozhiVersion {
  const new({this.fiberVersion = '', this.goVersion = ''});

  factory fromJson(Map<String, dynamic> json) => MozhiVersion(
    fiberVersion: readString(json['fiberversion']),
    goVersion: readString(json['goversion']),
  );

  final String fiberVersion;
  final String goVersion;
}
