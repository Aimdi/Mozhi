import 'dart:math';

/// Creates unique-enough local ids (time + counter + random suffix).
typedef IdGenerator = String Function();

int _counter = 0;
final Random _random = Random();

/// Default [IdGenerator], e.g. `m1x2y3z4-1-k3j9`.
String generateLocalId() {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final count = (_counter++).toRadixString(36);
  final suffix = _random.nextInt(1 << 30).toRadixString(36);
  return '$time-$count-$suffix';
}
