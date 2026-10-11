import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/models/workbench.dart';
import 'package:ocean_delivery/ui/core/brand_icon.dart';
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
    'stock synchronous TileLayer prunes loaded target tiles before camera rebuild',
    (tester) async {
      mapTestSize(tester);
      final provider = await fixtureProvider(tester);
      final controller = MapController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      });
      final rendered = <TileCoordinates, TileImage>{};
      Widget standaloneHost(int revision) => MaterialApp(
        title: 'Standalone tile fixture revision $revision',
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: FlutterMap(
                  mapController: controller,
                  options: const MapOptions(
                    initialCenter: LatLng(-33.884, 151.117),
                    initialZoom: 11,
                    minZoom: 0,
                    maxZoom: 22,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'http://127.0.0.1/standalone/{z}/{x}/{y}.png',
                      tileProvider: provider,
                      minZoom: 0,
                      maxZoom: 22,
                      maxNativeZoom: 19,
                      panBuffer: 0,
                      keepBuffer: 1,
                      tileDisplay: const TileDisplay.instantaneous(),
                      tileBuilder: (_, child, tile) {
                        rendered[tile.coordinates] = tile;
                        return child;
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 46),
            ],
          ),
        ),
      );
      await tester.pumpWidget(standaloneHost(1));
      await tester.pumpAndSettle();
      final firstLayerState = tester.state(find.byType(TileLayer));
      await tester.pumpWidget(standaloneHost(2));
      await tester.pump();
      expect(tester.state(find.byType(TileLayer)), same(firstLayerState));
      final before = controller.camera;
      expect(before.zoom, 11);
      expect(before.center, const LatLng(-33.884, 151.117));
      await performFixtureUI(tester, () async {
        controller.fitCamera(
          CameraFit.coordinates(
            coordinates: const [LatLng(-33.97, 151.21)],
            padding: const EdgeInsets.fromLTRB(30, 20, 30, 349.2),
            minZoom: 0,
            maxZoom: 15,
          ),
        );
      }, description: 'standalone explicit camera fit must finish');
      await tester.pumpAndSettle();
      expect(controller.camera.zoom, 15);
      final targetTiles = rendered.values.where(
        (tile) => tile.coordinates.z == 15,
      );
      expect(targetTiles, isNotEmpty);
      final coordinates = targetTiles.map((tile) => tile.coordinates).toSet();
      final obtained = provider.requestedCoordinates
          .where((tile) => tile.z == 15)
          .toList();
      final resolved = provider.resolvedCoordinates
          .where((tile) => tile.z == 15)
          .toList();
      // Dependency fault characterization, separate from product availability:
      // first generation resolves synchronously, is pruned, then recreated.
      expect(obtained.length, coordinates.length * 2);
      expect(resolved.toSet(), coordinates);
      expect(resolved.length, coordinates.length);
      for (final coordinate in coordinates) {
        expect(obtained.where((tile) => tile == coordinate), hasLength(2));
      }
      expect(
        targetTiles.every(
          (tile) =>
              tile.loadStarted == null &&
              tile.loadFinishedAt == null &&
              !tile.loadError &&
              !tile.cancelLoading.isCompleted,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'cached return, latest rapid focus and detach remain ready (${reducedMotion ? 'reduced motion' : 'normal motion'})',
      (tester) async {
        mapTestSize(tester);
        final provider = await fixtureProvider(tester);
        final controller = fixtureController(tester);
        final first = mapStop('FIRST', latitude: -33.88, longitude: 151.11);
        final last = mapStop('LAST', latitude: -33.97, longitude: 151.21);
        final result = mapResult([first, last]);
        await tester.pumpWidget(
          mapHost(
            result: result,
            provider: provider,
            controller: controller,
            showTools: false,
            disableAnimations: reducedMotion,
          ),
        );
        await tester.pumpAndSettle();
        await waitForFixtureMap(tester, controller);
        await performFixtureUI(tester, () async {
          controller.focusStop(first);
        }, description: 'first synchronous tile focus must finish');
        await tester.pumpAndSettle();
        await waitForFixtureMap(tester, controller);
        final firstCamera = controller.mapController.camera;
        final firstCoordinates = provider.requestedCoordinates
            .where((tile) => tile.z == 15)
            .toSet();
        expect(firstCoordinates, isNotEmpty);
        final firstResolutions = provider.resolvedCoordinates
            .where(firstCoordinates.contains)
            .length;
        expect(firstResolutions, firstCoordinates.length);
        await performFixtureUI(tester, () async {
          controller.focusStop(last);
        }, description: 'second synchronous tile focus must finish');
        await tester.pumpAndSettle();
        await waitForFixtureMap(tester, controller);
        final lastCamera = controller.mapController.camera;
        final beforeRapid = provider.requestedCoordinates.length;
        await performFixtureUI(tester, () async {
          controller.focusStop(first);
          controller.focusStop(last);
        }, description: 'two focus actions must join the same next frame');
        await tester.pumpAndSettle();
        await waitForFixtureMap(tester, controller);
        expect(controller.mapController.camera.center, lastCamera.center);
        expect(controller.mapController.camera.zoom, lastCamera.zoom);
        expect(
          provider.requestedCoordinates.length,
          beforeRapid,
          reason: 'only the final already-loaded viewport is processed',
        );
        expect(
          find.byKey(const ValueKey('map-stop-LAST')).hitTestable(),
          findsOneWidget,
        );
        await performFixtureUI(tester, () async {
          controller.focusStop(first);
        }, description: 'return to the first cached viewport must finish');
        await tester.pumpAndSettle();
        await waitForFixtureMap(tester, controller);
        expect(controller.mapController.camera.center, firstCamera.center);
        expect(controller.mapController.camera.zoom, firstCamera.zoom);
        expect(provider.requestedCoordinates.length, greaterThan(beforeRapid));
        expect(
          provider.resolvedCoordinates.where(firstCoordinates.contains).length,
          firstResolutions,
          reason: 'real ImageCache hits do not invoke loadImage again',
        );
        expect(
          find.byKey(const ValueKey('map-stop-FIRST')).hitTestable(),
          findsOneWidget,
        );
        final beforeDetach = provider.requestedCoordinates.length;
        await performFixtureUI(
          tester,
          () async {
            controller.focusStop(last);
            await tester.pumpWidget(const SizedBox());
          },
          description: 'remove the map before its queued focus is processed',
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(provider.requestedCoordinates.length, beforeDetach);
        expect(provider.disposeCalls, 1);
        expect(result.stops, hasLength(2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'explicit focus uses updated detail padding and overlay leaves footer visible',
    (tester) async {
      mapTestSize(tester);
      final provider = await fixtureProvider(tester);
      final controller = fixtureController(tester);
      final stop = mapStop('DETAIL', latitude: -33.97, longitude: 151.21);
      final result = mapResult([stop]);
      BoxConstraints? overlayConstraints;
      BoxConstraints? fitConstraints;
      var fits = 0;
      Widget overlay(BuildContext context, BoxConstraints constraints) {
        overlayConstraints = constraints;
        return Positioned(
          left: 12,
          right: 12,
          bottom: 0,
          child: SizedBox(
            key: const ValueKey('host-detail-overlay'),
            height: constraints.maxHeight * .4,
            child: const Material(child: Center(child: Text('Detail preview'))),
          ),
        );
      }

      await tester.pumpWidget(
        mapHost(
          result: result,
          provider: provider,
          controller: controller,
          selectedStopId: stop.id,
          showTools: false,
          overlayBuilder: overlay,
        ),
      );
      await tester.pumpAndSettle();
      final before = controller.mapController.camera;
      expect(before.center, const LatLng(-33.884, 151.117));
      expect(before.zoom, 11, reason: 'selection props never auto-focus');
      await tester.pumpWidget(
        mapHost(
          result: result,
          provider: provider,
          controller: controller,
          selectedStopId: stop.id,
          showTools: false,
          overlayBuilder: overlay,
          fitPaddingBuilder: (constraints) {
            fits++;
            fitConstraints = constraints;
            return EdgeInsets.fromLTRB(
              30,
              20,
              30,
              constraints.maxHeight * .4 + 30,
            );
          },
        ),
      );
      await tester.pump();
      expect(controller.mapController.camera.center, before.center);
      expect(controller.mapController.camera.zoom, before.zoom);
      expect(fits, 0, reason: 'padding props never trigger camera actions');

      final layerBefore = tester.state(find.byType(TileLayer));
      final layerOptions = tester.widget<TileLayer>(find.byType(TileLayer));
      final events = <MapEvent>[];
      final updates = <TileUpdateEvent>[];
      final moved = Completer<MapEventWithMove>();
      final eventSubscription = controller.mapController.mapEventStream.listen((
        event,
      ) {
        events.add(event);
        if (event is MapEventWithMove &&
            event.source == MapEventSource.mapController &&
            !moved.isCompleted) {
          moved.complete(event);
        }
      });
      // Observe the exact public transformer used by the mounted TileLayer.
      // This parallel observer does not change the layer or load a tile.
      final updateSubscription = controller.mapController.mapEventStream
          .map((event) => TileUpdateEvent(mapEvent: event))
          .transform(layerOptions.tileUpdateTransformer)
          .listen(updates.add);
      String eventDiagnostics() {
        final after = controller.mapController.camera;
        final layer = tester.widget<TileLayer>(find.byType(TileLayer));
        final layerContext = tester.element(find.byType(TileLayer));
        final contextualCamera = MapCamera.of(layerContext);
        final eventStates = events.map(
          (event) =>
              '${event.runtimeType}/${event.source}: '
              '${event.camera.center}@${event.camera.zoom} size=${event.camera.nonRotatedSize}',
        );
        final updateStates = updates.map(
          (event) =>
              '${event.mapEvent.runtimeType}/${event.mapEvent.source}: '
              'load=${event.load}, prune=${event.prune}, '
              '${event.center}@${event.zoom}',
        );
        return 'before=${before.center}@${before.zoom} size=${before.nonRotatedSize}; '
            'after=${after.center}@${after.zoom} size=${after.nonRotatedSize}; '
            'events=[${eventStates.join('; ')}]; updates=[${updateStates.join('; ')}]; '
            'sameLayerState=${identical(layerBefore, tester.state(find.byType(TileLayer)))}, '
            'sameContextController=${identical(MapController.of(layerContext), controller.mapController)}, '
            'contextCamera=${contextualCamera.center}@${contextualCamera.zoom}; '
            'layerZoom=${layer.minZoom}..${layer.maxZoom}, '
            'nativeZoom=${layer.minNativeZoom}..${layer.maxNativeZoom}, '
            'pan=${layer.panBuffer}, keep=${layer.keepBuffer}, '
            'defaultTransformer=${identical(layer.tileUpdateTransformer, TileUpdateTransformers.ignoreTapEvents)}, '
            'providerRequests=${provider.requestedCoordinates.join(', ')}; '
            'providerResolved=${provider.resolvedCoordinates.join(', ')}';
      }

      try {
        // Match the normal UI action boundary; publication and actual tile
        // readiness below remain separate, required observations.
        await performFixtureUI(
          tester,
          () async {
            controller.focusStop(stop);
          },
          description: 'explicit selected-stop focus must finish its UI action',
        );
        final event = await completeFixtureIO(
          tester,
          () => moved.future,
          description: 'explicit focus must publish its actual map move',
          diagnostics: eventDiagnostics,
        );
        expect(event.camera.center, controller.mapController.camera.center);
        expect(event.camera.zoom, controller.mapController.camera.zoom);
        await tester.pumpAndSettle();
        await waitForFixtureMap(
          tester,
          controller,
          diagnostics: eventDiagnostics,
        );
      } finally {
        await completeFixtureIO(tester, () async {
          await eventSubscription.cancel();
          await updateSubscription.cancel();
        }, description: 'focus diagnostic subscriptions must be released');
      }
      final mapRect = tester.getRect(
        find.byKey(const ValueKey('delivery-map')),
      );
      final overlayRect = tester.getRect(
        find.byKey(const ValueKey('host-detail-overlay')),
      );
      final marker = find.byKey(const ValueKey('map-stop-DETAIL'));
      expect(marker.hitTestable(), findsOneWidget);
      final markerRect = tester.getRect(marker);
      expect(markerRect.top, greaterThanOrEqualTo(mapRect.top));
      expect(markerRect.bottom, lessThan(overlayRect.top));
      expect(controller.mapController.camera.zoom, 15);
      expect(overlayRect.bottom, mapRect.bottom);
      expect(overlayConstraints!.maxHeight, mapRect.height);
      expect(overlayConstraints!.maxWidth, mapRect.width);
      expect(fits, 1);
      expect(fitConstraints!.maxWidth, mapRect.width);
      expect(fitConstraints!.maxHeight, mapRect.height);
      final footerRect = tester.getRect(
        find.byKey(const ValueKey('map-attribution')),
      );
      expect(footerRect.top, mapRect.bottom);
      expect(footerRect.bottom, lessThanOrEqualTo(844));
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      expect(find.byKey(const ValueKey('zoom-in')), findsNothing);
      expect(controller.tileStatus.value, MapTileStatus.ready);
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
      var syncCalls = 0;
      await tester.pumpWidget(
        mapHost(
          result: mapResult([]),
          provider: provider,
          controller: controller,
          initialViewport: saved,
          syncing: true,
          onSync: () => syncCalls++,
        ),
      );
      // Busy sync intentionally animates; bounded pumps retain that behavior.
      await tester.pump(const Duration(milliseconds: 200));
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
        isNotNull,
      );
      final sync = find.byKey(const ValueKey('map-sync'));
      await tester.tap(sync);
      await tester.pump();
      expect(syncCalls, 1, reason: 'busy action joins the host sync run');
      expect(
        tester.widget<SyncActionIcon>(find.byType(SyncActionIcon)).syncing,
        isTrue,
      );
      final zoomIn = tester.getRect(find.byKey(const ValueKey('zoom-in')));
      final zoomOut = tester.getRect(find.byKey(const ValueKey('zoom-out')));
      final fit = tester.getRect(find.byKey(const ValueKey('fit-stops')));
      final locate = tester.getRect(
        find.byKey(const ValueKey('locate-reference')),
      );
      for (final rect in [zoomIn, zoomOut, fit, locate]) {
        expect(rect.size, const Size(44, 44));
      }
      expect(zoomOut.left, zoomIn.left);
      expect(zoomOut.top, zoomIn.bottom);
      expect(fit.left, zoomIn.left);
      expect(fit.top, zoomOut.bottom);
      expect(locate.left, zoomIn.left);
      expect(locate.top, fit.bottom);
      expect(tester.getSize(sync), const Size(44, 44));
      expect(controller.mapController.camera.center, camera.center);
      expect(controller.mapController.camera.zoom, camera.zoom);
      expect(tester.takeException(), isNull);
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

  for (final height in [200.0, 240.0]) {
    testWidgets(
      'landscape short map exposes single-column tools by actual drag at height $height',
      (tester) async {
        tester.view.physicalSize = const Size(844, 390);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final provider = await fixtureProvider(tester);
        final controller = fixtureController(tester);
        final result = mapResult([mapStop('A')]);
        var syncCalls = 0;
        await tester.pumpWidget(
          mapHost(
            result: result,
            provider: provider,
            controller: controller,
            workspaceHeight: height,
            toolbarTop: 12,
            onSync: () => syncCalls++,
          ),
        );
        await tester.pumpAndSettle();
        await waitForFixtureMap(tester, controller);
        final map = tester.getRect(find.byKey(const ValueKey('delivery-map')));
        expect(map.height, lessThan(221));
        final initialCamera = controller.mapController.camera;
        final zoom = find.byKey(const ValueKey('zoom-in'));
        expect(zoom.hitTestable(), findsOneWidget);
        final columnX = tester.getCenter(zoom).dx;

        // Deliver a real vertical drag inside the visible column. An unbounded
        // column leaves Sync clipped and this actual-hit assertion fails.
        await tester.dragFrom(
          Offset(columnX, map.bottom - 24),
          const Offset(0, -140),
        );
        await tester.pumpAndSettle();
        final sync = find.byKey(const ValueKey('map-sync'));
        expect(
          sync.hitTestable(),
          findsOneWidget,
          reason: 'The bottom tool must receive input after a real column drag',
        );
        for (final key in ['locate-reference', 'map-sync']) {
          final action = find.byKey(ValueKey(key));
          final bounds = tester.getRect(action);
          expect(action.hitTestable(), findsOneWidget, reason: key);
          expect(bounds.size, const Size(44, 44), reason: key);
          expect(map.contains(bounds.topLeft), isTrue, reason: key);
          expect(map.contains(bounds.bottomRight), isTrue, reason: key);
        }
        expect(controller.mapController.camera.center, initialCamera.center);
        expect(controller.mapController.camera.zoom, initialCamera.zoom);
        await tester.tap(sync.hitTestable());
        await tester.pump();
        expect(syncCalls, 1);
        await tester.tap(
          find.byKey(const ValueKey('locate-reference')).hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(
          controller.mapController.camera.center,
          const LatLng(TestReference.latitude, TestReference.longitude),
        );
        expect(controller.mapController.camera.zoom, 14);

        // Scroll back through the same pointer route, then prove Zoom remains
        // a real 44px action. Scrolling the tools must not pan the map.
        final locatedCamera = controller.mapController.camera;
        await tester.dragFrom(
          Offset(columnX, map.top + 32),
          const Offset(0, 140),
        );
        await tester.pumpAndSettle();
        expect(zoom.hitTestable(), findsOneWidget);
        expect(tester.getSize(zoom), const Size(44, 44));
        expect(controller.mapController.camera.center, locatedCamera.center);
        expect(controller.mapController.camera.zoom, locatedCamera.zoom);
        await tester.tap(zoom.hitTestable());
        await tester.pumpAndSettle();
        expect(controller.mapController.camera.zoom, 15);
        for (final key in [
          'zoom-in',
          'zoom-out',
          'fit-stops',
          'locate-reference',
          'map-sync',
        ]) {
          final action = find.byKey(ValueKey(key));
          expect(tester.getSize(action), const Size(44, 44), reason: key);
          expect(tester.getCenter(action).dx, columnX, reason: key);
        }
        expect(result.stops.single.reference, 'A');
        expect(controller.tileStatus.value, MapTileStatus.ready);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
