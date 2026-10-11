import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/app/ocean_delivery_app.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery/failure/delivery_failure_sheet.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery_screen.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';

import 'map/map_fixture.dart';
import 'ui/fake_delivery_repository.dart';

Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 30),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 2),
);

class _RootAppSession {
  _RootAppSession(this.model, this.map, this.tiles);
  final DeliveryViewModel model;
  final DeliveryMapController map;
  final FixtureTileProvider tiles;
  int factoryCalls = 0;
}

class _BootstrapRepository extends FakeDeliveryRepository {
  int initializeCalls = 0;
  int closeCalls = 0;
  final _closed = Completer<void>();
  Future<void> get closed => _closed.future;

  @override
  Future<void> initialize() {
    initializeCalls++;
    return super.initialize();
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await super.close();
    if (!_closed.isCompleted) _closed.complete();
  }
}

Future<_RootAppSession> _startApp(
  WidgetTester tester,
  FakeDeliveryRepository repository, {
  int bootstrapFailures = 0,
}) async {
  mapTestSize(tester);
  final tiles = await fixtureProvider(tester);
  final map = fixtureController(tester);
  final model = DeliveryViewModel(
    repository: repository,
    automaticSync: true,
    syncCoordinator: SyncCoordinator(
      repository: repository,
      transport: const UnavailableTransport(),
    ),
  );
  final session = _RootAppSession(model, map, tiles);
  addTearDown(() async {
    await performFixtureUI(
      tester,
      () => tester.pumpWidget(const SizedBox()),
      description: 'root app must unmount before model cleanup',
    );
    await completeFixtureIO(
      tester,
      model.close,
      description: 'root app must close its actual model',
    );
  });
  await performFixtureUI(
    tester,
    () => tester.pumpWidget(
      OceanDeliveryApp(
        createViewModel: () async {
          session.factoryCalls++;
          if (session.factoryCalls <= bootstrapFailures) {
            throw StateError('fixture cannot open database');
          }
          return model;
        },
        mapController: map,
        tileProvider: tiles,
        tileUrlTemplate: 'http://127.0.0.1/root-fixture/{z}/{x}/{y}.png',
      ),
    ),
    description: 'root app must mount through its actual factory',
  );
  await completeFixtureIO(
    tester,
    model.load,
    description: 'root app initial repository load must complete',
  );
  await settle(tester);
  if (model.loadError == null && bootstrapFailures == 0) {
    await waitForFixtureMap(tester, map);
  }
  return session;
}

Future<void> reveal(
  WidgetTester tester,
  Finder target, {
  double alignment = .5,
}) async {
  // Finish a text field's deferred caret reveal before the user's next scroll.
  await settle(tester);
  expect(target, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(target), alignment: alignment);
  await settle(tester);
  expect(target.hitTestable(), findsOneWidget);
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await reveal(tester, target);
  final model = tester
      .widget<DeliveryScreen>(find.byType(DeliveryScreen))
      .viewModel;
  await performFixtureUI(
    tester,
    () => tester.tap(target.hitTestable()),
    description: '$key must receive its actual UI tap',
  );
  await _waitForModelIdle(tester, model);
  await settle(tester);
}

Future<void> _waitForModelIdle(
  WidgetTester tester,
  DeliveryViewModel model,
) async {
  final done = Completer<void>();
  var waiting = true;
  var checking = false;
  bool busy() =>
      model.isLoading ||
      model.isSaving ||
      model.isSyncing ||
      model.isChangingOnline;
  void observe() {
    if (checking || busy()) return;
    checking = true;
    // Saving can notify idle immediately before starting automatic sync.
    // Require idle on the next frame, after that whole transition has run.
    tester.binding.addPostFrameCallback((_) {
      checking = false;
      if (waiting && !busy() && !done.isCompleted) done.complete();
    });
  }

  model.addListener(observe);
  try {
    observe();
    await completeFixtureIO(
      tester,
      () => done.future,
      description: 'actual root model loading, save and sync must finish',
      diagnostics: () =>
          'loading=${model.isLoading}, saving=${model.isSaving}, '
          'syncing=${model.isSyncing}, changingOnline=${model.isChangingOnline}',
    );
  } finally {
    waiting = false;
    model.removeListener(observe);
  }
}

