import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/models/workbench.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery/query/workbench_query.dart';
import 'package:ocean_delivery/ui/delivery/query/workbench_session.dart';

import 'map_fixture.dart';

void main() {
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  testWidgets(
    'real map uses original coordinates and shared query membership',
    (tester) async {
      mapTestSize(tester);
      final provider = await fixtureProvider(tester);
      final controller = fixtureController(tester);
      final stops = [
        mapStop('A'),
        mapStop('B', status: DeliveryStatus.completed, latitude: -33.94),
      ];
      final result = mapResult(
        stops,
        query: const WorkbenchQuery(status: DeliveryStatus.pending),
      );
      await tester.pumpWidget(
        mapHost(result: result, provider: provider, controller: controller),
      );
      await tester.pumpAndSettle();
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      final cluster = tester.widget<MarkerClusterLayerWidget>(
        find.byType(MarkerClusterLayerWidget),
      );
      expect(map.mapController, same(controller.mapController));
      expect(
        cluster.options.markers.single.point,
        LatLng(stops[0].latitude, stops[0].longitude),
      );
      expect(cluster.options.markers.single.key, ValueKey(stops[0].id));
      expect(result.stops.single, same(stops[0]));
      expect(find.byKey(const ValueKey('map-stop-B')), findsNothing);
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      expect(find.byKey(const ValueKey('map-attribution')), findsOneWidget);
      final tileLayer = tester.widget<TileLayer>(find.byType(TileLayer));
      expect(tileLayer.maxNativeZoom, 19);
      expect(tileLayer.maxZoom, 22);
      expect(tileLayer.urlTemplate, startsWith('http://127.0.0.1/'));
      expect(provider.requestedCoordinates, isNotEmpty);
      expect(controller.tileStatus.value, MapTileStatus.ready);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reference heading stays anchored while footer label supports large text',
    (tester) async {
      mapTestSize(tester);
      final provider = await fixtureProvider(tester);
      final controller = fixtureController(tester);
      final semantics = tester.ensureSemantics();
      try {
        final result = mapResult([mapStop('A')]);
        await tester.pumpWidget(
          mapHost(result: result, provider: provider, controller: controller),
        );
        await tester.pumpAndSettle();
        final footerLabel = find.descendant(
          of: find.byKey(const ValueKey('map-attribution')),
          matching: find.text(TestReference.label),
        );
        final normalLabelHeight = tester.getSize(footerLabel).height;
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(
          mapHost(
            result: result,
            provider: provider,
            controller: controller,
            textScale: 3,
          ),
        );
        await tester.pumpAndSettle();
        final marker = find.byKey(const ValueKey('test-reference-marker'));
        expect(tester.getSize(marker), const Size(44, 44));
        expect(
          tester.getSemantics(marker).getSemanticsData().label,
          contains('Test reference, fixed heading 35 degrees'),
        );
        final reference = tester
            .widget<MarkerLayer>(find.byType(MarkerLayer))
            .markers
            .single;
        expect(
          reference.point,
          const LatLng(TestReference.latitude, TestReference.longitude),
        );
        expect(
          reference.alignment,
          isNull,
          reason: 'graphic is centered on point',
        );
        expect(
          tester.getSize(footerLabel).height,
          greaterThan(normalLabelHeight),
        );
        expect(tester.widget<Text>(footerLabel).textScaler, isNull);
        expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
        expect(controller.tileStatus.value, MapTileStatus.ready);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'mixed cluster conveys member count/status and tap expands to original stop',
    (tester) async {
      mapTestSize(tester);
      final provider = await fixtureProvider(tester);
      final controller = fixtureController(tester);
      final semantics = tester.ensureSemantics();
      try {
        final stops = [
          mapStop('A', latitude: -33.883),
          mapStop(
            'B',
            status: DeliveryStatus.completed,
            latitude: -33.885,
            longitude: 151.118,
          ),
          mapStop(
            'C',
            status: DeliveryStatus.failed,
            latitude: -33.884,
            longitude: 151.116,
          ),
        ];
        Stop? opened;
        DetailOrigin? origin;
        await tester.pumpWidget(
          mapHost(
            result: mapResult(stops),
            provider: provider,
            controller: controller,
            onOpenStop: (stop, source) {
              opened = stop;
              origin = source;
            },
          ),
        );
        await tester.pumpAndSettle();
        final cluster = find.byKey(const ValueKey('map-cluster-A-B-C'));
        expect(cluster.hitTestable(), findsOneWidget);
        final data = tester.getSemantics(cluster).getSemanticsData();
        expect(
          data.label,
          contains('Zoom to 3 stops: 1 Pending, 1 Completed, 1 Failed'),
        );
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        final beforeZoom = controller.mapController.camera.zoom;
        await tester.tap(cluster.hitTestable());
        await tester.pumpAndSettle();
        expect(controller.mapController.camera.zoom, greaterThan(beforeZoom));
        final marker = find.byKey(const ValueKey('map-stop-A'));
        expect(marker.hitTestable(), findsOneWidget);
        expect(
          tester.getSemantics(marker).getSemanticsData().label,
          contains('Pending'),
        );
        await tester.tap(marker.hitTestable());
        await tester.pump();
        expect(opened, same(stops[0]));
        expect(origin, DetailOrigin.map);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'zoom, fit and locate are explicit actions and native tiles stay at z19',
    (tester) async {
      mapTestSize(tester);
      final provider = await fixtureProvider(tester);
      final controller = fixtureController(tester);
      final saves = <MapViewport>[];
      await tester.pumpWidget(
        mapHost(
          result: mapResult([mapStop('A'), mapStop('B', latitude: -33.93)]),
          provider: provider,
          controller: controller,
          onViewportChanged: saves.add,
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.mapController.camera.zoom, 11);
      await tester.tap(find.byKey(const ValueKey('zoom-in')));
      await tester.pump();
      expect(controller.mapController.camera.zoom, 12);
      await tester.tap(find.byKey(const ValueKey('zoom-out')));
      await tester.pump();
      expect(controller.mapController.camera.zoom, 11);
      await tester.tap(find.byKey(const ValueKey('fit-stops')));
      await tester.pumpAndSettle();
      expect(
        controller.mapController.camera.visibleBounds.contains(
          const LatLng(-33.93, 151.117),
        ),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('locate-reference')));
      await tester.pumpAndSettle();
      expect(
        controller.mapController.camera.center,
        const LatLng(TestReference.latitude, TestReference.longitude),
      );
      expect(controller.mapController.camera.zoom, greaterThanOrEqualTo(14));
      expect(
        find.byKey(const ValueKey('test-reference-marker')),
        findsOneWidget,
      );
      controller.mapController.move(controller.mapController.camera.center, 22);
      await tester.pumpAndSettle();
      expect(
        provider.requestedCoordinates.every(
          (coordinates) => coordinates.z <= 19,
        ),
        isTrue,
      );
      expect(
        provider.requestedCoordinates.any((coordinates) => coordinates.z == 19),
        isTrue,
      );
      expect(saves, isNotEmpty);
      expect(saves.last.datasetId, 'map-fixture');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same dataset viewport restores once, result and sync updates retain camera',
    (tester) async {
      mapTestSize(tester);
      final provider = await fixtureProvider(tester);
      final controller = fixtureController(tester);
      const saved = MapViewport(
        datasetId: 'map-fixture',
        latitude: -33.901,
        longitude: 151.145,
        zoom: 12.5,
      );
      await tester.pumpWidget(
        mapHost(
          result: mapResult([mapStop('A')]),
          provider: provider,
          controller: controller,
          initialViewport: saved,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        controller.mapController.camera.center,
        LatLng(saved.latitude, saved.longitude),
      );
      expect(controller.mapController.camera.zoom, saved.zoom);
      controller.mapController.move(const LatLng(-33.89, 151.15), 13.25);
      final camera = controller.mapController.camera;
      await tester.pumpWidget(
        mapHost(
          result: mapResult([]),
          provider: provider,
          controller: controller,
          initialViewport: saved,
          syncing: true,
          onSync: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.mapController.camera.center, camera.center);
      expect(controller.mapController.camera.zoom, camera.zoom);
      expect(
        tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController,
        same(controller.mapController),
      );
      controller.fitMatches();
      await tester.pump();
      expect(
        controller.mapController.camera.center,
        camera.center,
        reason: 'empty fit is stable',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('fit-stops')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('map-sync')))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'foreign viewport falls back, user pan emits one merged valid viewport',
    (tester) async {
      mapTestSize(tester);
      final provider = await fixtureProvider(tester);
      final controller = fixtureController(tester);
      final saves = <MapViewport>[];
      await tester.pumpWidget(
        mapHost(
          result: mapResult([]),
          provider: provider,
          controller: controller,
          initialViewport: const MapViewport(
            datasetId: 'old',
            latitude: 40,
            longitude: 30,
            zoom: 4,
          ),
          onViewportChanged: saves.add,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        controller.mapController.camera.center,
        const LatLng(-33.884, 151.117),
      );
      expect(controller.mapController.camera.zoom, 11);
      expect(saves, isEmpty, reason: 'initial camera is not a user gesture');
      await tester.dragFrom(const Offset(280, 370), const Offset(-55, 25));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(saves, hasLength(1));
      expect(
        saves.single.latitude,
        controller.mapController.camera.center.latitude,
      );
      expect(
        saves.single.longitude,
        controller.mapController.camera.center.longitude,
      );
      expect(saves.single.zoom.isFinite, isTrue);
      expect(saves.single.datasetId, 'map-fixture');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real fixture tile failure leaves marker action available and Retry recovers',
    (tester) async {
      mapTestSize(tester);
      final provider = await fixtureProvider(tester)
        ..fail = true;
      final controller = fixtureController(tester);
      Stop? opened;
      await tester.pumpWidget(
        mapHost(
          result: mapResult([mapStop('A')]),
          provider: provider,
          controller: controller,
          onOpenStop: (stop, _) => opened = stop,
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.tileStatus.value, MapTileStatus.error);
      expect(find.text('Map unavailable. Stops still work.'), findsOneWidget);
      final before = controller.mapController.camera;
      final requestsBeforeRetry = provider.requestedCoordinates.length;
      await tester.tap(find.byKey(const ValueKey('map-stop-A')).hitTestable());
      await tester.pump();
      expect(opened?.reference, 'A');
      provider.fail = false;
      await tester.tap(find.byKey(const ValueKey('retry-map')));
      await tester.pumpAndSettle();
      expect(controller.tileStatus.value, MapTileStatus.ready);
      expect(find.byKey(const ValueKey('retry-map')), findsNothing);
      expect(
        provider.requestedCoordinates.length,
        greaterThan(requestsBeforeRetry),
      );
      expect(controller.mapController.camera.center, before.center);
      expect(controller.mapController.camera.zoom, before.zoom);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tile-only clear reloads fixture, preserves camera and query and rejoins calls',
    (tester) async {
      mapTestSize(tester);
      final provider = await fixtureProvider(tester);
      final controller = fixtureController(tester);
      final result = mapResult([mapStop('A')]);
      var clearCalls = 0;
      await tester.pumpWidget(
        mapHost(
          result: result,
          provider: provider,
          controller: controller,
          tileCacheClearer: () async => clearCalls++,
        ),
      );
      await tester.pumpAndSettle();
      final before = controller.mapController.camera;
      final requests = provider.requestedCoordinates.length;
      final clearing = controller.clearTileCache();
      final joined = controller.clearTileCache();
      expect(identical(clearing, joined), isTrue);
      await tester.pump();
      await clearing;
      await tester.pumpAndSettle();
      expect(clearCalls, 1);
      expect(
        provider.disposeCalls,
        0,
        reason: 'injected provider retained during clear',
      );
      expect(provider.requestedCoordinates.length, greaterThan(requests));
      expect(controller.mapController.camera.center, before.center);
      expect(controller.mapController.camera.zoom, before.zoom);
      expect(
        tester
            .widget<DeliveryMapWorkspace>(find.byType(DeliveryMapWorkspace))
            .result,
        same(result),
      );
      expect(controller.tileStatus.value, MapTileStatus.ready);
      expect(tester.takeException(), isNull);
    },
  );
}
