import 'package:flutter_driver/flutter_driver.dart';

/// A fixed, private UI gesture. No coordinates, finder, or business data can be
/// supplied by the host. This library also runs in the independent Dart driver.
class DoubleComplete extends Command {
  const DoubleComplete() : super(timeout: const Duration(seconds: 8));

  @override
  String get kind => 'oceanDoubleComplete';
}
