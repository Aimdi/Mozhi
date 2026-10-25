import 'package:mozhi/documents/core/parsers/json_parser.dart'
    show DocumentParseException;

/// Why a ZIP-packaged document cannot be read.
enum PackageProblem {
  /// Not a ZIP package of the expected kind, a damaged ZIP or malformed
  /// XML (also old binary Office files with a new extension).
  damaged,

  /// Protected with a password, or an e-book with DRM.
  encrypted,

  /// Refused to protect the device: a decompression bomb, too many
  /// entries, entry names that leave the package, nesting that is too
  /// deep or document type declarations.
  unsafe,
}

/// A [DocumentParseException] for ZIP packages that says why the package
/// was refused.
class PackageParseException extends DocumentParseException {
  const new(this.problem, super.message);

  final PackageProblem problem;

  @override
  String toString() => 'PackageParseException(${problem.name}): $message';
}
