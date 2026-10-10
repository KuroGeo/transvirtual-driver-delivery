import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_driver/flutter_driver.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_gesture_command.dart';

/// Resolve the real button once, then deliver two consecutive pointer gestures.
/// Re-resolving between gestures would wait for an already dismissed button;
/// parallel driver taps would collide with Flutter's async gesture guard.
class DoubleCompleteExtension extends CommandExtension {
  @override
  String get commandKind => 'oceanDoubleComplete';

  @override
  Command deserialize(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory,
    DeserializeCommandFactory commandFactory,
  ) {
    const fields = {'command', 'timeout', 'isolateId'};
    final isolate = params['isolateId'];
    if (params.keys.any((key) => !fields.contains(key)) ||
        params['command'] != commandKind ||
        params['timeout'] != '8000' ||
        (isolate != null && !RegExp(r'^isolates/[0-9]+$').hasMatch(isolate))) {
      throw FormatException('DoubleComplete accepts its fixed command only.');
    }
    return const DoubleComplete();
  }

  @override
  Future<Result> call(
    Command command,
    WidgetController prober,
    CreateFinderFactory finderFactory,
    CommandHandlerFactory handlerFactory,
  ) async {
    final button = finderFactory.createFinder(ByValueKey('detail-complete'));
    await handlerFactory.waitForElement(button);
    final centre = prober.getCenter(button);
    final elapsed = Stopwatch()..start();
    await prober.tapAt(centre);
    final first = elapsed.elapsedMicroseconds;
    await prober.tapAt(centre);
    elapsed.stop();
    return _GestureResult({
      'key': 'detail-complete',
      'point': {'x': centre.dx, 'y': centre.dy},
      'completedTaps': 2,
      'firstCompletedMicros': first,
      'elapsedMicros': elapsed.elapsedMicroseconds,
    });
  }
}

class _GestureResult extends Result {
  const _GestureResult(this.value);

  final Map<String, dynamic> value;

  @override
  Map<String, dynamic> toJson() => value;
}
