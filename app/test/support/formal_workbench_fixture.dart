import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/app/ocean_delivery_app.dart';
import 'package:ocean_delivery/app/runtime_configuration.dart';
import 'package:ocean_delivery/data/delivery/delivery_repository.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/main.dart' as formal;
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/models/workbench.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../integration_test/support/delivery_fault_fixtures.dart';
import '../map/map_fixture.dart';
import 'delivery_risk_fixture.dart';

const formalWaitBound = Duration(seconds: 5);

/// Real formal factory, App and file database with first-mount local tiles.
/// It never runs the native probe, replaces the formal screen, or uses a service.
class FormalWorkbenchFixture {
  FormalWorkbenchFixture(this.sandbox);

  final DeliveryRiskSandbox sandbox;
  final models = <DeliveryViewModel>[];
  final transports = <FormalHeldTransport>[];
  final events = <Map<String, Object?>>[];

  Future<DeliveryViewModel> createModel({
    String mode = 'local-client',
    SyncTransport? transport,
    Future<String> Function()? loadCsv,
  }) async {
    if (transport is FormalHeldTransport) transports.add(transport);
    final model = await formal.createLocalViewModel(
      configuration: RuntimeConfiguration.parse(mode),
      databaseFactoryOverride: databaseFactoryFfi,
      databaseDirectory: sandbox.directory.path,
      loadCsv: loadCsv ?? () async => independentRiskCsv,
      transport: transport,
      requestTimeout: const Duration(seconds: 15),
      eventSink: events.add,
    );
    models.add(model);
    return model;
  }

  /// Narrow App/VM fault-injection boundary. The repository/settings/mode are
  /// produced by the formal factory; this one case explicitly decorates reads.
  /// Other cases consume the factory's exact returned model without replacing it.
  Future<(DeliveryViewModel, CommittedReadFailure)>
  createReadFaultModel() async {
    final core = await createModel();
    await core.close();
    final fault = CommittedReadFailure(core.repository);
    final model = DeliveryViewModel(
      repository: fault,
      settingsStore: core.settingsStore,
      mode: core.mode,
      automaticSync: core.automaticSync,
      syncCoordinator: SyncCoordinator(repository: fault),
    );
    models.add(model);
    return (model, fault);
  }

  Future<void> dispose() async {
    final closing = [for (final model in models) model.close()];
    for (final transport in transports) {
      transport.releaseAllMatching();
    }
    await Future.wait(closing).timeout(formalWaitBound);
    await sandbox.dispose();
  }
}

/// Each request has a separate explicit response fence. No network or delay.
class FormalHeldTransport implements SyncTransport {
  final requests = <PendingUpdate>[];
  final _replies = <Completer<Ack>>[];
  final _arrivals = <int, Completer<PendingUpdate>>{};
  int active = 0;
  int maxActive = 0;

  @override
  Future<Ack> send(PendingUpdate update) async {
    final index = requests.length;
    requests.add(update);
    final reply = Completer<Ack>();
    _replies.add(reply);
    active++;
    if (active > maxActive) maxActive = active;
    _arrivals.remove(index)?.complete(update);
    try {
      return await reply.future;
    } finally {
      active--;
    }
  }

  Future<PendingUpdate> request(int index) => index < requests.length
      ? Future.value(requests[index])
      : _arrivals.putIfAbsent(index, Completer<PendingUpdate>.new).future;

  void releaseMatching(int index) =>
      _replies[index].complete(fixtureMatchingAck(requests[index]));

  void fail(int index) =>
      _replies[index].completeError(StateError('Held test service failure'));

  void releaseAllMatching() {
    for (var index = 0; index < _replies.length; index++) {
      if (!_replies[index].isCompleted) releaseMatching(index);
    }
  }
}

/// A successful SQLite submit is not altered. Only its subsequent snapshot
/// reads fail until the independent test enables them and presses actual Reload.
class CommittedReadFailure implements DeliveryRepository {
  CommittedReadFailure(this.delegate);
  final DeliveryRepository delegate;
  bool failReads = false;

  @override
  Future<void> initialize() => delegate.initialize();
  @override
  Future<List<Stop>> loadStops() => failReads
      ? Future.error(StateError('Independent committed snapshot read failure'))
      : delegate.loadStops();
  @override
  Future<void> submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
    String? note,
  }) async {
    await delegate.submit(stopId, status, reason: reason, note: note);
    failReads = true;
  }

  @override
  Future<List<PendingUpdate>> pendingUpdates() => delegate.pendingUpdates();
  @override
  Future<bool> acknowledge(Ack ack) => delegate.acknowledge(ack);
  @override
  Future<void> close() => delegate.close();
}

Future<void> mountFormalApp(
  WidgetTester tester, {
  required DeliveryViewModel model,
  required FixtureTileProvider provider,
  required DeliveryMapController controller,
}) async {
  final mounted = await awaitGuardedFormalIO(tester, (uiFinished) async {
    await tester.pumpWidget(
      OceanDeliveryApp(
        createViewModel: () async => model,
        demo: model.mode == ClientMode.demo,
        tileProvider: provider,
        tileUrlTemplate: 'http://127.0.0.1/formal-only/{z}/{x}/{y}.png',
        mapController: controller,
      ),
    );
    uiFinished();
    await model.load();
    return true;
  });
  expect(mounted, isTrue);
  await pumpFormalFrames(tester);
  expect(find.byKey(const ValueKey('formal-map')), findsOneWidget);
  expect(provider.requestedCoordinates, isNotEmpty);
}

