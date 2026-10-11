import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/app/ocean_delivery_app.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/models/route.dart';
import 'package:ocean_delivery/platform/location/location_gateway.dart';
import 'package:ocean_delivery/platform/navigation/navigation_gateway.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';
import 'package:ocean_delivery/ui/navigation/navigation_view_model.dart';

import '../map/map_fixture.dart';
import '../ui/fake_delivery_repository.dart';

void main() {
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  testWidgets(
    'each detail source returns with query session and map retained',
    (tester) async {
      final fixture = await _mount(tester);
      for (final origin in DetailOrigin.values) {
        await _open(tester, fixture, origin);
        final selected = fixture.model.selectedStop!;
        final query = fixture.model.query;
        final listSession = fixture.model.detailContext!.listSession;
        final camera = fixture.map.mapController.camera;
        await _tap(tester, 'detail-navigate');
        expect(_key('navigation-preview'), findsOneWidget);
        expect(fixture.navigation!.target.stopId, selected.id);
        expect(fixture.navigation!.routeStatus, RoutePreviewStatus.unavailable);
        expect(_key('navigation-route-state'), findsOneWidget);
        await _tap(tester, 'navigation-choose-map');
        await _tap(tester, 'navigation-app-browserMap');
        expect(
          fixture.navigation!.handoffStatus,
          HandoffStatus.handoffRequested,
        );
        await _tap(tester, 'navigation-return-detail');
        expect(fixture.model.panel, WorkbenchPanel.detail);
        expect(fixture.model.selectedStop!.id, selected.id);
        expect(fixture.model.detailContext!.origin, origin);
        expect(fixture.model.query, query);
        expect(fixture.model.detailContext!.listSession, same(listSession));
        await _tap(tester, 'detail-close');
        expect(
          fixture.model.panel,
          origin == DetailOrigin.list
              ? WorkbenchPanel.list
              : WorkbenchPanel.map,
        );
        expect(fixture.model.query, query);
        expect(fixture.map.mapController.camera.center, camera.center);
        expect(fixture.map.mapController.camera.zoom, camera.zoom);
        if (origin == DetailOrigin.list) {
          expect(
            fixture.model.listSession.scrollOffset,
            closeTo(listSession!.scrollOffset, .1),
          );
          expect(
            fixture.model.listSession.focusedReference,
            listSession.focusedReference,
          );
          await _tap(tester, 'close-list');
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'navigation failures and return preserve an existing immutable outbox',
    (tester) async {
      final fixture = await _mount(tester);
      final initial = _durable(fixture.repository);
      await _open(tester, fixture, DetailOrigin.nearest);
      await _tap(tester, 'detail-navigate');
      await _tap(tester, 'navigation-use-location');
      expect(
        fixture.navigation!.locationStatus,
        LocationStatus.permissionDenied,
      );
      expect(fixture.navigation!.origin, isNull);
      expect(fixture.navigation!.route, isNull);
      await _tap(tester, 'navigation-choose-map');
      await _tap(tester, 'navigation-app-appleMaps');
      expect(fixture.navigation!.handoffStatus, HandoffStatus.unavailable);
      expect(_key('navigation-app-googleMaps'), findsOneWidget);
      await _tap(tester, 'navigation-app-googleMaps');
      expect(fixture.navigation!.handoffStatus, HandoffStatus.launchFailed);
      expect(_key('navigation-app-browserMap'), findsOneWidget);
      await _tap(tester, 'navigation-app-browserMap');
      expect(fixture.navigation!.handoffStatus, HandoffStatus.handoffRequested);
      expect(_durable(fixture.repository), initial);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _frames(tester);
      expect(fixture.navigation!.handoffStatus, HandoffStatus.returned);
      expect(_durable(fixture.repository), initial);
      await _tap(tester, 'navigation-return-detail');
      await _tap(tester, 'detail-close');
      expect(_durable(fixture.repository), initial);
      expect(fixture.repository.submitCalls, 0);
      expect(fixture.model.queueCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scope switch and removed stop invalidate pending handoff UI', (
    tester,
  ) async {
    final held = _HeldUiGateway();
    final fixture = await _mount(tester, gateway: held);
    final initial = _durable(fixture.repository);
    for (final scopeSwitch in [true, false]) {
      await _open(tester, fixture, DetailOrigin.nearest);
      final targetId = fixture.model.selectedStop!.id;
      await _tap(tester, 'detail-navigate');
      await _tap(tester, 'navigation-choose-map');
      await _tap(tester, 'navigation-app-browserMap');
      expect(fixture.navigation!.handoffStatus, HandoffStatus.checking);
      final oldNavigation = fixture.navigation!;
      if (scopeSwitch) {
        fixture.model.updateNavigationScope(
          NavigationScope(
            workspaceId: 'independent-account-container',
            principalId: 'driver-b',
            sessionGeneration: 1,
            datasetId: fixture.model.navigationScope.datasetId,
          ),
        );
      } else {
        fixture.repository.stops.removeWhere((stop) => stop.id == targetId);
        await completeFixtureIO(
          tester,
          fixture.model.load,
          description: 'removed-stop repository refresh must complete',
        );
      }
      await _frames(tester);
      expect(_key('navigation-invalidated'), findsOneWidget);
      expect(_key('navigation-app-browserMap'), findsNothing);
      expect(oldNavigation.handoffStatus, HandoffStatus.invalidated);
      held.pending.last.complete(HandoffStatus.handoffRequested);
      await _frames(tester);
      expect(oldNavigation.handoffStatus, HandoffStatus.invalidated);
      await _tap(tester, 'navigation-close');
      if (!scopeSwitch) {
        expect(
          fixture.model.panel,
          WorkbenchPanel.map,
          reason: 'A removed stop must return to its valid source workspace',
        );
        expect(fixture.model.selectedStop, isNull);
      } else if (fixture.model.panel == WorkbenchPanel.detail) {
        await _tap(tester, 'detail-close');
      }
      expect(fixture.repository.submitCalls, 0);
      expect(_queue(fixture.repository), jsonDecode(initial)['outbox']);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'maximum text preserves readable navigation and reachable map actions',
    (tester) async {
      final fixture = await _mount(tester, scale: 53 / 17);
      await _open(tester, fixture, DetailOrigin.nearest);
      await _tap(tester, 'detail-navigate');
      final close = _key('navigation-close');
      final returnButton = _key('navigation-return-detail');
      expect(close.hitTestable(), findsOneWidget);
      expect(returnButton.hitTestable(), findsOneWidget);
      expect(tester.getSize(close).shortestSide, greaterThanOrEqualTo(44));
      final destination = _key('navigation-destination');
      expect(
        MediaQuery.textScalerOf(tester.element(destination)).scale(17),
        closeTo(53, .001),
      );
      await _tap(tester, 'navigation-use-location');
      expect(
        fixture.navigation!.locationStatus,
        LocationStatus.permissionDenied,
      );
      await _tap(tester, 'navigation-manual-start');
      await tester.enterText(_key('navigation-start-latitude'), '-33.91');
      await tester.enterText(_key('navigation-start-longitude'), '151.14');
      await _tap(tester, 'navigation-confirm-start');
      await _frames(tester);
      expect(fixture.navigation!.origin!.source, OriginSource.manual);
      expect(fixture.navigation!.routeStatus, RoutePreviewStatus.unavailable);
      await _tap(tester, 'navigation-maps-start');
      expect(fixture.navigation!.origin, isNull);
      await _tap(tester, 'navigation-choose-map');
      for (final app in NavigationApp.values) {
        await _tap(tester, 'navigation-app-${app.name}');
        expect(tester.takeException(), isNull);
      }
      await _tap(tester, 'navigation-return-detail');
      await _tap(tester, 'detail-close');
      expect(fixture.model.panel, WorkbenchPanel.map);
      expect(fixture.repository.submitCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  if (key == 'nearest-stop' &&
      _key(key).evaluate().isEmpty &&
      _key('map-summary-open').evaluate().isNotEmpty) {
    await _tap(tester, 'map-summary-open');
  }
  final target = _key(key);
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await _frames(tester);
  expect(target.hitTestable(), findsOneWidget, reason: '$key must be tappable');
  await tester.tap(target);
  await _frames(tester);
}

Future<void> _open(
  WidgetTester tester,
  _Fixture fixture,
  DetailOrigin origin,
) async {
  switch (origin) {
    case DetailOrigin.list:
      await _tap(tester, 'browse-stops');
      if (_key('stop-search').evaluate().isEmpty) {
        await _tap(tester, 'list-query-controls');
      }
      await tester.enterText(_key('stop-search'), 'F1-P');
      await _frames(tester);
      await _tap(tester, 'stop-F1-P1');
    case DetailOrigin.map:
      final visible = fixture.model.result.stops.map(
        (stop) => _key('map-stop-${stop.reference}').hitTestable(),
      );
      final marker = visible.firstWhere(
        (finder) => finder.evaluate().isNotEmpty,
      );
      await tester.tap(marker);
      await _frames(tester);
    case DetailOrigin.nearest:
      await _tap(tester, 'nearest-stop');
  }
  expect(fixture.model.panel, WorkbenchPanel.detail);
  expect(fixture.model.detailContext!.origin, origin);
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  double scale = 1,
  NavigationGateway? gateway,
}) async {
  mapTestSize(tester);
  tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
  tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await completeFixtureIO(tester, () async {
    final font = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/InterVariable.ttf'));
    await font.load();
  }, description: 'real app font must load before large-font layout');
  final repository = FakeDeliveryRepository()
    ..stops.clear()
    ..stops.addAll([
      const Stop(
        id: 'f1-p1',
        reference: 'F1-P1',
        customerName: 'Harbour delivery one',
        address: '1 Independent Street, Sydney NSW',
        latitude: -33.9,
        longitude: 151.158,
        status: DeliveryStatus.pending,
      ),
      const Stop(
        id: 'f1-p2',
        reference: 'F1-P2',
        customerName: 'Harbour delivery two',
        address: '2 Independent Street, Sydney NSW',
        latitude: -33.914,
        longitude: 151.126,
        status: DeliveryStatus.pending,
      ),
      Stop(
        id: 'f1-terminal',
        reference: 'F1-T',
        customerName: 'Existing offline result',
        address: '3 Independent Street, Sydney NSW',
        latitude: -33.887,
        longitude: 151.121,
        status: DeliveryStatus.completed,
        operationId: 'existing-immutable-op',
        recordedAt: DateTime.utc(2026, 10, 12),
      ),
    ])
    ..queue.add(
      PendingUpdate(
        seq: 8,
        operationId: 'existing-immutable-op',
        datasetId: 'fixture-dataset',
        stopId: 'f1-terminal',
        status: DeliveryStatus.completed,
        recordedAt: DateTime.utc(2026, 10, 12),
      ),
    );
  final model = DeliveryViewModel(
    repository: repository,
    syncCoordinator: SyncCoordinator(repository: repository),
  );
  final fixture = _Fixture(repository, model, DeliveryMapController());
  final provider = await fixtureProvider(tester);
  await tester.pumpWidget(
    OceanDeliveryApp(
      createViewModel: () async => model,
      tileProvider: provider,
      mapController: fixture.map,
      tileUrlTemplate: 'http://127.0.0.1/f1-owned-tiles/{z}/{x}/{y}.png',
      locationGateway: _DeniedLocation(),
      navigationGateway: gateway ?? _FixtureGateway(),
      onNavigationChanged: (navigation) => fixture.navigation = navigation,
    ),
  );
  await _frames(tester);
  await waitForFixtureMap(tester, fixture.map);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await completeFixtureIO(
      tester,
      model.close,
      description: 'independent app model must close without pending work',
    );
  });
  return fixture;
}

List<Map<String, Object?>> _queue(FakeDeliveryRepository repository) => [
  for (final update in repository.queue)
    {
      'seq': update.seq,
      'operationId': update.operationId,
      'datasetId': update.datasetId,
      'stopId': update.stopId,
      'status': update.status.name,
      'reason': update.reason,
      'note': update.note,
      'recordedAt': update.recordedAt?.toUtc().toIso8601String(),
    },
];

String _durable(FakeDeliveryRepository repository) => jsonEncode({
  'stops': [
    for (final stop in repository.stops)
      {
        'id': stop.id,
        'status': stop.status.name,
        'operationId': stop.operationId,
        'reason': stop.reason,
        'note': stop.note,
        'recordedAt': stop.recordedAt?.toUtc().toIso8601String(),
        'acknowledgedAt': stop.acknowledgedAt?.toUtc().toIso8601String(),
      },
  ],
  'outbox': _queue(repository),
});

class _Fixture {
  _Fixture(this.repository, this.model, this.map);
  final FakeDeliveryRepository repository;
  final DeliveryViewModel model;
  final DeliveryMapController map;
  NavigationViewModel? navigation;
}

class _DeniedLocation implements LocationGateway {
  @override
  Future<LocationResult> currentLocation() async =>
      const LocationResult.failure(LocationStatus.permissionDenied);
}

class _FixtureGateway implements NavigationGateway {
  @override
  Future<HandoffStatus> launch(
    NavigationApp app, {
    required RouteCoordinate destination,
    RouteCoordinate? origin,
    required bool Function() isCurrent,
  }) async => !isCurrent()
      ? HandoffStatus.invalidated
      : switch (app) {
          NavigationApp.appleMaps => HandoffStatus.unavailable,
          NavigationApp.googleMaps => HandoffStatus.launchFailed,
          NavigationApp.browserMap => HandoffStatus.handoffRequested,
        };
}

class _HeldUiGateway implements NavigationGateway {
  final pending = <Completer<HandoffStatus>>[];
  @override
  Future<HandoffStatus> launch(
    NavigationApp app, {
    required RouteCoordinate destination,
    RouteCoordinate? origin,
    required bool Function() isCurrent,
  }) {
    final receipt = Completer<HandoffStatus>();
    pending.add(receipt);
    return receipt.future;
  }
}
