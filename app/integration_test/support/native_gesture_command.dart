import 'package:flutter_driver/flutter_driver.dart';

/// A fixed, private UI gesture. No coordinates, finder, or business data can be
/// supplied by the host. This library also runs in the independent Dart driver.
class DoubleComplete extends Command {
  const DoubleComplete() : super(timeout: const Duration(seconds: 8));

  @override
  String get kind => 'oceanDoubleComplete';
}

/// Fixed two-touch map gestures. The host cannot supply coordinates, a finder,
/// business values, or an imperative camera command.
class MapPinchOut extends Command {
  const MapPinchOut() : super(timeout: const Duration(seconds: 8));

  @override
  String get kind => 'oceanMapPinchOut';
}

class MapPinchIn extends Command {
  const MapPinchIn() : super(timeout: const Duration(seconds: 8));

  @override
  String get kind => 'oceanMapPinchIn';
}