/// Finite frame advancement also works while the real sync animation is active.
/// It is not a retry loop, a settle timeout, or an async I/O completion assertion.
Future<void> pumpFormalFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

/// A real SQLite response can resume a continuation registered by a fake-zone
/// viewport Timer. Advancing pending frames/microtasks while yielding the real
/// event loop prevents that test-only scheduling deadlock. The actual operation
/// still owns success; a real five-second deadline fails a missing completion.
Future<T?> awaitFormalIO<T>(WidgetTester tester, Future<T> Function() action) =>
    _awaitFormalOperation(tester, (_) => action(), guardedUI: false);

/// Both the UI-finished fence and the deadline belong to runAsync's real zone.
/// Call uiFinished only after the awaited guarded tester operation returns.
Future<T?> awaitGuardedFormalIO<T>(
  WidgetTester tester,
  Future<T> Function(VoidCallback uiFinished) action,
) => _awaitFormalOperation(tester, action, guardedUI: true);

Future<T?> _awaitFormalOperation<T>(
  WidgetTester tester,
  Future<T> Function(VoidCallback uiFinished) action, {
  required bool guardedUI,
}) => tester.runAsync(() async {
  final uiFinished = Completer<void>();
  var finished = false;
  final deadline = action(uiFinished.complete).timeout(formalWaitBound);
  // Observe termination only; awaiting the original deadline below propagates
  // its error unchanged. No fallback value or success is supplied on failure.
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
  // A guarded mount/tap inside action must finish before this sibling loop
  // calls pump. The same original deadline includes that UI fence; its error
  // also releases this wait if the UI action itself never completes.
  if (guardedUI) {
    await Future.any<void>([uiFinished.future, deadline.then<void>((_) {})]);
  }
  while (!finished) {
    await tester.pump();
    await Future<void>.delayed(Duration.zero);
  }
  return deadline;
});

Future<void> revealFormalControl(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  if (key.startsWith('stop-REF-') && target.evaluate().isEmpty) {
    final scrollable = find
        .descendant(
          of: find.byKey(const ValueKey('stop-list-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    expect(scrollable, findsOneWidget);
    await tester.scrollUntilVisible(
      target,
      100,
      scrollable: scrollable,
      maxScrolls: 12,
    );
  }
  expect(target, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await pumpFormalFrames(tester);
  expect(
    target.hitTestable(),
    findsOneWidget,
    reason: '$key actual bounds ${tester.getRect(target)}',
  );
}

Future<void> tapFormalControl(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await revealFormalControl(tester, key);
  final tapped = await tester.runAsync(() async {
    await tester.tap(target);
    return true;
  });
  expect(tapped, isTrue);
  await pumpFormalFrames(tester);
}

/// Observe the actual UI -> asynchronous VM -> file I/O transition in the real
/// zone. Missing actions or hung work fail at the explicit five-second bound.
Future<void> tapFormalTransition(
  WidgetTester tester,
  DeliveryViewModel model,
  String key, {
  required bool Function() busy,
}) async {
  final target = find.byKey(ValueKey(key));
  await revealFormalControl(tester, key);
  final completed = await awaitGuardedFormalIO(tester, (uiFinished) async {
    final done = Completer<void>();
    var started = false;
    void observe() {
      started |= busy();
      if (started && !busy() && !done.isCompleted) done.complete();
    }

    model.addListener(observe);
    try {
      await tester.tap(target);
      uiFinished();
      await done.future;
      return true;
    } finally {
      model.removeListener(observe);
    }
  });
  expect(completed, isTrue);
  await pumpFormalFrames(tester);
}

Future<void> waitForFormalModel(
  WidgetTester tester,
  DeliveryViewModel model,
  bool Function() settled,
) async {
  final completed = await awaitFormalIO(tester, () async {
    if (settled()) return true;
    final done = Completer<void>();
    void observe() {
      if (settled() && !done.isCompleted) done.complete();
    }

    model.addListener(observe);
    try {
      await done.future;
      return true;
    } finally {
      model.removeListener(observe);
    }
  });
  expect(completed, isTrue);
  await pumpFormalFrames(tester);
}

Future<PendingUpdate> waitForFormalRequest(
  WidgetTester tester,
  FormalHeldTransport transport,
  int index,
) async {
  final request = await awaitFormalIO(tester, () => transport.request(index));
  expect(
    request,
    isNotNull,
    reason: 'Request $index did not cross the actual send fence',
  );
  return request!;
}

Future<void> unmountFormalApp(
  WidgetTester tester,
  DeliveryViewModel model,
) async {
  await tester.pumpWidget(const SizedBox());
  await awaitFormalIO(tester, model.close);
}

FocusNode formalFieldFocus(WidgetTester tester, String key) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(EditableText),
      ),
    )
    .focusNode;
