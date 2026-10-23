import 'package:mozhi/core/key_value_store.dart';
import 'package:mozhi/on_device_ai/data/on_device_ai.dart';

/// No on-device AI in a browser (see `on_device_ai_io.dart` for the app).
Future<OnDeviceAi?> createOnDeviceAi({required KeyValueStore store}) async =>
    null;
