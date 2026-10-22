// The platform's dictionary pack storage (`createDictionaryPackStorage`):
// files in the app's support directory on Android, the origin private file
// system in a browser.
export 'dictionary_pack_storage_web.dart'
    if (dart.library.io) 'dictionary_pack_storage_io.dart';
