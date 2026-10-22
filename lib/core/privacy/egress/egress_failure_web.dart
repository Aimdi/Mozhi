import 'package:mozhi/core/privacy/egress/egress_entry.dart';

/// Browsers report every network error the same way (a `ClientException`
/// from `fetch`), so nothing more can be told here.
EgressFailure? platformFailureOf(Object error) => null;
