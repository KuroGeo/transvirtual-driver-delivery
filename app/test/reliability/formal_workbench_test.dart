import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/data/services/demo_transport.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/models/workbench.dart';
import 'package:ocean_delivery/ui/delivery/failure/delivery_failure_sheet.dart';
import 'package:ocean_delivery/ui/delivery/feedback/workbench_notice.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../map/map_fixture.dart';
import '../support/delivery_risk_fixture.dart';
import '../support/formal_workbench_fixture.dart';

const _localName = 'ocean_delivery.sqlite';
const _demoName = 'ocean_delivery-demo.sqlite';

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  testWidgets(
    'formal factory uses first-mount local tiles, typed origins and isolated default modes',
    (tester) async {
      mapTestSize(tester);
      final fixture = await _fixture(tester);
      final local = (await awaitFormalIO(tester, fixture.createModel))!;
      final localMap = _controller(tester);
      final provider = await fixtureProvider(tester);
      provider.fail = true;
      await mountFormalApp(
        tester,
        model: local,
        provider: provider,
        controller: localMap,
      );
      expect(local.automaticSync, isTrue);
      expect(local.syncCoordinator.transport, isA<UnavailableTransport>());
      expect(local.mode, ClientMode.localClient);
      expect(find.text('Local client · service unavailable'), findsOneWidget);
      expect(local.stops.length, 4);
      expect(local.pendingCount, 2);
      final mapState = tester.state(find.byKey(const ValueKey('formal-map')));

      await tapFormalControl(tester, 'nearest-stop');
      expect(local.detailContext!.origin, DetailOrigin.nearest);
      expect(local.selectedStop!.reference, 'REF-A');
      await tapFormalControl(tester, 'detail-close');
      expect(local.panel, WorkbenchPanel.map);
      await tapFormalControl(tester, 'browse-stops');
      await tapFormalControl(tester, 'stop-REF-A');
      expect(local.detailContext!.origin, DetailOrigin.list);
      await tapFormalControl(tester, 'detail-close');
      expect(local.panel, WorkbenchPanel.list);
      expect(FocusManager.instance.primaryFocus!.debugLabel, 'Stop REF-A');
      await tapFormalControl(tester, 'close-list');
      expect(
        identical(
          tester.state(find.byKey(const ValueKey('formal-map'))),
          mapState,
        ),
        isTrue,
      );
      await tapFormalControl(tester, 'map-stop-REF-A');
      expect(local.detailContext!.origin, DetailOrigin.map);
      expect(local.selectedStop!.reference, 'REF-A');
      await tapFormalControl(tester, 'detail-close');
      expect(local.panel, WorkbenchPanel.map);

      // At 2x text, detail uses the full task area. Returning to the retained
      // map must still put the real 44px selected marker in the exposed lane.
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpFormalFrames(tester);
      expect(localMap.tileStatus.value, MapTileStatus.error);
      expect(find.byKey(const ValueKey('root-map-error')), findsOneWidget);
      final failureMapRect = tester.getRect(
        find.byKey(const ValueKey('delivery-map')),
      );
      for (final key in [
        'map-sync',
        'zoom-in',
        'zoom-out',
        'fit-stops',
        'locate-reference',
        'retry-map',
      ]) {
        final target = find.byKey(ValueKey(key));
        final bounds = tester.getRect(target);
        expect(target.hitTestable(), findsOneWidget);
        expect(bounds.height, greaterThanOrEqualTo(44));
        expect(failureMapRect.contains(bounds.topLeft), isTrue);
        expect(failureMapRect.contains(bounds.bottomRight), isTrue);
        expect(
          bounds.overlaps(
            tester.getRect(find.byKey(const ValueKey('map-attribution'))),
          ),
          isFalse,
        );
      }
      final failedZoom = localMap.mapController.camera.zoom;
      await tapFormalControl(tester, 'zoom-in');
      expect(localMap.mapController.camera.zoom, failedZoom + 1);
      await tapFormalControl(tester, 'zoom-out');
      expect(localMap.mapController.camera.zoom, failedZoom);
      await tapFormalControl(tester, 'retry-map');
      expect(localMap.tileStatus.value, MapTileStatus.error);
      await tapFormalControl(tester, 'nearest-stop');
      final selected = local.selectedStop!;
      final taskRect = tester.getRect(
        find.byKey(const ValueKey('large-text-task-workspace')),
      );
      final detailRect = tester.getRect(
        find.byKey(const ValueKey('delivery-detail-card')),
      );
      expect(detailRect, taskRect);
      expect(detailRect.height, greaterThan(700));
      expect(find.byKey(const ValueKey('delivery-map')), findsNothing);
      expect(find.byKey(const ValueKey('detail-customer')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('detail-close')).hitTestable(),
        findsOneWidget,
      );
      await tapFormalTransition(
        tester,
        local,
        'detail-complete',
        busy: () => local.isSaving,
      );
      await awaitFormalIO(tester, () => local.sync());
      await pumpFormalFrames(tester);
      expect(local.selectedStop!.status, DeliveryStatus.completed);
      expect(local.queueCount, 1);
      expect(local.notice.value!.message, contains('Service unavailable'));
      expect(local.notice.value!.message, contains('still saved'));
      await tapFormalControl(tester, 'detail-close');
      expect(local.panel, WorkbenchPanel.map);
      expect(
        identical(
          tester.state(find.byKey(const ValueKey('formal-map'))),
          mapState,
        ),
        isTrue,
      );
      final currentMap = tester.getRect(
        find.byKey(const ValueKey('delivery-map')),
      );
      final currentMarker = Rect.fromCenter(
        center:
            currentMap.topLeft +
            localMap.mapController.camera.latLngToScreenOffset(
              LatLng(selected.latitude, selected.longitude),
            ),
        width: 44,
        height: 44,
      );
      expect(currentMap.contains(currentMarker.topLeft), isTrue);
      expect(currentMap.contains(currentMarker.bottomRight), isTrue);
      for (final key in [
        'map-sync',
        'zoom-in',
        'zoom-out',
        'fit-stops',
        'locate-reference',
        'map-attribution',
        'root-map-error',
      ]) {
        expect(
          currentMarker.overlaps(tester.getRect(find.byKey(ValueKey(key)))),
          isFalse,
          reason: 'Returned selected marker hidden by $key',
        );
      }
      expect(find.byKey(const ValueKey('workbench-notice')), findsNothing);
      await tapFormalControl(tester, 'map-summary-open');
      await revealFormalControl(tester, 'workbench-notice');
      expect(find.textContaining('Service unavailable'), findsOneWidget);
      await tapFormalControl(tester, 'summary-close');
      expect(local.panel, WorkbenchPanel.map);
      expect(
        find.byKey(const ValueKey('large-summary-workspace')),
        findsNothing,
      );
      final localOperation = (await awaitFormalIO(
        tester,
        local.repository.pendingUpdates,
      ))!.single;
      await unmountFormalApp(tester, local);
      final localBeforeDemo = (await awaitFormalIO(
        tester,
        () => fixture.sandbox.persistedSnapshot(_localName),
      ))!;
      tester.platformDispatcher.clearTextScaleFactorTestValue();

      final demo = (await awaitFormalIO(
        tester,
        () => fixture.createModel(mode: 'demo'),
      ))!;
      final demoProvider = await fixtureProvider(tester);
      await mountFormalApp(
        tester,
        model: demo,
        provider: demoProvider,
        controller: _controller(tester),
      );
      expect(demo.syncCoordinator.transport, isA<DemoTransport>());
      expect(find.text('Demo · simulated confirmations'), findsOneWidget);
      expect(demo.pendingCount, 2);
      expect(
        demo.stops.singleWhere((stop) => stop.reference == 'REF-A').operationId,
        isNull,
      );
      await tapFormalControl(tester, 'nearest-stop');
      await tapFormalTransition(
        tester,
        demo,
        'detail-complete',
        busy: () => demo.isSaving,
      );
      await awaitFormalIO(tester, () => demo.sync());
      await pumpFormalFrames(tester);
      expect(demo.queueCount, 0);
      expect(demo.selectedStop!.acknowledgedAt, isNotNull);
      expect(demo.notice.value!.message, contains('Demo · 1 update confirmed'));
      expect(
        (await awaitFormalIO(
          tester,
          () => fixture.sandbox.persistedSnapshot(_localName),
        ))!,
        localBeforeDemo,
      );
      final demoRows = (await awaitFormalIO(
        tester,
        () => fixture.sandbox.persistedSnapshot(_demoName),
      ))!;
      final demoStop = (demoRows['stops']! as List).cast<Map>().singleWhere(
        (row) => row['reference'] == 'REF-A',
      );
      expect(demoStop['operation_id'], isNot(localOperation.operationId));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings save failure retains persisted Online flag and permits retry',
    (tester) async {
      mapTestSize(tester);
      final fixture = await _fixture(tester);
      final transport = FormalHeldTransport();
      final model = (await awaitFormalIO(
        tester,
        () => fixture.createModel(transport: transport),
      ))!;
      await mountFormalApp(
        tester,
        model: model,
        provider: await fixtureProvider(tester),
        controller: _controller(tester),
      );
      final viewport = MapViewport(
        datasetId: model.settings!.datasetId,
        latitude: -33.9,
        longitude: 151.14,
        zoom: 15,
      );
      expect(
        await awaitFormalIO(tester, () => model.saveViewport(viewport)),
        isTrue,
      );
      await tapFormalControl(tester, 'browse-stops');
      const rawQuery = '  HARBOUR  ';
      await revealFormalQueryTools(tester);
      await tester.enterText(
        find.byKey(const ValueKey('stop-search')),
        rawQuery,
      );
      await tapFormalControl(tester, 'filter-pending');
      final resultBefore = model.result;
      final settingsBefore = (await awaitFormalIO(
        tester,
        () => fixture.sandbox.persistedSnapshot(_localName),
      ))!['settings'];
      await awaitFormalIO(tester, () async {
        await (await fixture.sandbox.admin(_localName)).execute('''
          CREATE TRIGGER reject_formal_online BEFORE UPDATE OF online ON delivery_settings
          BEGIN SELECT RAISE(ABORT, 'independent settings rollback'); END
        ''');
      });
      await tapFormalTransition(
        tester,
        model,
        'online-toggle',
        busy: () => model.isChangingOnline,
      );
      expect(model.online, isTrue);
      expect(model.settingsError, isNotNull);
      expect(transport.requests, isEmpty);
      expect(identical(model.result, resultBefore), isTrue);
      expect(model.query.search, rawQuery);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('stop-search')))
            .controller!
            .text,
        rawQuery,
      );
      expect(
        (await awaitFormalIO(
          tester,
          () => fixture.sandbox.persistedSnapshot(_localName),
        ))!['settings'],
        settingsBefore,
      );
      expect(find.byKey(const ValueKey('retry-settings')), findsOneWidget);

      // A successful unrelated write cannot erase a failed Online intention.
      final laterViewport = MapViewport(
        datasetId: viewport.datasetId,
        latitude: -33.902,
        longitude: 151.142,
        zoom: 14,
      );
      expect(
        await awaitFormalIO(tester, () => model.saveViewport(laterViewport)),
        isTrue,
      );
      await pumpFormalFrames(tester);
      expect(model.online, isTrue);
      expect(model.settingsError, isNotNull);
      expect(find.byKey(const ValueKey('retry-settings')), findsOneWidget);
      final persisted =
          ((await awaitFormalIO(
                        tester,
                        () => fixture.sandbox.persistedSnapshot(_localName),
                      ))!['settings']!
                      as List)
                  .single
              as Map;
      expect(persisted['online'], 1);
      expect(persisted['viewport_zoom'], 14);
      await awaitFormalIO(tester, () async {
        await (await fixture.sandbox.admin(
          _localName,
        )).execute('DROP TRIGGER reject_formal_online');
      });
      await tapFormalTransition(
        tester,
        model,
        'retry-settings',
        busy: () => model.isChangingOnline,
      );
      expect(model.online, isFalse);
      expect(model.settingsError, isNull);
      expect(find.byKey(const ValueKey('retry-settings')), findsNothing);
      expect(model.query.search, rawQuery);
      expect(model.query.status, DeliveryStatus.pending);
      await tapFormalControl(tester, 'stop-REF-A');
      await tapFormalTransition(
        tester,
        model,
        'detail-complete',
        busy: () => model.isSaving,
      );
      expect(model.queueCount, 1);
      expect(transport.requests, isEmpty);
      await tapFormalControl(tester, 'detail-return');
      await tapFormalTransition(
        tester,
        model,
        'online-toggle',
        busy: () => model.isChangingOnline,
      );
      final sent = await waitForFormalRequest(tester, transport, 0);
      expect(
        sent.stopId,
        model.stops.singleWhere((stop) => stop.reference == 'REF-A').id,
      );
      expect(model.online, isTrue);
      transport.releaseMatching(0);
      await waitForFormalModel(tester, model, () => !model.isSyncing);
      expect(model.queueCount, 0);
      expect(transport.requests.length, 1);
      expect(model.panel, WorkbenchPanel.list);
      expect(model.query.search, rawQuery);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('formal direct sync notice preserves camera focus and detail', (
    tester,
  ) async {
    mapTestSize(tester);
    final fixture = await _fixture(tester);
    final transport = FormalHeldTransport();
    final model = (await awaitFormalIO(
      tester,
      () => fixture.createModel(transport: transport),
    ))!;
    await awaitFormalIO(tester, () async {
      await model.repository.initialize();
      final stops = await model.repository.loadStops();
      for (final stop in stops.where(
        (stop) => stop.status == DeliveryStatus.pending,
      )) {
        await model.repository.submit(stop.id, DeliveryStatus.completed);
      }
    });
    final controller = _controller(tester);
    await mountFormalApp(
      tester,
      model: model,
      provider: await fixtureProvider(tester),
      controller: controller,
    );
    await waitForFormalRequest(tester, transport, 0);
    transport.fail(0);
    await waitForFormalModel(tester, model, () => !model.isSyncing);
    expect(model.queueCount, 2);
    final mapState = tester.state(find.byKey(const ValueKey('formal-map')));
    await tapFormalControl(tester, 'map-sync');
    await waitForFormalRequest(tester, transport, 1);
    await pumpFormalFrames(tester);
    expect(find.textContaining('Syncing · 0 confirmed'), findsOneWidget);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('workbench-notice')))
          .overlaps(tester.getRect(find.byKey(const ValueKey('map-sync')))),
      isFalse,
    );
    await tapFormalControl(tester, 'nearest-stop');
    final selectedId = model.selectedStop!.id;
    final beforeCamera = controller.mapController.camera;
    final detailResult = model.result;
    await tapFormalControl(tester, 'map-sync');
    expect(model.panel, WorkbenchPanel.detail);
    expect(model.detailContext!.origin, DetailOrigin.nearest);
    expect(model.selectedStop!.id, selectedId);
    expect(identical(model.result, detailResult), isTrue);
    transport.releaseMatching(1);
    await waitForFormalRequest(tester, transport, 2);
    // A second send proves the first ack transaction committed. The independent
    // UI snapshot refresh is asynchronous and must cross its own actual fence.
    await waitForFormalModel(
      tester,
      model,
      () =>
          model.selectedStop?.id == selectedId &&
          model.selectedStop?.acknowledgedAt != null &&
          model.queueCount == 1,
    );
    expect(model.syncProgress.value!.confirmedCount, 1);
    expect(model.panel, WorkbenchPanel.detail);
    expect(model.detailContext!.origin, DetailOrigin.nearest);
    expect(model.selectedStop!.id, selectedId);
    expect(model.selectedStop!.operationId, transport.requests[1].operationId);
    expect(model.selectedStop!.acknowledgedAt, isNotNull);
    expect(controller.mapController.camera.center, beforeCamera.center);
    expect(controller.mapController.camera.zoom, beforeCamera.zoom);
    await tapFormalControl(tester, 'detail-return');
    await tapFormalControl(tester, 'browse-stops');
    const rawQuery = '  no matching customer  ';
    await revealFormalQueryTools(tester);
    await tester.enterText(find.byKey(const ValueKey('stop-search')), rawQuery);
    await pumpFormalFrames(tester);
    expect(model.result.stops, isEmpty);
    expect(model.result.totalQueueCount, 1);
    final cachedResult = model.result;
    var notifications = 0;
    void observed() => notifications++;
    model.addListener(observed);
    await tapFormalControl(tester, 'list-sync');
    model.removeListener(observed);
    expect(
      notifications,
      0,
      reason: 'Joining an active drain is not a business snapshot refresh',
    );
    expect(identical(model.result, cachedResult), isTrue);
    expect(transport.requests.length, 3);
    final field = formalFieldFocus(tester, 'stop-search');
    await tapFormalControl(tester, 'stop-search');
    expect(field.hasFocus, isTrue);
    final focused = FocusManager.instance.primaryFocus;
    expect(
      tester.getRect(find.byKey(const ValueKey('workbench-notice'))).bottom,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const ValueKey('list-workspace'))).top,
      ),
    );
    expect(model.syncProgress.value!.confirmedCount, 1);
    expect(
      (await awaitFormalIO(tester, model.repository.pendingUpdates))!.length,
      1,
    );
    expect(model.query.search, rawQuery);
    expect(FocusManager.instance.primaryFocus, same(focused));
    expect(controller.mapController.camera.center, beforeCamera.center);
    expect(controller.mapController.camera.zoom, beforeCamera.zoom);
    transport.fail(2);
    await waitForFormalModel(tester, model, () => !model.isSyncing);
    expect(model.notice.value!.message, contains('1 confirmed'));
    expect(model.notice.value!.message, contains('1 update still saved'));
    expect(model.result.stops, isEmpty);
    expect(model.result.totalQueueCount, 1);
    expect(model.query.search, rawQuery);
    expect(FocusManager.instance.primaryFocus, same(focused));
    expect(
      identical(
        tester.state(find.byKey(const ValueKey('formal-map'))),
        mapState,
      ),
      isTrue,
    );
    expect(controller.mapController.camera.center, beforeCamera.center);
    expect(transport.maxActive, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'formal automatic enqueue joins one drain and durable pause holds the next immutable event until reconnect',
    (tester) async {
      mapTestSize(tester);
      final fixture = await _fixture(tester);
      final transport = FormalHeldTransport();
      final model = (await awaitFormalIO(
        tester,
        () => fixture.createModel(transport: transport),
      ))!;
      await mountFormalApp(
        tester,
        model: model,
        provider: await fixtureProvider(tester),
        controller: _controller(tester),
      );
      await tapFormalControl(tester, 'nearest-stop');
      await tapFormalTransition(
        tester,
        model,
        'detail-complete',
        busy: () => model.isSaving,
      );
      final first = await waitForFormalRequest(tester, transport, 0);
      await tapFormalControl(tester, 'detail-return');
      await tapFormalControl(tester, 'browse-stops');
      await tapFormalControl(tester, 'stop-REF-B');
      await tapFormalTransition(
        tester,
        model,
        'detail-complete',
        busy: () => model.isSaving,
      );
      final queued = (await awaitFormalIO(
        tester,
        model.repository.pendingUpdates,
      ))!;
      expect(queued.length, 2);
      expect(queued.first.operationId, first.operationId);
      final secondFacts = immutableUpdateFacts(queued.last);
      expect(transport.requests.length, 1);
      await tapFormalTransition(
        tester,
        model,
        'online-toggle',
        busy: () => model.isChangingOnline,
      );
      expect(model.online, isFalse);
      final persisted =
          ((await awaitFormalIO(
                        tester,
                        () => fixture.sandbox.persistedSnapshot(_localName),
                      ))!['settings']!
                      as List)
                  .single
              as Map;
      expect(persisted['online'], 0);
      transport.releaseMatching(0);
      await waitForFormalModel(tester, model, () => !model.isSyncing);
      expect(model.queueCount, 1);
      expect(
        transport.requests.length,
        1,
        reason:
            'Pause may finish its in-flight acknowledgement but cannot send the next event',
      );
      expect(model.syncProgress.value!.confirmedCount, 1);
      expect(
        immutableUpdateFacts(
          (await awaitFormalIO(
            tester,
            model.repository.pendingUpdates,
          ))!.single,
        ),
        secondFacts,
      );
      await tapFormalTransition(
        tester,
        model,
        'online-toggle',
        busy: () => model.isChangingOnline,
      );
      final second = await waitForFormalRequest(tester, transport, 1);
      expect(immutableUpdateFacts(second), secondFacts);
      expect(second.seq, greaterThan(first.seq));
      transport.releaseMatching(1);
      await waitForFormalModel(tester, model, () => !model.isSyncing);
      expect(model.queueCount, 0);
      expect(transport.maxActive, 1);
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.detailContext!.origin, DetailOrigin.list);
      expect(model.selectedStop!.reference, 'REF-B');
      expect(model.selectedStop!.acknowledgedAt!.isUtc, isTrue);
      expect(
        transport.requests.map((update) => update.operationId).toSet().length,
        2,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'formal App keeps committed read-only failure facts across card remount until actual Reload succeeds',
    (tester) async {
      mapTestSize(tester);
      final fixture = await _fixture(tester);
      final (model, fault) = (await awaitFormalIO(
        tester,
        fixture.createReadFaultModel,
      ))!;
      await awaitFormalIO(tester, () => model.settingsStore!.saveOnline(false));
      await mountFormalApp(
        tester,
        model: model,
        provider: await fixtureProvider(tester),
        controller: _controller(tester),
      );
      await tapFormalControl(tester, 'nearest-stop');
      final stopId = model.selectedStop!.id;
      await tapFormalControl(tester, 'detail-fail');
      await tapFormalControl(tester, 'failure-reason-business-closed');
      const rawNote = '  Roller door locked.  ';
      final note = find.byKey(const ValueKey('failure-note'));
      await tester.ensureVisible(note);
      await tester.enterText(note, rawNote);
      await tapFormalTransition(
        tester,
        model,
        'failure-save',
        busy: () => model.isSaving,
      );
      expect(find.byType(DeliveryFailureSheet), findsNothing);
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.hasUnrefreshedResult(stopId), isTrue);
      expect(model.selectedStop!.status, DeliveryStatus.failed);
      expect(model.selectedStop!.reason, 'Business closed');
      expect(model.selectedStop!.note, rawNote.trim());
      expect(model.selectedStop!.operationId, isNull);
      expect(model.selectedStop!.recordedAt, isNull);
      expect(model.loadError, isNotNull);
      expect(model.canRecord, isFalse);
      expect(
        find.byKey(const ValueKey('detail-reload-warning')),
        findsOneWidget,
      );
      final rawCommitted = (await awaitFormalIO(
        tester,
        () => fixture.sandbox.persistedSnapshot(_localName),
      ))!;
      final update = (await awaitFormalIO(
        tester,
        model.repository.pendingUpdates,
      ))!.single;
      expect(update.note, rawNote.trim());
      expect(update.reason, 'Business closed');
      expect(update.recordedAt!.isUtc, isTrue);
      await tapFormalControl(tester, 'detail-close');
      expect(model.panel, WorkbenchPanel.map);
      await tapFormalControl(tester, 'nearest-stop');
      expect(model.selectedStop!.id, stopId);
      expect(model.selectedStop!.status, DeliveryStatus.failed);
      expect(find.byKey(const ValueKey('detail-complete')), findsNothing);
      expect(find.byKey(const ValueKey('detail-fail')), findsNothing);
      expect(
        find.byKey(const ValueKey('detail-reload-warning')),
        findsOneWidget,
      );
      final otherId = model.stops
          .singleWhere((stop) => stop.reference == 'REF-B')
          .id;
      expect(
        await awaitFormalIO(
          tester,
          () => model.submit(otherId, DeliveryStatus.completed),
        ),
        isFalse,
      );
      final afterRejected = (await awaitFormalIO(
        tester,
        () => fixture.sandbox.persistedSnapshot(_localName),
      ))!;
      expect(afterRejected['stops'], rawCommitted['stops']);
      expect(afterRejected['outbox'], rawCommitted['outbox']);
      fault.failReads = false;
      await tapFormalTransition(
        tester,
        model,
        'detail-reload',
        busy: () => model.isLoading,
      );
      expect(model.loadError, isNull);
      expect(model.hasUnrefreshedResult(stopId), isFalse);
      expect(model.selectedStop!.operationId, update.operationId);
      expect(model.selectedStop!.recordedAt, update.recordedAt);
      expect(model.selectedStop!.note, rawNote.trim());
      expect(model.queueCount, 1);
      expect(
        (await awaitFormalIO(
          tester,
          model.repository.pendingUpdates,
        ))!.single.operationId,
        update.operationId,
      );
      expect(
        find.byKey(const ValueKey('detail-recorded-time')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'formal cold App remount resets transients while restoring offline file state and actual gesture viewport',
    (tester) async {
      mapTestSize(tester);
      final fixture = await _fixture(tester);
      final transport = FormalHeldTransport();
      final first = (await awaitFormalIO(
        tester,
        () => fixture.createModel(transport: transport),
      ))!;
      final firstMap = _controller(tester);
      await mountFormalApp(
        tester,
        model: first,
        provider: await fixtureProvider(tester),
        controller: firstMap,
      );
      await tapFormalTransition(
        tester,
        first,
        'online-toggle',
        busy: () => first.isChangingOnline,
      );
      final originalCamera = firstMap.mapController.camera;
      final mapRect = tester.getRect(
        find.byKey(const ValueKey('delivery-map')),
      );
      await tester.dragFrom(
        Offset(mapRect.right - 60, mapRect.top + 170),
        const Offset(-34, 22),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final gestured = firstMap.mapController.camera;
      expect(gestured.center, isNot(originalCamera.center));
      await tapFormalControl(tester, 'nearest-stop');
      await tapFormalTransition(
        tester,
        first,
        'detail-complete',
        busy: () => first.isSaving,
      );
      await tapFormalControl(tester, 'detail-return');
      await tapFormalControl(tester, 'browse-stops');
      await revealFormalQueryTools(tester);
      await tester.enterText(
        find.byKey(const ValueKey('stop-search')),
        ' Harbour ',
      );
      await tapFormalControl(tester, 'filter-completed');
      await tapFormalControl(tester, 'waiting-only');
      await tapFormalControl(tester, 'stop-REF-A');
      expect(first.detailContext!.origin, DetailOrigin.list);
      first.showNotice(
        'Transient session feedback',
        kind: NoticeKind.information,
      );
      final finalCamera = firstMap.mapController.camera;
      await tester.pump(const Duration(milliseconds: 500));
      await unmountFormalApp(tester, first);
      final persisted = (await awaitFormalIO(
        tester,
        () => fixture.sandbox.persistedSnapshot(_localName),
      ))!;
      final settings = (persisted['settings']! as List).single as Map;
      expect(settings['online'], 0);
      expect(
        settings['viewport_latitude'],
        closeTo(finalCamera.center.latitude, 0.0000001),
      );
      expect(
        settings['viewport_longitude'],
        closeTo(finalCamera.center.longitude, 0.0000001),
      );
      expect(settings['viewport_zoom'], finalCamera.zoom);
      final operation = (persisted['outbox']! as List).single as Map;

      final second = (await awaitFormalIO(
        tester,
        () => fixture.createModel(
          transport: transport,
          loadCsv: () async =>
              throw StateError('Cold formal reopen must not read source'),
        ),
      ))!;
      final secondMap = _controller(tester);
      await mountFormalApp(
        tester,
        model: second,
        provider: await fixtureProvider(tester),
        controller: secondMap,
      );
      expect(second.online, isFalse);
      expect(second.panel, WorkbenchPanel.map);
      expect(second.query.search, isEmpty);
      expect(second.query.status, isNull);
      expect(second.query.waitingOnly, isFalse);
      expect(second.detailContext, isNull);
      expect(second.listSession.focusedReference, isNull);
      expect(second.listSession.scrollOffset, 0);
      expect(second.notice.value, isNull);
      expect(second.syncProgress.value, isNull);
      expect(second.isSyncing, isFalse);
      expect(second.isSaving, isFalse);
      expect(find.byKey(const ValueKey('map-search')), findsNothing);
      expect(find.byKey(const ValueKey('list-workspace')), findsNothing);
      expect(find.byKey(const ValueKey('delivery-detail-card')), findsNothing);
      expect(find.byKey(const ValueKey('workbench-notice')), findsNothing);
      expect(
        secondMap.mapController.camera.center.latitude,
        closeTo(finalCamera.center.latitude, 0.0000001),
      );
      expect(
        secondMap.mapController.camera.center.longitude,
        closeTo(finalCamera.center.longitude, 0.0000001),
      );
      expect(secondMap.mapController.camera.zoom, finalCamera.zoom);
      expect(second.queueCount, 1);
      expect(
        (await awaitFormalIO(
          tester,
          second.repository.pendingUpdates,
        ))!.single.operationId,
        operation['operation_id'],
      );
      expect(transport.requests, isEmpty);
      await tapFormalControl(tester, 'map-sync');
      expect(second.notice.value!.message, contains('Offline'));
      expect(second.notice.value!.message, contains('1 saved update'));
      expect(transport.requests, isEmpty);
      expect(
        (await awaitFormalIO(
          tester,
          second.repository.pendingUpdates,
        ))!.single.operationId,
        operation['operation_id'],
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<FormalWorkbenchFixture> _fixture(WidgetTester tester) async {
  final sandbox = (await awaitFormalIO(tester, DeliveryRiskSandbox.create))!;
  final fixture = FormalWorkbenchFixture(sandbox);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await awaitFormalIO(tester, fixture.dispose);
  });
  return fixture;
}

DeliveryMapController _controller(WidgetTester tester) {
  final controller = DeliveryMapController();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  return controller;
}
