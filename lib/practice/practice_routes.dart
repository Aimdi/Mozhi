/// Where practice lives, without loading its screens (they are deferred).
abstract final class PracticeRoutes {
  /// The practice page.
  static const location = '/practice';

  /// Query parameter naming the one collection to practise.
  static const collectionParameter = 'collection';

  /// The location practising [collectionId] (the practised collections
  /// without one).
  static String locationFor({String? collectionId}) => Uri(
    path: location,
    queryParameters: collectionId == null
        ? null
        : {collectionParameter: collectionId},
  ).toString();
}
