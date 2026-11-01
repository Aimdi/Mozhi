/// Outside a browser no other tab shares the app's storage.
Stream<String?> webStorageChanges() => const Stream.empty();
