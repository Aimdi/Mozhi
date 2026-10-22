import 'package:equatable/equatable.dart';
import 'package:mozhi/pairing/protocol/pairing_exception.dart';

/// What a phone can send: its data (a backup snapshot) or one kind of
/// offline files.
enum PairingItemKind {
  /// Settings, history and the other backup sections (`BackupRegistry`).
  data,

  /// The on-device translation models of one language (both directions).
  translation,

  /// A Whisper speech model, or the speech detector.
  speech,

  /// The text recognition data of one language (Tesseract).
  ocr,

  /// An offline dictionary pack.
  dictionary;

  /// The kind called [name]; null for any other name.
  static PairingItemKind? tryParse(Object? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// One file of a [PairingItem]: its [name] (unique in the item, at most
/// one `/`), [size] and, when the sender knows them, its hashes (lower-case
/// hex). The receiver checks every file against its own catalogue, so
/// these are only hints for what to ask for.
class PairingFile extends Equatable {
  const new({required this.name, required this.size, this.sha256, this.sha1});

  /// Reads [toJson] output; throws [PairingProtocolException] for anything
  /// else.
  factory fromJson(Object? json) {
    if (json is! Map<String, Object?>) throw _invalid('file');
    final name = json['name'];
    final size = json['size'];
    final sha256 = json['sha256'];
    final sha1 = json['sha1'];
    if (name is! String || !isValidName(name)) throw _invalid('file name');
    if (size is! int || size < 0 || size > maxSize) throw _invalid('size');
    if (sha256 != null && (sha256 is! String || !_sha256.hasMatch(sha256))) {
      throw _invalid('SHA-256');
    }
    if (sha1 != null && (sha1 is! String || !_sha1.hasMatch(sha1))) {
      throw _invalid('SHA-1');
    }
    return PairingFile(
      name: name,
      size: size,
      sha256: sha256 as String?,
      sha1: sha1 as String?,
    );
  }

  /// The largest file pairing carries (4 GiB).
  static const int maxSize = 1 << 32;

  final String name;
  final int size;
  final String? sha256;
  final String? sha1;

  /// Whether [name] is a file name pairing accepts: one or two segments of
  /// letters, digits, `.`, `_` and `-`, none starting with a dot.
  static bool isValidName(String name) => _name.hasMatch(name);

  Map<String, Object?> toJson() => {
    'name': name,
    'size': size,
    'sha256': ?sha256,
    'sha1': ?sha1,
  };

  @override
  List<Object?> get props => [name, size, sha256, sha1];

  static final _name = RegExp(
    r'^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}(/[A-Za-z0-9_-][A-Za-z0-9._-]{0,127})?$',
  );
  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static final _sha1 = RegExp(r'^[0-9a-f]{40}$');
}

/// One thing offered by the sending phone: its [kind], a [key] that names
/// it within the kind (a language code, a model or pack id; `backup` for
/// the data) and its [files]. A data item also lists the backup
/// [sections] it holds and whether it holds [secrets] (API keys,
/// passwords).
class PairingItem extends Equatable {
  const new({
    required this.kind,
    required this.key,
    required this.files,
    this.sections = const [],
    this.secrets = false,
  });

  /// Reads [toJson] output; throws [PairingProtocolException] for anything
  /// else (an unknown kind, an invalid key or file, too many files,
  /// duplicate names).
  factory fromJson(Object? json) {
    if (json is! Map<String, Object?>) throw _invalid('item');
    final kind = PairingItemKind.tryParse(json['kind']);
    final key = json['key'];
    final files = json['files'];
    final sections = json['sections'] ?? const <Object?>[];
    final secrets = json['secrets'] ?? false;
    if (kind == null) throw _invalid('kind');
    if (key is! String || !_key.hasMatch(key)) throw _invalid('key');
    if (files is! List<Object?> || files.length > maxFiles) {
      throw _invalid('files');
    }
    if (sections is! List<Object?> ||
        sections.length > maxSections ||
        sections.any((id) => id is! String || !_key.hasMatch(id))) {
      throw _invalid('sections');
    }
    if (secrets is! bool) throw _invalid('secrets');
    final parsed = [for (final file in files) PairingFile.fromJson(file)];
    if ({for (final file in parsed) file.name}.length != parsed.length) {
      throw _invalid('duplicate file');
    }
    return PairingItem(
      kind: kind,
      key: key,
      files: List.unmodifiable(parsed),
      sections: List.unmodifiable(sections.cast<String>()),
      secrets: secrets,
    );
  }

  /// Most files one item may have.
  static const maxFiles = 32;

  /// Most backup sections a data item may list.
  static const maxSections = 64;

  final PairingItemKind kind;
  final String key;
  final List<PairingFile> files;
  final List<String> sections;
  final bool secrets;

  /// Unique in an offer: `<kind>:<key>`.
  String get id => '${kind.name}:$key';

  /// Bytes of all [files].
  int get size => files.fold(0, (sum, file) => sum + file.size);

  /// The file called [name], if any.
  PairingFile? file(String name) {
    for (final file in files) {
      if (file.name == name) return file;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'key': key,
    'files': [for (final file in files) file.toJson()],
    if (sections.isNotEmpty) 'sections': sections,
    if (secrets) 'secrets': true,
  };

  @override
  List<Object?> get props => [kind, key, files, sections, secrets];

  @override
  String toString() => 'PairingItem($id)';

  static final _key = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
}

/// What the receiving phone makes of an offered item.
enum PairingItemStatus {
  /// It can take the item: [PairingPlan.files] are what it needs.
  available,

  /// Everything of the item is on this phone already.
  installed,

  /// This phone's catalogue does not have these files (another version of
  /// Mozhi), or cannot take this kind of item.
  incompatible,
}

/// How the receiving phone would take an offered item: its [status] and,
/// when it is available, the [files] it needs, as its own catalogue lists
/// them (size and hashes it checks).
class PairingPlan extends Equatable {
  const new available(this.files, {this.language})
    : status = PairingItemStatus.available;

  const new installed({this.language})
    : status = PairingItemStatus.installed,
      files = const [];

  const new incompatible()
    : status = PairingItemStatus.incompatible,
      files = const [],
      language = null;

  final PairingItemStatus status;
  final List<PairingFile> files;

  /// The app language the item is for, as this phone's catalogue says
  /// (for its name on the screen); null when it is not a language's.
  final String? language;

  /// Bytes of [files].
  int get size => files.fold(0, (sum, file) => sum + file.size);

  @override
  List<Object?> get props => [status, files, language];
}

/// What became of one item the receiving phone accepted.
enum PairingItemOutcome {
  /// Installed or restored.
  installed,

  /// A file did not match this phone's catalogue (or the backup was not a
  /// valid one); nothing of the item was installed.
  damaged,

  /// The phone ran out of storage space.
  noSpace,

  /// This phone cannot use it (another version of Mozhi).
  incompatible,

  /// Installing failed otherwise.
  failed;

  /// The outcome called [name]; null for any other name.
  static PairingItemOutcome? tryParse(Object? name) {
    for (final outcome in values) {
      if (outcome.name == name) return outcome;
    }
    return null;
  }
}

/// The [outcome] of the item [id] ([PairingItem.id]).
class PairingItemResult extends Equatable {
  const new(this.id, this.outcome);

  final String id;
  final PairingItemOutcome outcome;

  @override
  List<Object?> get props => [id, outcome];
}

PairingProtocolException _invalid(String what) =>
    PairingProtocolException('Invalid $what');
