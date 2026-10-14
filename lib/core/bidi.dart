/// [text] as a bidirectional isolate (FIRST STRONG ISOLATE … POP
/// DIRECTIONAL ISOLATE): it takes the direction of its own first strong
/// character and does not affect the order of the text around it.
///
/// Use it for names interpolated into localized strings, e.g. Latin-script
/// language names inside an Arabic "{source} ← {target}" label, so the
/// arrow keeps pointing from the source to the target.
String bidiIsolate(String text) => '\u2068$text\u2069';
