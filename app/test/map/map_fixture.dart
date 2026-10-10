import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
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
  bool fail = false;
  int disposeCalls = 0;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    requestedCoordinates.add(coordinates);
    return _FixtureImage(image, fail);
  }

  @override
  void dispose() {
    disposeCalls++;
  }
}

class _FixtureImage extends ImageProvider<_FixtureImage> {
  const _FixtureImage(this.image, this.fail);
  final ui.Image image;
  final bool fail;

  @override
  Future<_FixtureImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _FixtureImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    fail
        ? Future<ImageInfo>.error(StateError('Controlled fixture tile failure'))
        : SynchronousFuture(ImageInfo(image: image.clone())),
  );
}

Future<FixtureTileProvider> fixtureProvider(WidgetTester tester) async {
  final image = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(TileProvider.transparentImage);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  });
  addTearDown(() => image!.dispose());
  return FixtureTileProvider(image!);
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
}) => MaterialApp(
  theme: oceanTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: DeliveryMapWorkspace(
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
      toolbarTop: 120,
      fitPadding: const EdgeInsets.all(30),
      tileCacheClearer: tileCacheClearer ?? () async {},
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
