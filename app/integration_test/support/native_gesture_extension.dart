import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderBox;
import 'package:flutter/widgets.dart' show View;
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

class MapPinchOutExtension extends _MapPinchExtension {
  MapPinchOutExtension() : super(outward: true);
}

class MapPinchInExtension extends _MapPinchExtension {
  MapPinchInExtension() : super(outward: false);
}

/// Instrumented framework touch input, not physical OS touchscreen injection.
/// The readonly bridge and the product MapController are never used here.
abstract class _MapPinchExtension extends CommandExtension {
  _MapPinchExtension({required this.outward});
  final bool outward;

  @override
  String get commandKind => outward ? 'oceanMapPinchOut' : 'oceanMapPinchIn';

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
      throw FormatException('MapPinch accepts its fixed command only.');
    }
    return outward ? const MapPinchOut() : const MapPinchIn();
  }

  @override
  Future<Result> call(
    Command command,
    WidgetController prober,
    CreateFinderFactory finderFactory,
    CommandHandlerFactory handlerFactory,
  ) async {
    final finder = finderFactory.createFinder(ByValueKey('delivery-map'));
    await handlerFactory.waitForElement(finder);
    final elements = finder.evaluate().toList();
    if (elements.length != 1) {
      throw StateError('MapPinch requires one actual onstage delivery-map.');
    }
    final element = elements.single;
    final render = element.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      throw StateError('MapPinch requires an attached, laid-out map.');
    }
    final rect = prober.getRect(finder);
    final view = View.of(element);
    final dpr = view.devicePixelRatio;
    if (!dpr.isFinite || dpr <= 0) {
      throw StateError('MapPinch requires a valid actual device pixel ratio.');
    }
    final window = ui.Rect.fromLTRB(
      view.padding.left / dpr,
      view.padding.top / dpr,
      (view.physicalSize.width - view.padding.right) / dpr,
      (view.physicalSize.height -
              math.max(view.padding.bottom, view.viewInsets.bottom)) /
          dpr,
    );
    final area = rect.intersect(window).deflate(8);
    if (![
          area.left,
          area.top,
          area.right,
          area.bottom,
        ].every((v) => v.isFinite) ||
        area.width < 200 ||
        area.height < 100) {
      throw StateError('MapPinch requires a finite actual map viewport.');
    }
    final largeRadius = math.min(110.0, area.width * .28);
    final smallRadius = largeRadius / 2.75;
    List<String> hitPath(ui.Offset point) => prober
        .hitTestOnBinding(point, viewId: view.viewId)
        .path
        .map((entry) => entry.target.runtimeType.toString())
        .toList();
    bool mapHit(ui.Offset point) =>
        area.contains(point) &&
        prober
            .hitTestOnBinding(point, viewId: view.viewId)
            .path
            .any((entry) => identical(entry.target, render));
    ui.Offset? centre;
    // Prefer the upper-right exposed area. A bounded central fallback permits
    // visible feedback, while refusing an overlay which consumes every pair.
    for (final y in [math.min(70.0, area.height * .25), area.height * .45]) {
      for (final x in [.56, .68]) {
        final candidate = ui.Offset(area.left + area.width * x, area.top + y);
        if ([
          -largeRadius,
          -smallRadius,
          smallRadius,
          largeRadius,
        ].every((dx) => mapHit(candidate + ui.Offset(dx, 0)))) {
          centre = candidate;
          break;
        }
      }
      if (centre != null) break;
    }
    if (centre == null) {
      throw StateError('MapPinch found no actual two-touch map hit path.');
    }
    final from = outward ? smallRadius : largeRadius;
    final to = outward ? largeRadius : smallRadius;
    final startLeft = centre - ui.Offset(from, 0);
    final startRight = centre + ui.Offset(from, 0);
    final endLeft = centre - ui.Offset(to, 0);
    final endRight = centre + ui.Offset(to, 0);
    final beforeHitPaths = [
      startLeft,
      startRight,
      endLeft,
      endRight,
    ].map(hitPath).toList();
    final firstPointer = prober.nextPointer;
    final left = await prober.createGesture(kind: ui.PointerDeviceKind.touch);
    final secondPointer = prober.nextPointer;
    final right = await prober.createGesture(kind: ui.PointerDeviceKind.touch);
    var leftDown = false;
    var rightDown = false;
    final elapsed = Stopwatch()..start();
    try {
      await left.down(startLeft, view: view);
      leftDown = true;
      await right.down(startRight, view: view);
      rightDown = true;
      // Each pair has the same event timestamp and no frame/delay between its
      // two moves. Both pointers stay down; no sequential single-finger drags.
      for (var step = 1; step <= 10; step++) {
        final time = Duration(milliseconds: step * 16);
        final radius = from + (to - from) * step / 10;
        await left.moveTo(
          centre - ui.Offset(radius, 0),
          timeStamp: time,
          view: view,
        );
        await right.moveTo(
          centre + ui.Offset(radius, 0),
          timeStamp: time,
          view: view,
        );
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await left.up(timeStamp: const Duration(milliseconds: 280), view: view);
      leftDown = false;
      await right.up(timeStamp: const Duration(milliseconds: 280), view: view);
      rightDown = false;
    } finally {
      try {
        if (leftDown) await left.cancel();
      } finally {
        if (rightDown) await right.cancel();
      }
    }
    elapsed.stop();
    Map<String, double> point(ui.Offset p) => {'x': p.dx, 'y': p.dy};
    return _GestureResult({
      'key': 'delivery-map',
      'direction': outward ? 'out' : 'in',
      'inputEvidence': 'framework two-touch; not physical OS injection',
      'mapRect': {
        'left': rect.left,
        'top': rect.top,
        'right': rect.right,
        'bottom': rect.bottom,
      },
      'startPoints': [point(startLeft), point(startRight)],
      'endPoints': [point(endLeft), point(endRight)],
      'beforeHitPaths': beforeHitPaths,
      'completedPointers': 2,
      'pointerIds': [firstPointer, secondPointer],
      'pairedMoveSteps': 10,
      'pairedEventTimeStampsMicros': [
        for (var step = 1; step <= 10; step++) step * 16000,
      ],
      'elapsedMicros': elapsed.elapsedMicroseconds,
    });
  }
}
