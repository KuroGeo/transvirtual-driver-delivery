import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/delivery/delivery_repository.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/repository_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<RepositoryFixture> queued({int count = 2}) async {
    final value = await RepositoryFixture.create();
    addTearDown(value.dispose);
    final stops = await value.repository.loadStops();
    await value.repository.submit(stops.first.id, DeliveryStatus.completed);
    if (count > 1) {
      await value.repository.submit(
        stops[1].id,
        DeliveryStatus.failed,
        reason: 'No access',
      );
    }
    return value;
  }

  test('a never completing send times out and ignores its late ack', () async {
    final value = await queued();
    final expected = await value.repository.pendingUpdates();
    final lateAck = Completer<Ack>();
    final retryAck = Completer<Ack>();
    final retryStarted = Completer<PendingUpdate>();
    final sent = <String>[];
    final progress = <SyncProgress>[];
    final coordinator = SyncCoordinator(
      repository: value.repository,
      requestTimeout: const Duration(milliseconds: 150),
      transport: FakeSyncTransport(
        onSend: (update) {
          sent.add(update.operationId);
          if (sent.length == 1) return lateAck.future;
          if (sent.length == 2) {
            retryStarted.complete(update);
            return retryAck.future;
          }
          return Future.value(matchingAck(update));
        },
      ),
    )..addListener(progress.add);

    final first = coordinator.sync();
    expect(identical(first, coordinator.sync()), isTrue);
    await expectLater(first, throwsA(isA<TimeoutException>()));
    expect(coordinator.isRunning, isFalse);
    expect(sent, [expected.first.operationId]);
    expect(
      (await value.repository.pendingUpdates()).map(updateIdentity),
      expected.map(updateIdentity),
    );
    expect(
      progress.where((event) => event.stage == SyncStage.acknowledged),
      isEmpty,
    );

    final retry = coordinator.sync();
    final retryUpdate = await retryStarted.future;
    expect(retryUpdate.operationId, expected.first.operationId);
    lateAck.complete(matchingAck(expected.first));
    await lateAck.future;
    expect(
      (await value.repository.pendingUpdates()).map(updateIdentity),
      expected.map(updateIdentity),
    );
    expect(
      progress.where((event) => event.stage == SyncStage.acknowledged),
      isEmpty,
    );
    retryAck.complete(matchingAck(retryUpdate));
    await retry;
    expect(sent, [
      expected.first.operationId,
      expected.first.operationId,
      expected.last.operationId,
    ]);
    expect(await value.repository.pendingUpdates(), isEmpty);
    expect(
      progress
          .where((event) => event.stage == SyncStage.acknowledged)
          .map((event) => (event.runId, event.confirmedCount)),
      [(2, 1), (2, 2)],
    );
    expect(coordinator.progress!.stage, SyncStage.finished);
    expect(coordinator.progress!.error, isNull);
  });

  test('late transport errors do not reopen or retry a failed drain', () async {
    final value = await queued();
    final response = Completer<Ack>();
    var sent = 0;
    final coordinator = SyncCoordinator(
      repository: value.repository,
      requestTimeout: const Duration(milliseconds: 20),
      transport: FakeSyncTransport(
        onSend: (_) {
          sent++;
          return response.future;
        },
      ),
    );
    final running = coordinator.sync();
    for (var i = 0; i < 8; i++) {
      expect(identical(running, coordinator.sync()), isTrue);
    }
    await expectLater(running, throwsA(isA<TimeoutException>()));
    response.completeError(StateError('Late disconnected request'));
    expect(await value.repository.pendingUpdates(), hasLength(2));
    expect(sent, 1);
    expect(coordinator.isRunning, isFalse);
    expect(coordinator.progress!.confirmedCount, 0);
    expect(coordinator.progress!.error, isA<TimeoutException>());
  });

  test(
    'a request during an empty snapshot causes another queue read',
    () async {
      final value = await queued(count: 1);
      final emptyObserved = Completer<void>();
      final emptyResult = Completer<List<PendingUpdate>>();
      var held = false;
      final repository = _ControlledRepository(
        value.repository,
        onRead: () async {
          final pending = await value.repository.pendingUpdates();
          if (!held && pending.isEmpty) {
            held = true;
            emptyObserved.complete();
            return emptyResult.future;
          }
          return pending;
        },
      );
      final sent = <String>[];
      final coordinator = SyncCoordinator(
        repository: repository,
        transport: FakeSyncTransport(
          onSend: (update) async {
            sent.add(update.operationId);
            return matchingAck(update);
          },
        ),
      );
      final running = coordinator.sync();
      await emptyObserved.future;
      final second = (await value.repository.loadStops())[1];
      await value.repository.submit(second.id, DeliveryStatus.completed);
      final queuedSecond = (await value.repository.pendingUpdates()).single;
      expect(identical(running, coordinator.sync()), isTrue);
      emptyResult.complete([]);
      await running;
      expect(sent.last, queuedSecond.operationId);
      expect(sent, hasLength(2));
      expect(await value.repository.pendingUpdates(), isEmpty);
    },
  );

  test('reconnect during pause resumes the same in-flight drain', () async {
    final value = await queued();
    final started = Completer<PendingUpdate>();
    final response = Completer<Ack>();
    final sent = <String>[];
    final coordinator = SyncCoordinator(
      repository: value.repository,
      transport: FakeSyncTransport(
        onSend: (update) {
          sent.add(update.operationId);
          if (sent.length == 1) {
            started.complete(update);
            return response.future;
          }
          return Future.value(matchingAck(update));
        },
      ),
    );
    final running = coordinator.sync();
    final first = await started.future;
    coordinator.pause();
    expect(identical(running, coordinator.sync()), isTrue);
    response.complete(matchingAck(first));
    await running;
    expect(sent, hasLength(2));
    expect(await value.repository.pendingUpdates(), isEmpty);
    expect(coordinator.progress!.runId, 1);
  });

  test('reconnect wakes a paused empty-snapshot tail', () async {
    final value = await queued(count: 1);
    final emptyObserved = Completer<void>();
    final emptyResult = Completer<List<PendingUpdate>>();
    var held = false;
    final coordinator = SyncCoordinator(
      repository: _ControlledRepository(
        value.repository,
        onRead: () async {
          final pending = await value.repository.pendingUpdates();
          if (!held && pending.isEmpty) {
            held = true;
            emptyObserved.complete();
            return emptyResult.future;
          }
          return pending;
        },
      ),
      transport: const FakeSyncTransport(),
    );
    final running = coordinator.sync();
    await emptyObserved.future;
    coordinator.pause();
    final second = (await value.repository.loadStops())[1];
    await value.repository.submit(second.id, DeliveryStatus.completed);
    expect(identical(running, coordinator.sync()), isTrue);
    emptyResult.complete([]);
    await running;
    expect(await value.repository.pendingUpdates(), isEmpty);
    expect(coordinator.progress!.confirmedCount, 2);
  });

  test(
    'finished observer can start a new run without old cleanup clearing it',
    () async {
      final value = await queued(count: 1);
      final emptyObserved = Completer<void>();
      final emptyResult = Completer<List<PendingUpdate>>();
      final secondStarted = Completer<PendingUpdate>();
      final secondAck = Completer<Ack>();
      var held = false;
      var sends = 0;
      Future<void>? reentrant;
      bool? terminalSawIdle;
      final events = <SyncProgress>[];
      late final SyncCoordinator coordinator;
      coordinator =
          SyncCoordinator(
            repository: _ControlledRepository(
              value.repository,
              onRead: () async {
                final pending = await value.repository.pendingUpdates();
                if (!held && pending.isEmpty) {
                  held = true;
                  emptyObserved.complete();
                  return emptyResult.future;
                }
                return pending;
              },
            ),
            transport: FakeSyncTransport(
              onSend: (update) {
                sends++;
                if (sends == 2) {
                  secondStarted.complete(update);
                  return secondAck.future;
                }
                return Future.value(matchingAck(update));
              },
            ),
          )..addListener((event) {
            events.add(event);
            if (event.stage == SyncStage.finished && event.runId == 1) {
              terminalSawIdle = !coordinator.isRunning;
              reentrant = coordinator.sync();
            }
          });
      final firstRun = coordinator.sync();
      await emptyObserved.future;
      final second = (await value.repository.loadStops())[1];
      await value.repository.submit(second.id, DeliveryStatus.completed);
      emptyResult.complete([]);
      await firstRun;
      final update = await secondStarted.future;
      expect(coordinator.isRunning, isTrue);
      expect(terminalSawIdle, isTrue);
      expect(identical(firstRun, reentrant), isFalse);
      expect(identical(reentrant, coordinator.sync()), isTrue);
      secondAck.complete(matchingAck(update));
      await reentrant;
      expect(await value.repository.pendingUpdates(), isEmpty);
      expect(
        events
            .where((event) => event.stage == SyncStage.finished)
            .map((event) => event.runId),
        [1, 2],
      );
      expect(coordinator.isRunning, isFalse);
    },
  );

  test(
    'progress cannot count a transport response before the ack commits',
    () async {
      final value = await queued(count: 1);
      final ackEntered = Completer<void>();
      final releaseAck = Completer<void>();
      var committed = false;
      final events = <SyncProgress>[];
      final committedAtProgress = <bool>[];
      final coordinator =
          SyncCoordinator(
            repository: _ControlledRepository(
              value.repository,
              onAck: (ack) async {
                ackEntered.complete();
                await releaseAck.future;
                final result = await value.repository.acknowledge(ack);
                committed = result;
                return result;
              },
            ),
            transport: const FakeSyncTransport(),
          )..addListener((event) {
            if (event.stage == SyncStage.acknowledged) {
              committedAtProgress.add(committed);
            }
            events.add(event);
          });
      final running = coordinator.sync();
      await ackEntered.future;
      expect(await value.repository.pendingUpdates(), hasLength(1));
      expect(events.every((event) => event.confirmedCount == 0), isTrue);
      releaseAck.complete();
      await running;
      expect(
        events
            .where((event) => event.stage == SyncStage.acknowledged)
            .map((event) => event.confirmedCount),
        [1],
      );
      expect(await value.repository.pendingUpdates(), isEmpty);
      expect(committedAtProgress, [true]);
    },
  );

  test('confirmation rollback reports zero persisted progress', () async {
    final value = await queued();
    await (await value.admin).execute('''
      CREATE TRIGGER reject_progress BEFORE UPDATE OF acknowledged_at ON stops
      BEGIN SELECT RAISE(ABORT, 'controlled progress write failure'); END
    ''');
    final events = <SyncProgress>[];
    final coordinator = SyncCoordinator(
      repository: value.repository,
      transport: const FakeSyncTransport(),
    )..addListener(events.add);
    await expectLater(coordinator.sync(), throwsA(isA<DatabaseException>()));
    expect(
      events.where((event) => event.stage == SyncStage.acknowledged),
      isEmpty,
    );
    expect(events.last.confirmedCount, 0);
    expect(events.last.error, isA<DatabaseException>());
    expect(await value.repository.pendingUpdates(), hasLength(2));
  });

  test(
    'a failed second send retains the first persisted confirmation count',
    () async {
      final value = await queued();
      final pending = await value.repository.pendingUpdates();
      var sends = 0;
      final events = <SyncProgress>[];
      final coordinator = SyncCoordinator(
        repository: value.repository,
        transport: FakeSyncTransport(
          onSend: (update) async {
            sends++;
            if (sends == 2) throw StateError('Controlled second send failure');
            return matchingAck(update);
          },
        ),
      )..addListener(events.add);
      await expectLater(coordinator.sync(), throwsStateError);
      expect((await value.repository.pendingUpdates()).map(updateIdentity), [
        updateIdentity(pending.last),
      ]);
      expect(
        events
            .where((event) => event.stage == SyncStage.acknowledged)
            .map((event) => event.confirmedCount),
        [1],
      );
      expect(events.last.confirmedCount, 1);
      expect(events.last.error, isA<StateError>());
      expect(coordinator.isRunning, isFalse);
    },
  );

  test(
    'a matching response with an unpersisted ack cannot advance progress',
    () async {
      final value = await queued();
      final expected = await value.repository.pendingUpdates();
      final events = <SyncProgress>[];
      final coordinator = SyncCoordinator(
        repository: _ControlledRepository(
          value.repository,
          onAck: (_) async => false,
        ),
        transport: const FakeSyncTransport(),
      )..addListener(events.add);
      await expectLater(coordinator.sync(), throwsStateError);
      expect(
        events.where((event) => event.stage == SyncStage.acknowledged),
        isEmpty,
      );
      expect(events.last.confirmedCount, 0);
      expect(
        (await value.repository.pendingUpdates()).map(updateIdentity),
        expected.map(updateIdentity),
      );
    },
  );

  test(
    'listener failures and removal do not change persisted results',
    () async {
      final value = await queued();
      final received = <SyncProgress>[];
      final removed = <SyncProgress>[];
      final coordinator =
          SyncCoordinator(
              repository: value.repository,
              transport: const FakeSyncTransport(),
              eventSink: (_) => throw StateError('Legacy observer failure'),
            )
            ..addListener((_) => throw StateError('Typed observer failure'))
            ..addListener(received.add)
            ..addListener(removed.add);
      coordinator.removeListener(removed.add);
      await coordinator.sync();
      expect(removed, isEmpty);
      expect(
        received
            .where((event) => event.stage == SyncStage.acknowledged)
            .map((event) => event.confirmedCount),
        [1, 2],
      );
      expect(await value.repository.pendingUpdates(), isEmpty);
      expect(coordinator.isRunning, isFalse);
    },
  );

  test('a sending observer may pause before a new request is sent', () async {
    final value = await queued();
    var sends = 0;
    final received = <SyncStage>[];
    late final SyncCoordinator coordinator;
    coordinator = SyncCoordinator(
      repository: value.repository,
      transport: FakeSyncTransport(
        onSend: (update) async {
          sends++;
          return matchingAck(update);
        },
      ),
      eventSink: (event) {
        if (event['stage'] == 'sync_sending') coordinator.pause();
      },
    )..addListener((event) => received.add(event.stage));
    await coordinator.sync();
    expect(sends, 0);
    expect(received, [
      SyncStage.started,
      SyncStage.sending,
      SyncStage.paused,
      SyncStage.finished,
    ]);
    expect(await value.repository.pendingUpdates(), hasLength(2));
  });

  test(
    'scope close is bounded by the actual hanging request deadline',
    () async {
      final value = await queued();
      final expected = await value.repository.pendingUpdates();
      final sent = Completer<void>();
      final hanging = Completer<Ack>();
      final model = DeliveryViewModel(
        repository: value.repository,
        syncCoordinator: SyncCoordinator(
          repository: value.repository,
          requestTimeout: const Duration(milliseconds: 30),
          transport: FakeSyncTransport(
            onSend: (_) {
              sent.complete();
              return hanging.future;
            },
          ),
        ),
      );
      await model.load();
      final running = model.sync();
      await sent.future;
      final closing = model.close();
      expect(identical(closing, model.close()), isTrue);
      await closing.timeout(const Duration(seconds: 2));
      await running;
      expect(model.syncCoordinator.isRunning, isFalse);
      await value.reopen();
      expect(
        (await value.repository.pendingUpdates()).map(updateIdentity),
        expected.map(updateIdentity),
      );
      hanging.complete(matchingAck(expected.first));
      await hanging.future;
      expect(
        (await value.repository.pendingUpdates()).map(updateIdentity),
        expected.map(updateIdentity),
      );
    },
  );

  test('a nonpositive request deadline is rejected', () async {
    final value = await queued(count: 1);
    for (final deadline in [Duration.zero, const Duration(milliseconds: -1)]) {
      expect(
        () => SyncCoordinator(
          repository: value.repository,
          requestTimeout: deadline,
        ),
        throwsArgumentError,
      );
    }
    expect(
      SyncCoordinator(repository: value.repository).requestTimeout,
      const Duration(seconds: 5),
    );
  });
}

class _ControlledRepository implements DeliveryRepository {
  _ControlledRepository(this.delegate, {this.onRead, this.onAck});

  final DeliveryRepository delegate;
  final Future<List<PendingUpdate>> Function()? onRead;
  final Future<bool> Function(Ack)? onAck;

  @override
  Future<void> initialize() => delegate.initialize();

  @override
  Future<List<Stop>> loadStops() => delegate.loadStops();

  @override
  Future<void> submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
    String? note,
  }) => delegate.submit(stopId, status, reason: reason, note: note);

  @override
  Future<List<PendingUpdate>> pendingUpdates() =>
      onRead?.call() ?? delegate.pendingUpdates();

  @override
  Future<bool> acknowledge(Ack ack) =>
      onAck?.call(ack) ?? delegate.acknowledge(ack);

  @override
  Future<void> close() => delegate.close();
}
