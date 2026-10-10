import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/models/workbench.dart';
import 'package:ocean_delivery/ui/delivery/failure/delivery_failure_sheet.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../map/map_fixture.dart';
import '../support/delivery_risk_fixture.dart';
import '../support/risk_workbench_host.dart';

const _databaseName = 'independent-workbench.sqlite';

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  testWidgets(
    'filtered real list retains Other draft after rollback, then returns with truthful global queue',
    (tester) async {
      mapTestSize(tester);
      final sandbox = (await tester.runAsync(DeliveryRiskSandbox.create))!;
      final repository = sandbox.repository(_databaseName);
      late final DeliveryViewModel model;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await completeFixtureIO(tester, () async {
          await model.close();
          await sandbox.dispose();
        }, description: 'risk list VM and actual file sandbox must close');
      });
      await completeFixtureIO(tester, () async {
        model = DeliveryViewModel(
          repository: repository,
          syncCoordinator: SyncCoordinator(repository: repository),
        );
        await model.load();
      }, description: 'risk list VM creation and file load must finish');
      model.setSearch('HARBOUR');
      model.setStatus(DeliveryStatus.pending);
      model.openList();
      await tester.pumpWidget(RiskWorkbenchHost(model: model));
      await tapRiskControl(tester, 'stop-REF-A');
      final stopId = model.selectedStop!.id;
      expect(model.detailContext!.origin, DetailOrigin.list);
      expect(model.result.matchedCount, 2);
      await tester.runAsync(() async {
        await (await sandbox.admin(_databaseName)).execute('''
          CREATE TRIGGER reject_risk_outbox BEFORE INSERT ON outbox
          BEGIN SELECT RAISE(ABORT, 'independent result rollback'); END
        ''');
      });
      await tapRiskControl(tester, 'detail-fail');
      await tapRiskControl(tester, 'failure-reason-other');
      final note = find.byKey(const ValueKey('failure-note'));
      await tester.ensureVisible(note);
      const rawDraft = '  Gate locked; phone unanswered.  \n';
      await tester.enterText(note, rawDraft);
      await tapRiskSave(tester, model, 'failure-save');
      expect(find.byType(DeliveryFailureSheet), findsOneWidget);
      expect(tester.widget<TextField>(note).controller!.text, rawDraft);
      expect(model.selectedStop!.status, DeliveryStatus.pending);
      expect(model.result.matchedCount, 2);
      expect(model.queueCount, 0);
      final afterFailure = (await tester.runAsync(
        repository.loadStops,
      ))!.singleWhere((stop) => stop.id == stopId);
      expect(afterFailure.recordedAt, isNull);
      expect(afterFailure.operationId, isNull);
      expect((await tester.runAsync(repository.pendingUpdates))!, isEmpty);

      await tester.runAsync(() async {
        await (await sandbox.admin(
          _databaseName,
        )).execute('DROP TRIGGER reject_risk_outbox');
      });
      await tapRiskSave(tester, model, 'failure-save');
      expect(find.byType(DeliveryFailureSheet), findsNothing);
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.selectedStop!.id, stopId);
      expect(model.selectedStop!.status, DeliveryStatus.failed);
      expect(model.selectedStop!.reason, rawDraft.trim());
      expect(model.selectedStop!.note, isNull);
      expect(model.result.stops.single.reference, 'REF-B');
      final update = (await tester.runAsync(repository.pendingUpdates))!.single;
      expect(update.stopId, stopId);
      expect(update.operationId, model.selectedStop!.operationId);
      expect(update.recordedAt, model.selectedStop!.recordedAt);
      expect(update.recordedAt!.isUtc, isTrue);
      expect(update.reason, rawDraft.trim());
      expect(update.note, isNull);

      await tapRiskControl(tester, 'detail-return');
      expect(model.panel, WorkbenchPanel.list);
      expect(model.query.search, 'HARBOUR');
      expect(model.query.status, DeliveryStatus.pending);
      expect(find.byKey(const ValueKey('stop-REF-A')), findsNothing);
      expect(find.byKey(const ValueKey('stop-REF-B')), findsOneWidget);
      expect(FocusManager.instance.primaryFocus!.debugLabel, 'Close stop list');
      await tapRiskControl(tester, 'waiting-only');
      expect(model.result.stops, isEmpty);
      expect(model.result.totalQueueCount, 1);
      expect(
        find.text('0 matching stops · 1 waiting in total'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tile failure and cache-clear failure preserve actual saved result and restored viewport',
    (tester) async {
      mapTestSize(tester);
      final provider = await fixtureProvider(tester);
      provider.fail = true;
      final sandbox = (await tester.runAsync(DeliveryRiskSandbox.create))!;
      final repository = sandbox.repository(_databaseName);
      late final DeliveryViewModel model;
      final controller = DeliveryMapController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await completeFixtureIO(tester, () async {
          await model.close();
          await sandbox.dispose();
        }, description: 'risk map VM and actual file sandbox must close');
      });
      await completeFixtureIO(tester, () async {
        model = DeliveryViewModel(
          repository: repository,
          syncCoordinator: SyncCoordinator(repository: repository),
        );
        await model.load();
      }, description: 'risk map VM creation and file load must finish');
      final settings = (await tester.runAsync(repository.loadSettings))!;
      final viewport = MapViewport(
        datasetId: settings.datasetId,
        latitude: -33.8995,
        longitude: 151.138,
        zoom: 15,
      );
      await tester.runAsync(() => repository.saveViewport(viewport));
      model.setSearch('Harbour A');
      model.setStatus(DeliveryStatus.pending);
      var rejectClear = true;
      await tester.pumpWidget(
        RiskWorkbenchHost(
          model: model,
          viewport: viewport,
          mapController: controller,
          tileProvider: provider,
          tileCacheClearer: () async {
            if (rejectClear) throw StateError('Independent tile cache failure');
            await clearBuiltInTileCache();
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.tileStatus.value, MapTileStatus.error);
      final restoredCamera = controller.mapController.camera;
      expect(restoredCamera.center.latitude, viewport.latitude);
      expect(restoredCamera.center.longitude, viewport.longitude);
      expect(restoredCamera.zoom, viewport.zoom);
      final stop = model.result.stops.single;
      await tapRiskControl(tester, 'map-stop-${stop.reference}');
      expect(model.selectedStop!.id, stop.id);
      expect(model.detailContext!.origin, DetailOrigin.map);
      await tapRiskSave(tester, model, 'detail-complete');
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.selectedStop!.status, DeliveryStatus.completed);
      expect(model.result.stops, isEmpty);
      await tapRiskControl(tester, 'detail-return');
      expect(model.panel, WorkbenchPanel.map);

      final beforeClear = (await tester.runAsync(
        () => sandbox.persistedSnapshot(_databaseName),
      ))!;
      final clearFailure = await tester.runAsync(() async {
        final observed = controller.clearTileCache().then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        await tester.pump();
        return observed.timeout(const Duration(seconds: 5));
      });
      expect(clearFailure, isA<StateError>());
      await tester.pumpAndSettle();
      expect(
        (await tester.runAsync(
          () => sandbox.persistedSnapshot(_databaseName),
        ))!,
        beforeClear,
      );
      expect(controller.mapController.camera.center, restoredCamera.center);
      expect(controller.mapController.camera.zoom, restoredCamera.zoom);

      final cachedFile = File('${sandbox.directory.path}/fm_cache/risk-tile');
      await tester.runAsync(() async {
        final cache = BuiltInMapCachingProvider.getOrCreateInstance(
          cacheDirectory: sandbox.directory.path,
          maxCacheSize: null,
        );
        expect(await cache.getTile('http://127.0.0.1/risk/0/0/0.png'), isNull);
        await cachedFile.writeAsString('independent cached tile');
      });
      rejectClear = false;
      provider.fail = false;
      final cleared = await tester.runAsync(() async {
        final clearing = controller.clearTileCache();
        await tester.pump();
        await clearing.timeout(const Duration(seconds: 5));
        return true;
      });
      expect(cleared, isTrue);
      await tester.pumpAndSettle();
      expect(controller.tileStatus.value, MapTileStatus.ready);
      expect(await tester.runAsync(cachedFile.exists), isFalse);
      expect(
        (await tester.runAsync(
          () => sandbox.persistedSnapshot(_databaseName),
        ))!,
        beforeClear,
      );
      expect(controller.mapController.camera.center, restoredCamera.center);
      expect(controller.mapController.camera.zoom, restoredCamera.zoom);
      expect(model.result.stops, isEmpty);
      expect(model.queueCount, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
