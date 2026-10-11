import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/core/brand_theme.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery/query/workbench_query.dart';
import 'package:ocean_delivery/ui/delivery/query/workbench_session.dart';
import 'package:ocean_delivery/models/workbench.dart';

/// Every tile is generated locally. No network client or public OSM requests.
class FixtureTileProvider extends TileProvider {
  FixtureTileProvider(this.image);
  final ui.Image image;
  final requestedCoordinates = <TileCoordinates>[];
  final resolvedCoordinates = <TileCoordinates>[];
  bool fail = false;
  int disposeCalls = 0;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    requestedCoordinates.add(coordinates);
    return _FixtureImage(
      image,
      fail,
      coordinates,
      () => resolvedCoordinates.add(coordinates),
    );
  }

  @override
  void dispose() {
    disposeCalls++;
  }
}

class _FixtureImage extends ImageProvider<_FixtureImage> {
  const _FixtureImage(this.image, this.fail, this.coordinates, this.onResolve);
  final ui.Image image;
  final bool fail;
  final TileCoordinates coordinates;
  final VoidCallback onResolve;

  // Stable per-tile keys also exercise Flutter's synchronous ImageCache hits.
  @override
  bool operator ==(Object other) =>
      other is _FixtureImage &&
      identical(image, other.image) &&
      fail == other.fail &&
      coordinates == other.coordinates;

  @override
  int get hashCode => Object.hash(identityHashCode(image), fail, coordinates);

  @override
  Future<_FixtureImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _FixtureImage key,
    ImageDecoderCallback decode,
  ) {
    onResolve();
    return OneFrameImageStreamCompleter(
      fail
          ? Future<ImageInfo>.error(
              StateError('Controlled fixture tile failure'),
            )
          : SynchronousFuture(ImageInfo(image: image.clone())),
    );
  }
}

Future<FixtureTileProvider> fixtureProvider(WidgetTester tester) async {
  final image = await completeFixtureIO(tester, () async {
    // Decode the real approved assets before mounting icons in FakeAsync.
    // This warms only the SVG byte cache; no widget or graphic is replaced.
    final paths = Map<String, String>.from(
      jsonDecode(await rootBundle.loadString('assets/icons.json')) as Map,
    );
    for (final source in paths.values) {
      final picture = await vg.loadPicture(SvgStringLoader(source), null);
      picture.picture.dispose();
    }
    final codec = await ui.instantiateImageCodec(TileProvider.transparentImage);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }, description: 'local approved SVG assets and tile decode must complete');
  addTearDown(image.dispose);
  return FixtureTileProvider(image);
}

class _FixtureCompletion<T> {
  _FixtureCompletion(this.value);
  final T value;
}

/// Complete real I/O while also draining continuations created in FakeAsync.
/// The action owns success; a real five-second deadline fails missing work.
/// Finish guarded tester UI operations before entering this helper.
Future<T> completeFixtureIO<T>(
  WidgetTester tester,
  Future<T> Function() action, {
  required String description,
  String Function()? diagnostics,
}) async {
  final result = await tester.runAsync(() async {
    var finished = false;
    final deadline = action().timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException(
        '$description${diagnostics == null ? '' : '; ${diagnostics()}'}',
      ),
    );
    unawaited(
      deadline.then<void>(
        (_) {
          finished = true;
        },
        onError: (Object error, StackTrace stack) {
          finished = true;
        },
      ),
    );
    while (!finished) {
      // A late tile observation may queue only a post-frame callback. Request
      // its frame explicitly rather than infer readiness from scheduled frames.
      tester.binding.scheduleFrame();
      await tester.pump(const Duration(milliseconds: 16));
      // Event-loop yield, not a delay standing in for observed completion.
      await Future<void>.delayed(Duration.zero);
    }
    return _FixtureCompletion(await deadline);
  });
  expect(result, isNotNull, reason: description);
  return result!.value;
}

/// Guarded UI work must finish before a cooperative I/O pump loop starts.
Future<void> performFixtureUI(
  WidgetTester tester,
  Future<void> Function() action, {
  required String description,
}) async {
  final completed = await tester.runAsync(() async {
    await action().timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException(description),
    );
    return true;
  });
  expect(completed, isTrue, reason: description);
}