Future<void> _openNearest(
  WidgetTester tester,
  _RootAppSession session, {
  String? search,
}) async {
  // Query preparation is setup; opening the detail is always the real UI action.
  if (search != null) {
    session.model.setSearch(search);
    await settle(tester);
  }
  await tapKey(tester, 'nearest-stop');
  expect(session.model.panel, WorkbenchPanel.detail);
  expect(session.model.detailContext!.origin, DetailOrigin.nearest);
  expect(find.byKey(const ValueKey('delivery-detail-card')), findsOneWidget);
}

void expectTerminalDetail(DeliveryStatus status) {
  expect(find.byKey(const ValueKey('delivery-detail-card')), findsOneWidget);
  expect(
    find.text(
      status == DeliveryStatus.completed
          ? 'Delivery completed'
          : 'Delivery failed',
    ),
    findsOneWidget,
  );
  expect(find.byKey(const ValueKey('detail-complete')), findsNothing);
  expect(find.byKey(const ValueKey('detail-fail')), findsNothing);
}

void main() {
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  testWidgets('loads all stops and states the local service boundary', (
    tester,
  ) async {
    final repository = FakeDeliveryRepository();
    final session = await _startApp(tester, repository);

    expect(find.byKey(const ValueKey('delivery-map')), findsOneWidget);
    expect(find.byKey(const ValueKey('delivery-overview')), findsOneWidget);
    expect(find.text('Sydney · 30 stops'), findsOneWidget);
    expect(find.text('Local client · service unavailable'), findsOneWidget);
    expect(find.text('All 30'), findsOneWidget);
    expect(find.text('Pending 29'), findsOneWidget);
    expect(find.text('Completed 0'), findsOneWidget);
    expect(find.text('Failed 1'), findsOneWidget);
    expect(find.text('29 left to deliver'), findsOneWidget);
    expect(find.text('0 waiting to sync'), findsOneWidget);
    expect(find.text('Test reference'), findsOneWidget);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    expect(session.tiles.requestedCoordinates, isNotEmpty);
    expect(session.map.tileStatus.value, MapTileStatus.ready);
    expect(session.model.result.stops, hasLength(30));

    await tapKey(tester, 'browse-stops');
    expect(session.model.panel, WorkbenchPanel.list);
    expect(find.text('Stops on the map'), findsOneWidget);
    expect(find.text('30 stops · Nearest first'), findsOneWidget);
    await tapKey(tester, 'list-query-controls');
    expect(find.text('30 matching stops · 0 waiting in total'), findsOneWidget);
    await tapKey(tester, 'close-list');
    await tapKey(tester, 'header-filter-failed');
    await _openNearest(tester, session);
    expect(session.model.selectedStop!.reference, 'REF-30');
    expectTerminalDetail(DeliveryStatus.failed);
    await tapKey(tester, 'detail-return');
    expect(session.model.panel, WorkbenchPanel.map);
    await tapKey(tester, 'header-filter-all');
    expect(session.model.result.stops, hasLength(30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('completion is local and unavailable sync retains its event', (
    tester,
  ) async {
    final repository = FakeDeliveryRepository();
    final session = await _startApp(tester, repository);
    await _openNearest(tester, session);
    expect(session.model.selectedStop!.id, 'stop-0');
    await tapKey(tester, 'detail-complete');

    expect(repository.stops.first.status, DeliveryStatus.completed);
    expect(repository.queue, hasLength(1));
    final event = repository.queue.single;
    expect(event.stopId, 'stop-0');
    expect(event.status, DeliveryStatus.completed);
    expect(event.operationId, repository.stops.first.operationId);
    expect(repository.stops.first.recordedAt, isNotNull);
    expect(session.model.panel, WorkbenchPanel.detail);
    expectTerminalDetail(DeliveryStatus.completed);
    expect(find.text('Saved locally. Waiting to sync.'), findsOneWidget);
    expect(
      find.text('Service unavailable · 1 update still saved. Try again.'),
      findsOneWidget,
    );

    final camera = session.map.mapController.camera;
    await tapKey(tester, 'map-sync');
    expect(repository.queue.single.operationId, event.operationId);
    expect(repository.submitCalls, 1);
    expect(session.model.queueCount, 1);
    expect(session.model.panel, WorkbenchPanel.detail);
    expectTerminalDetail(DeliveryStatus.completed);
    expect(session.map.mapController.camera.center, camera.center);
    expect(session.map.mapController.camera.zoom, camera.zoom);
    expect(
      find.text('Service unavailable · 1 update still saved. Try again.'),
      findsOneWidget,
    );
    await tapKey(tester, 'detail-return');
    expect(session.model.panel, WorkbenchPanel.map);
    expect(find.text('28 left to deliver'), findsOneWidget);
    expect(find.text('1 waiting to sync'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed save retains typed reason and retry persists it', (
    tester,
  ) async {
    final repository = FakeDeliveryRepository()..failSubmit = true;
    final session = await _startApp(tester, repository);
    await _openNearest(tester, session);
    await tapKey(tester, 'detail-fail');
    await tapKey(tester, 'failure-save');
    expect(find.text('Choose a reason to continue.'), findsOneWidget);
    expect(repository.submitCalls, 0);
    await tapKey(tester, 'failure-reason-other');
    await tapKey(tester, 'failure-save');
    expect(find.text('Enter a reason to continue.'), findsOneWidget);
    expect(repository.submitCalls, 0);

    const typedReason = '  Access gate is locked; try tomorrow  ';
    final note = find.byKey(const ValueKey('failure-note'));
    await reveal(tester, note);
    await tester.enterText(note, typedReason);
    await tapKey(tester, 'failure-save');
    expect(
      find.text('Could not save. Your choices and note are kept. Try again.'),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(note).controller!.text, typedReason);
    expect(find.byType(DeliveryFailureSheet), findsOneWidget);
    expect(repository.stops.first.status, DeliveryStatus.pending);
    expect(repository.queue, isEmpty);
    expect(repository.submitCalls, 1);

    repository.failSubmit = false;
    await tapKey(tester, 'failure-save');
    expect(find.byType(DeliveryFailureSheet), findsNothing);
    expect(repository.stops.first.status, DeliveryStatus.failed);
    expect(
      repository.stops.first.reason,
      'Access gate is locked; try tomorrow',
    );
    expect(repository.stops.first.note, isNull);
    expect(
      repository.queue.single.reason,
      'Access gate is locked; try tomorrow',
    );
    expect(
      repository.queue.single.note,
      isNull,
      reason: 'Other text is the reason',
    );
    expect(session.model.panel, WorkbenchPanel.detail);
    expectTerminalDetail(DeliveryStatus.failed);
    expect(find.text('Access gate is locked; try tomorrow'), findsOneWidget);

    // The same root flow also preserves a preset's independent optional note.
    await tapKey(tester, 'detail-return');
    await _openNearest(tester, session, search: 'REF-2');
    expect(session.model.selectedStop!.id, 'stop-1');
    await tapKey(tester, 'detail-fail');
    await tapKey(tester, 'failure-reason-business-closed');
    await reveal(tester, find.byKey(const ValueKey('failure-note')));
    await tester.enterText(
      find.byKey(const ValueKey('failure-note')),
      '  Shutters were locked at 09:00  ',
    );
    await tapKey(tester, 'failure-save');
    expect(repository.stops[1].reason, 'Business closed');
    expect(repository.stops[1].note, 'Shutters were locked at 09:00');
    expect(repository.queue.last.note, 'Shutters were locked at 09:00');
    expect(session.model.panel, WorkbenchPanel.detail);
    expectTerminalDetail(DeliveryStatus.failed);
    expect(find.text('Shutters were locked at 09:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'completion save error keeps the stop pending and permits retry',
    (tester) async {
      final repository = FakeDeliveryRepository()..failSubmit = true;
      final session = await _startApp(tester, repository);
      await _openNearest(tester, session);
      await tapKey(tester, 'detail-complete');
      expect(
        find.text(
          'Could not save. The stop has not changed. Please try again.',
        ),
        findsOneWidget,
      );
      expect(repository.stops.first.status, DeliveryStatus.pending);
      expect(repository.queue, isEmpty);
      expect(repository.submitCalls, 1);
      expect(session.model.panel, WorkbenchPanel.detail);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('detail-complete')))
            .onPressed,
        isNotNull,
      );

      repository.failSubmit = false;
      await tapKey(tester, 'detail-complete');
      expect(repository.stops.first.status, DeliveryStatus.completed);
      expect(repository.queue, hasLength(1));
      expect(repository.submitCalls, 2);
      expectTerminalDetail(DeliveryStatus.completed);
      expect(session.model.panel, WorkbenchPanel.detail);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('initial repository error is retryable', (tester) async {
    final repository = FakeDeliveryRepository()..failInitialization = true;
    final session = await _startApp(tester, repository);
    expect(
      find.text('Could not load deliveries. Reload to try again.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('delivery-map')), findsNothing);
    expect(find.text('Customer 1'), findsNothing);
    repository.failInitialization = false;
    await tapKey(tester, 'reload-data');
    expect(find.text('Sydney · 30 stops'), findsOneWidget);
    expect(find.byKey(const ValueKey('delivery-map')), findsOneWidget);
    expect(
      find.text('Could not load deliveries. Reload to try again.'),
      findsNothing,
    );
    await _openNearest(tester, session);
    expect(find.text('Customer 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'database bootstrap error can reopen through its injected factory',
    (tester) async {
      mapTestSize(tester);
      final tiles = await fixtureProvider(tester);
      final map = fixtureController(tester);
      final gate = Completer<void>();
      final models = <DeliveryViewModel>[];
      final repositories = <_BootstrapRepository>[];
      var factoryCalls = 0;
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await performFixtureUI(
          tester,
          () => tester.pumpWidget(const SizedBox()),
          description: 'bootstrap app must unmount before fallback cleanup',
        );
        for (final model in models) {
          await completeFixtureIO(
            tester,
            model.close,
            description: 'each bootstrap-created actual model must close',
          );
        }
      });
      await performFixtureUI(
        tester,
        () => tester.pumpWidget(
          OceanDeliveryApp(
            createViewModel: () async {
              factoryCalls++;
              if (factoryCalls == 1) {
                throw StateError('fixture cannot open database');
              }
              final repository = _BootstrapRepository();
              final model = DeliveryViewModel(
                repository: repository,
                automaticSync: true,
                syncCoordinator: SyncCoordinator(
                  repository: repository,
                  transport: const UnavailableTransport(),
                ),
              );
              repositories.add(repository);
              models.add(model);
              await gate.future;
              return model;
            },
            mapController: map,
            tileProvider: tiles,
            tileUrlTemplate:
                'http://127.0.0.1/bootstrap-fixture/{z}/{x}/{y}.png',
          ),
        ),
        description: 'bootstrap app must mount through its actual factory',
      );
      await settle(tester);
      expect(
        find.text('Could not open the local database. Try again.'),
        findsOneWidget,
      );
      expect(factoryCalls, 1);
      expect(find.byKey(const ValueKey('delivery-map')), findsNothing);
      final retry = find.byKey(const ValueKey('retry-bootstrap'));
      expect(retry.hitTestable(), findsOneWidget);
      // Both real UI taps reach the still-rendered button before a frame;
      // the reserved opening Future must join them while the factory is held.
      await performFixtureUI(
        tester,
        () async {
          await tester.tap(retry.hitTestable());
          await tester.tap(retry.hitTestable());
        },
        description: 'both bootstrap retry taps must reach the held factory',
      );
      await tester.pump();
      expect(factoryCalls, 2, reason: 'one failed call plus one joined retry');
      expect(
        models,
        hasLength(1),
        reason: 'the factory creates one actual model',
      );
      expect(repositories, hasLength(1));
      expect(repositories.single.initializeCalls, 0);
      expect(repositories.single.closeCalls, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey('delivery-map')), findsNothing);

      gate.complete();
      await completeFixtureIO(
        tester,
        models.single.load,
        description: 'the one released bootstrap model must finish loading',
      );
      await settle(tester);
      await waitForFixtureMap(tester, map);
      expect(factoryCalls, 2);
      expect(models, hasLength(1));
      expect(repositories.single.initializeCalls, 1);
      expect(find.text('Sydney · 30 stops'), findsOneWidget);
      expect(find.byKey(const ValueKey('delivery-map')), findsOneWidget);
      final session = _RootAppSession(models.single, map, tiles);
      await _openNearest(tester, session);
      expect(find.text('Customer 1'), findsOneWidget);
      expect(repositories.single.closeCalls, 0);

      // Check app-owned disposal before teardown's fallback cleanup runs.
      await performFixtureUI(
        tester,
        () => tester.pumpWidget(const SizedBox()),
        description: 'actual bootstrap app unmount must finish',
      );
      await completeFixtureIO(
        tester,
        () => repositories.single.closed,
        description: 'app-owned actual repository close must complete',
      );
      expect(repositories.single.closeCalls, 1);
      expect(
        () => models.single.addListener(() {}),
        throwsFlutterError,
        reason: 'the actual ViewModel has been disposed, not merely detached',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'persisted save is distinguished from subsequent refresh failure',
    (tester) async {
      final repository = FakeDeliveryRepository()..failRefreshAfterSave = true;
      final session = await _startApp(tester, repository);
      await _openNearest(tester, session);
      await tapKey(tester, 'detail-complete');
      expect(repository.stops.first.status, DeliveryStatus.completed);
      expect(repository.queue, hasLength(1));
      expect(repository.submitCalls, 1);
      expect(session.model.loadError, isNotNull);
      expect(session.model.hasUnrefreshedResult('stop-0'), isTrue);
      expect(session.model.selectedStop!.status, DeliveryStatus.completed);
      expect(session.model.selectedStop!.operationId, isNull);
      expect(session.model.selectedStop!.recordedAt, isNull);
      expectTerminalDetail(DeliveryStatus.completed);
      expect(find.text('Saved locally. Reload required.'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-reload')), findsOneWidget);
      expect(
        find.text(
          'Could not save. The stop has not changed. Please try again.',
        ),
        findsNothing,
      );

      // Close and reopen the actual card: committed facts belong to the VM.
      await tapKey(tester, 'detail-close');
      expect(session.model.panel, WorkbenchPanel.map);
      await _openNearest(tester, session);
      expectTerminalDetail(DeliveryStatus.completed);
      expect(find.text('Saved locally. Reload required.'), findsOneWidget);
      expect(find.text('Saved locally · reload required'), findsOneWidget);
      expect(
        find.text('Waiting to sync'),
        findsNothing,
        reason: 'a failed read cannot prove current acknowledgement state',
      );
      expect(session.model.canRecord, isFalse);
      expect(repository.submitCalls, 1);

      repository.failRefreshAfterSave = false;
      await tapKey(tester, 'detail-reload');
      expect(session.model.loadError, isNull);
      expect(session.model.hasUnrefreshedResult('stop-0'), isFalse);
      expect(
        session.model.selectedStop!.operationId,
        repository.stops.first.operationId,
      );
      expect(
        session.model.selectedStop!.recordedAt,
        repository.stops.first.recordedAt,
      );
      expect(session.model.queueCount, 1);
      expect(repository.submitCalls, 1);
      expectTerminalDetail(DeliveryStatus.completed);
      expect(find.text('Saved locally. Reload required.'), findsNothing);
      expect(
        find.byKey(const ValueKey('detail-recorded-time')),
        findsOneWidget,
      );
      expect(find.text('Waiting to sync'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failure form scrolls above the keyboard without overflow', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final repository = FakeDeliveryRepository();
    final session = await _startApp(tester, repository);
    await _openNearest(tester, session);
    await tapKey(tester, 'detail-fail');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tapKey(tester, 'failure-reason-other');
    final note = find.byKey(const ValueKey('failure-note'));
    await reveal(tester, note);
    await tester.enterText(note, 'No recipient at the address');
    await settle(tester);
    final scrollRect = tester.getRect(
      find.byKey(const ValueKey('failure-scroll')),
    );
    // Drag the outer form padding, outside the note's nested text scroller.
    await tester.dragFrom(
      Offset(scrollRect.left + 8, scrollRect.center.dy),
      const Offset(0, -220),
    );
    await settle(tester);
    final save = find.byKey(const ValueKey('failure-save'));
    await reveal(tester, save, alignment: 1);
    final bounds = tester.getRect(save);
    final viewport = tester.getRect(
      find.byKey(const ValueKey('failure-scroll')),
    );
    final geometry = 'button=$bounds scroll=$viewport keyboardTop=${844 - 300}';
    expect(bounds.left, greaterThanOrEqualTo(viewport.left), reason: geometry);
    expect(bounds.right, lessThanOrEqualTo(viewport.right), reason: geometry);
    expect(bounds.top, greaterThanOrEqualTo(viewport.top), reason: geometry);
    expect(bounds.bottom, lessThanOrEqualTo(viewport.bottom), reason: geometry);
    expect(bounds.bottom, lessThanOrEqualTo(844 - 300), reason: geometry);
    expect(save.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tapKey(tester, 'failure-save');
    expect(repository.stops.first.reason, 'No recipient at the address');
    expect(repository.queue, hasLength(1));
    expect(find.byType(DeliveryFailureSheet), findsNothing);
    expect(session.model.panel, WorkbenchPanel.detail);
    expectTerminalDetail(DeliveryStatus.failed);
    expect(tester.takeException(), isNull);
  });
}
