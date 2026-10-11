import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery/feedback/workbench_notice.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../map/map_fixture.dart';
import '../support/delivery_risk_fixture.dart';
import '../support/formal_workbench_fixture.dart';

// Synthetic identities deliberately separate matching nearby stops from a
// distant stop of the same status. Fitting all Pending instead of the current
// search/status intersection must produce a measurably different camera.
const _csv =
    '''reference,customer_name,address,latitude,longitude,status,time_window
MATCH-P1,Harbour One,1 Review Street,-33.8995,151.138,pending,08:00-10:00
MATCH-P2,Harbour Two,2 Review Street,-33.91,151.15,pending,10:00-12:00
MATCH-C,Historical Three,3 Review Street,-33.93,151.165,completed,12:00-14:00
REMOTE-P,Distant Four,4 Review Street,-32.7,150.5,pending,14:00-16:00
REMOTE-F,Distant Five,5 Review Street,-34.8,152.0,failed,16:00-18:00
''';

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  for (final scale in [1.0, 53 / 17]) {
    testWidgets(
      'left map tools stay in one hittable column in overview and detail at scale $scale',
      (tester) async {
        mapTestSize(tester);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final (fixture, model, _) = await _mount(tester);
        _expectSingleToolColumn(tester);
        await tapFormalControl(tester, 'nearest-stop');
        expect(model.panel, WorkbenchPanel.detail);
        expect(model.detailContext!.origin, DetailOrigin.nearest);
        _expectSingleToolColumn(tester);
        await tapFormalControl(tester, 'detail-close');
        expect(model.panel, WorkbenchPanel.map);
        _expectSingleToolColumn(tester);
        expect(tester.takeException(), isNull);
        await unmountFormalApp(tester, model);
        await awaitFormalIO(tester, fixture.dispose);
      },
    );
  }

  for (final region in ['upper-right', 'central']) {
    testWidgets('two simultaneous touch pointers zoom formal map in $region', (
      tester,
    ) async {
      mapTestSize(tester);
      final (fixture, model, map) = await _mount(tester);
      final query = model.query;
      final references = model.result.stops
          .map((stop) => stop.reference)
          .toList();
      final initial = map.mapController.camera;
      final area = tester.getRect(find.byKey(const ValueKey('delivery-map')));
      final centre = Offset(
        area.left + area.width * .56,
        area.top + (region == 'upper-right' ? 70 : area.height * .45),
      );
      for (final dx in [-110.0, -40.0, 40.0, 110.0]) {
        expect(area.contains(centre + Offset(dx, 0)), isTrue);
      }
      final diagnostics = _gestureDiagnostics(tester, centre);
      debugPrint(
        'prototype pinch $region before: ${jsonEncode({...diagnostics, 'camera': _cameraFacts(map)})}',
      );
      await _pinch(tester, centre, from: 40, to: 110, pointer: 7);
      await pumpFormalFrames(tester);
      final expanded = map.mapController.camera;
      final outFacts = jsonEncode({
        ...diagnostics,
        'initialZoom': initial.zoom,
        'actualAfterOut': _cameraFacts(map),
      });
      debugPrint('prototype pinch $region out: $outFacts');
      expect(expanded.zoom, greaterThan(initial.zoom + .5), reason: outFacts);
      expect(expanded.rotation, closeTo(initial.rotation, 1e-9));
      await waitForFixtureMap(tester, map);

      await _pinch(tester, centre, from: 110, to: 40, pointer: 9);
      await pumpFormalFrames(tester);
      final inFacts = jsonEncode({
        ...diagnostics,
        'expandedZoom': expanded.zoom,
        'actualAfterIn': _cameraFacts(map),
      });
      debugPrint('prototype pinch $region in: $inFacts');
      expect(
        map.mapController.camera.zoom,
        lessThan(expanded.zoom - .5),
        reason: inFacts,
      );
      expect(
        map.mapController.camera.rotation,
        closeTo(initial.rotation, 1e-9),
      );
      expect(model.query, query);
      expect(
        model.result.stops.map((stop) => stop.reference).toList(),
        references,
      );
      expect(model.queueCount, 0);
      expect(
        await awaitFormalIO(tester, model.repository.pendingUpdates),
        isEmpty,
      );
      expect(model.panel, WorkbenchPanel.map);
      expect(tester.takeException(), isNull);
      await unmountFormalApp(tester, model);
      await awaitFormalIO(tester, fixture.dispose);
    });
  }

  testWidgets(
    'explicit header status taps fit current search matches plus test reference',
    (tester) async {
      mapTestSize(tester);
      final (fixture, model, map) = await _mount(tester);
      await tapFormalControl(tester, 'header-filter-all');
      final allCamera = map.mapController.camera;
      expect(allCamera.zoom, lessThan(11));
      for (final stop in model.stops) {
        expect(
          allCamera.visibleBounds.contains(
            LatLng(stop.latitude, stop.longitude),
          ),
          isTrue,
        );
      }
      await tapFormalControl(tester, 'open-search');
      await tester.enterText(find.byKey(const ValueKey('map-search')), 'MATCH');
      await pumpFormalFrames(tester);
      expect(model.result.stops, hasLength(3));
      expect(map.mapController.camera.center, allCamera.center);
      expect(map.mapController.camera.zoom, allCamera.zoom);

      await tapFormalControl(tester, 'header-filter-pending');
      final fitted = map.mapController.camera;
      expect(model.query.search, 'MATCH');
      expect(model.query.status, DeliveryStatus.pending);
      expect(model.result.stops.map((stop) => stop.reference), [
        'MATCH-P1',
        'MATCH-P2',
      ]);
      expect(fitted.zoom, greaterThan(allCamera.zoom + .5));
      expect(fitted.zoom, lessThanOrEqualTo(14));
      for (final stop in model.result.stops) {
        expect(
          fitted.visibleBounds.contains(LatLng(stop.latitude, stop.longitude)),
          isTrue,
        );
      }
      expect(
        fitted.visibleBounds.contains(
          const LatLng(TestReference.latitude, TestReference.longitude),
        ),
        isTrue,
      );
      final remote = model.stops.singleWhere((s) => s.reference == 'REMOTE-P');
      expect(
        fitted.visibleBounds.contains(
          LatLng(remote.latitude, remote.longitude),
        ),
        isFalse,
        reason: 'Fit must preserve the current search/status intersection.',
      );

      // Repeating the already-selected status is still a user Fit action and
      // dismisses the actual detail context without changing the shared query.
      await tapFormalControl(tester, 'nearest-stop');
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.selectedStop!.reference, 'MATCH-P1');
      await tapFormalControl(tester, 'header-filter-pending');
      expect(model.panel, WorkbenchPanel.map);
      expect(model.selectedStop, isNull);
      expect(model.query.search, 'MATCH');
      expect(model.query.status, DeliveryStatus.pending);
      expect(map.mapController.camera.center, fitted.center);
      expect(map.mapController.camera.zoom, closeTo(fitted.zoom, 1e-9));

      // Passive model notifications rebuild membership but must not steal a
      // camera which the user is examining. Only the explicit header action fits.
      model.setStatus(DeliveryStatus.completed);
      model.showNotice(
        'Independent review notice',
        kind: NoticeKind.information,
      );
      await pumpFormalFrames(tester);
      expect(model.result.stops.single.reference, 'MATCH-C');
      expect(map.mapController.camera.center, fitted.center);
      expect(map.mapController.camera.zoom, fitted.zoom);
      await tapFormalControl(tester, 'header-filter-pending');
      expect(map.mapController.camera.zoom, closeTo(fitted.zoom, 1e-9));

      await tester.enterText(
        find.byKey(const ValueKey('map-search')),
        'NO-MATCH',
      );
      await pumpFormalFrames(tester);
      await tapFormalControl(tester, 'header-filter-failed');
      expect(model.result.stops, isEmpty);
      expect(
        map.mapController.camera.center,
        const LatLng(TestReference.latitude, TestReference.longitude),
      );
      expect(map.mapController.camera.zoom, 14);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('fit-stops')))
            .onPressed,
        isNull,
      );
      expect(model.queueCount, 0);
      expect(
        await awaitFormalIO(tester, model.repository.pendingUpdates),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await unmountFormalApp(tester, model);
      await awaitFormalIO(tester, fixture.dispose);
    },
  );

  testWidgets(
    'Browse defaults to prototype rows and retains explicit query tools',
    (tester) async {
      mapTestSize(tester);
      final (fixture, model, _) = await _mount(tester);
      await tapFormalControl(tester, 'header-filter-pending');
      await tapFormalControl(tester, 'browse-stops');
      expect(model.panel, WorkbenchPanel.list);
      final panel = find.byKey(const ValueKey('list-workspace'));
      expect(
        find.descendant(of: panel, matching: find.text('Stops on the map')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: panel,
          matching: find.text('3 stops · Nearest first'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('stop-search')), findsNothing);
      final tools = find.byKey(const ValueKey('list-query-controls'));
      expect(tools.hitTestable(), findsOneWidget);
      expect(tester.getSize(tools).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(tools).height, greaterThanOrEqualTo(44));

      final first = model.result.stops.first;
      final row = find.byKey(ValueKey('stop-${first.reference}'));
      final customer = find.descendant(
        of: row,
        matching: find.text(first.customerName),
      );
      final address = find.descendant(
        of: row,
        matching: find.text(first.address),
      );
      expect(customer, findsOneWidget);
      expect(address, findsOneWidget);
      expect(
        tester.getRect(customer).bottom,
        lessThan(tester.getRect(address).top),
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(
            straightLineDistanceLabel(model.result.distanceMeters(first)!),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('08:00–10:00')),
        findsOneWidget,
      );

      await tapFormalControl(tester, 'list-query-controls');
      await revealFormalControl(tester, 'stop-search');
      await tester.enterText(
        find.byKey(const ValueKey('stop-search')),
        'MATCH-P',
      );
      await pumpFormalFrames(tester);
      expect(model.result.stops, hasLength(2));
      expect(model.query.status, DeliveryStatus.pending);
      await tapFormalControl(tester, 'list-query-controls');
      expect(find.byKey(const ValueKey('stop-search')), findsNothing);
      expect(model.query.search, 'MATCH-P');
      expect(model.result.stops, hasLength(2));
      await tapFormalControl(tester, 'stop-${first.reference}');
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.detailContext!.origin, DetailOrigin.list);
      expect(model.selectedStop!.reference, first.reference);
      final savedOffset = model.listSession.scrollOffset;
      await tapFormalControl(tester, 'detail-close');
      expect(model.panel, WorkbenchPanel.list);
      expect(model.query.search, 'MATCH-P');
      expect(model.query.status, DeliveryStatus.pending);
      expect(model.listSession.scrollOffset, closeTo(savedOffset, .1));
      expect(model.listSession.focusedReference, first.reference);
      expect(row.hitTestable(), findsOneWidget);
      await tapFormalControl(tester, 'close-list');
      expect(model.panel, WorkbenchPanel.map);
      expect(model.query.search, 'MATCH-P');
      expect(model.queueCount, 0);
      expect(
        await awaitFormalIO(tester, model.repository.pendingUpdates),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await unmountFormalApp(tester, model);
      await awaitFormalIO(tester, fixture.dispose);
    },
  );

  testWidgets('Browse sync notice reserves a separate lane and releases it', (
    tester,
  ) async {
    mapTestSize(tester);
    final (fixture, model, _) = await _mount(tester);
    await tapFormalControl(tester, 'browse-stops');
    final panel = find.byKey(const ValueKey('list-workspace'));
    final original = tester.getRect(panel);
    final map = tester.getRect(find.byKey(const ValueKey('delivery-map')));
    expect(model.queueCount, 0);
    await tapFormalControl(tester, 'list-sync');
    expect(model.notice.value!.message, 'No saved updates to sync.');
    final notice = find.byKey(const ValueKey('workbench-notice'));
    expect(notice, findsOneWidget);
    final noticeBounds = tester.getRect(notice);
    final panelWithNotice = tester.getRect(panel);
    expect(panelWithNotice.top, greaterThanOrEqualTo(noticeBounds.bottom));
    expect(panelWithNotice.bottom, lessThanOrEqualTo(map.bottom));
    for (final key in ['list-query-controls', 'list-sync', 'close-list']) {
      final action = find.byKey(ValueKey(key));
      final bounds = tester.getRect(action);
      expect(action.hitTestable(), findsOneWidget, reason: key);
      expect(bounds.overlaps(noticeBounds), isFalse, reason: key);
      expect(panelWithNotice.contains(bounds.topLeft), isTrue, reason: key);
      expect(panelWithNotice.contains(bounds.bottomRight), isTrue, reason: key);
      expect(bounds.width, greaterThanOrEqualTo(44), reason: key);
      expect(bounds.height, greaterThanOrEqualTo(44), reason: key);
    }
    // Notice is a ValueNotifier independent of the VM's ChangeNotifier.
    // Clear only that actual notice, without a query/business notification.
    model.clearNotice(model.notice.value!.id);
    await pumpFormalFrames(tester);
    expect(find.byKey(const ValueKey('workbench-notice')), findsNothing);
    expect(tester.getRect(panel).top, closeTo(original.top, .01));
    expect(tester.getRect(panel).bottom, closeTo(original.bottom, .01));
    expect(model.panel, WorkbenchPanel.list);
    expect(model.query, const WorkbenchQuery());
    expect(
      await awaitFormalIO(tester, model.repository.pendingUpdates),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
    await unmountFormalApp(tester, model);
    await awaitFormalIO(tester, fixture.dispose);
  });
}

void _expectSingleToolColumn(WidgetTester tester) {
  final map = tester.getRect(find.byKey(const ValueKey('delivery-map')));
  Rect? previous;
  for (final key in [
    'zoom-in',
    'zoom-out',
    'fit-stops',
    'locate-reference',
    'map-sync',
  ]) {
    final tool = find.byKey(ValueKey(key));
    expect(tool.hitTestable(), findsOneWidget, reason: key);
    final bounds = tester.getRect(tool);
    expect(bounds.width, greaterThanOrEqualTo(44), reason: key);
    expect(bounds.height, greaterThanOrEqualTo(44), reason: key);
    expect(
      map.contains(bounds.topLeft),
      isTrue,
      reason: '$key $bounds in $map',
    );
    expect(
      map.contains(bounds.bottomRight),
      isTrue,
      reason: '$key $bounds in $map',
    );
    if (previous != null) {
      expect(bounds.left, closeTo(previous.left, .01), reason: key);
      expect(bounds.center.dx, closeTo(previous.center.dx, .01), reason: key);
      expect(bounds.top, greaterThanOrEqualTo(previous.bottom), reason: key);
    }
    previous = bounds;
  }
}

Map<String, Object> _cameraFacts(DeliveryMapController map) => {
  'latitude': map.mapController.camera.center.latitude,
  'longitude': map.mapController.camera.center.longitude,
  'zoom': map.mapController.camera.zoom,
  'rotation': map.mapController.camera.rotation,
};

Map<String, Object> _gestureDiagnostics(WidgetTester tester, Offset centre) {
  final target = find.byKey(const ValueKey('delivery-map'));
  final render = tester.element(target).findRenderObject();
  return {
    'mapRect': tester.getRect(target).toString(),
    'pointHitPaths': [
      for (final dx in [-110.0, -40.0, 40.0, 110.0])
        {
          'point': {'x': centre.dx + dx, 'y': centre.dy},
          'includesActualMapRenderBox': tester
              .hitTestOnBinding(centre + Offset(dx, 0))
              .path
              .any((entry) => identical(entry.target, render)),
          'path': tester
              .hitTestOnBinding(centre + Offset(dx, 0))
              .path
              .map((entry) => entry.target.runtimeType.toString())
              .toList(),
        },
    ],
  };
}

Future<void> _pinch(
  WidgetTester tester,
  Offset centre, {
  required double from,
  required double to,
  required int pointer,
}) async {
  final left = await tester.createGesture(
    pointer: pointer,
    kind: ui.PointerDeviceKind.touch,
  );
  final right = await tester.createGesture(
    pointer: pointer + 1,
    kind: ui.PointerDeviceKind.touch,
  );
  var leftDown = false;
  var rightDown = false;
  try {
    await left.down(centre - Offset(from, 0));
    leftDown = true;
    await right.down(centre + Offset(from, 0));
    rightDown = true;
    // Both fingers remain down throughout these paired move events. This does
    // not call MapController.move/fitCamera or replace the gesture recognizer.
    for (var step = 1; step <= 10; step++) {
      final radius = from + (to - from) * step / 10;
      final time = Duration(milliseconds: step * 16);
      await left.moveTo(centre - Offset(radius, 0), timeStamp: time);
      await right.moveTo(centre + Offset(radius, 0), timeStamp: time);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 120));
    await left.up(timeStamp: const Duration(milliseconds: 280));
    leftDown = false;
    await right.up(timeStamp: const Duration(milliseconds: 280));
    rightDown = false;
  } finally {
    try {
      if (leftDown) await left.cancel();
    } finally {
      if (rightDown) await right.cancel();
    }
  }
}

Future<(FormalWorkbenchFixture, DeliveryViewModel, DeliveryMapController)>
_mount(WidgetTester tester) async {
  await completeFixtureIO(
    tester,
    () async {
      final font = FontLoader('Inter')
        ..addFont(rootBundle.load('assets/InterVariable.ttf'));
      await font.load();
    },
    description: 'approved Inter must load before prototype geometry tests',
  );
  final sandbox = (await awaitFormalIO(tester, DeliveryRiskSandbox.create))!;
  final fixture = FormalWorkbenchFixture(sandbox);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await awaitFormalIO(tester, fixture.dispose);
  });
  final model = (await awaitFormalIO(
    tester,
    () => fixture.createModel(loadCsv: () async => _csv),
  ))!;
  final provider = await fixtureProvider(tester);
  final map = fixtureController(tester);
  await mountFormalApp(
    tester,
    model: model,
    provider: provider,
    controller: map,
  );
  await waitForFixtureMap(tester, map);
  expect(model.stops, hasLength(5));
  return (fixture, model, map);
}