/// Observe the real map/tile state, including post-frame tile notifications.
/// This does not supply tiles, move the camera, or treat settling as readiness.
Future<void> waitForFixtureMap(
  WidgetTester tester,
  DeliveryMapController controller, {
  String Function()? diagnostics,
}) async {
  final ready = Completer<void>();
  void observe() {
    if (controller.isReady &&
        controller.tileStatus.value == MapTileStatus.ready &&
        !ready.isCompleted) {
      ready.complete();
    }
  }

  controller.tileStatus.addListener(observe);
  try {
    // Tile status is published after a frame, which may not schedule another.
    await tester.pump();
    observe();
    await completeFixtureIO(
      tester,
      () => ready.future,
      description: 'fixture map and original tile images must become ready',
      diagnostics: () {
        // Locked flutter_map TileKey stores the public TileImage. Inspect it
        // only for failure evidence; readiness still comes from the controller.
        final tiles = <TileImage>{
          for (final widget in tester.allWidgets)
            if (widget.key?.runtimeType.toString() == 'TileKey')
              (widget.key as dynamic).tileImage as TileImage,
        };
        final states = tiles.map(
          (tile) =>
              '${tile.coordinates}: started=${tile.loadStarted != null}, '
              'finished=${tile.loadFinishedAt != null}, error=${tile.loadError}, '
              'cancelled=${tile.cancelLoading.isCompleted}',
        );
        return 'mapReady=${controller.isReady}, status=${controller.tileStatus.value}, '
            'renderedTiles=${tiles.length} [${states.join('; ')}]'
            '${diagnostics == null ? '' : '; ${diagnostics()}'}';
      },
    );
  } finally {
    controller.tileStatus.removeListener(observe);
  }
  expect(controller.isReady, isTrue);
  expect(controller.tileStatus.value, MapTileStatus.ready);
}

Stop mapStop(
  String reference, {
  DeliveryStatus status = DeliveryStatus.pending,
  double latitude = -33.884,
  double longitude = 151.117,
}) => Stop(
  id: 'id-$reference',
  reference: reference,
  customerName: 'Customer $reference',
  address: 'Address $reference',
  latitude: latitude,
  longitude: longitude,
  status: status,
);

WorkbenchResult mapResult(
  List<Stop> stops, {
  WorkbenchQuery query = const WorkbenchQuery(),
  List<PendingUpdate> queue = const [],
}) => query.evaluate(stops: stops, queue: queue);

Widget mapHost({
  required WorkbenchResult result,
  required FixtureTileProvider provider,
  required DeliveryMapController controller,
  void Function(Stop, DetailOrigin)? onOpenStop,
  ValueChanged<MapViewport>? onViewportChanged,
  MapViewport? initialViewport,
  String datasetId = 'map-fixture',
  bool syncing = false,
  VoidCallback? onSync,
  Future<void> Function()? tileCacheClearer,
  double textScale = 1,
  bool disableAnimations = false,
  EdgeInsets fitPadding = const EdgeInsets.all(30),
  EdgeInsets Function(BoxConstraints)? fitPaddingBuilder,
  bool showTools = true,
  String? selectedStopId,
  Widget Function(BuildContext, BoxConstraints)? overlayBuilder,
  double toolbarTop = 120,
  double? workspaceHeight,
}) => MaterialApp(
  theme: oceanTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: disableAnimations,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: SizedBox(
      height: workspaceHeight,
      child: DeliveryMapWorkspace(
        result: result,
        datasetId: datasetId,
        controller: controller,
        onOpenStop: onOpenStop ?? (_, _) {},
        tileProvider: provider,
        tileUrlTemplate: 'http://127.0.0.1/controlled/{z}/{x}/{y}.png',
        initialViewport: initialViewport,
        onViewportChanged: onViewportChanged,
        syncing: syncing,
        onSync: onSync,
        toolbarTop: toolbarTop,
        fitPadding: fitPadding,
        fitPaddingBuilder: fitPaddingBuilder,
        showTools: showTools,
        selectedStopId: selectedStopId,
        overlayBuilder: overlayBuilder,
        tileCacheClearer: tileCacheClearer ?? () async {},
      ),
    ),
  ),
);

void mapTestSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

DeliveryMapController fixtureController(WidgetTester tester) {
  final controller = DeliveryMapController();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  return controller;
}
