import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';

import 'fake_delivery_repository.dart';

class ControlledRepository extends FakeDeliveryRepository {
  final initializeStarted = Completer<void>();
  final readStarted = Completer<void>();
  final submitStarted = Completer<void>();
  Completer<void>? initializeGate;
  Completer<void>? readGate;
  Completer<void>? submitGate;
  final events = <String>[];
  int closeCalls = 0;
  int reopenCalls = 0;
  int stopReads = 0;
  int queueReads = 0;
  bool isOpen = false;

  void _use(String event) {
    if (!isOpen) {
      if (closeCalls > 0) reopenCalls += 1;
      isOpen = true;
    }
    events.add(event);
  }

  @override
  Future<void> initialize() async {
    _use('initialize');
    if (!initializeStarted.isCompleted) initializeStarted.complete();
    await initializeGate?.future;
    await super.initialize();
    events.add('initialized');
  }

  @override
  Future<List<Stop>> loadStops() async {
    _use('read_stops');
    stopReads += 1;
    if (!readStarted.isCompleted) readStarted.complete();
    await readGate?.future;
    return super.loadStops();
  }

  @override
  Future<List<PendingUpdate>> pendingUpdates() async {
    _use('read_queue');
    queueReads += 1;
    return super.pendingUpdates();
  }

  @override
  Future<void> submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
    String? note,
  }) async {
    _use('submit');
    if (!submitStarted.isCompleted) submitStarted.complete();
    await submitGate?.future;
    await super.submit(stopId, status, reason: reason, note: note);
    events.add('submitted');
  }

  @override
  Future<bool> acknowledge(Ack ack) async {
    _use('ack');
    return super.acknowledge(ack);
  }

  @override
  Future<void> close() async {
    events.add('close');
    closeCalls += 1;
    isOpen = false;
  }
}

DeliveryViewModel createModel(
  ControlledRepository repository, {
  SyncTransport? transport,
}) => DeliveryViewModel(
  repository: repository,
  syncCoordinator: SyncCoordinator(
    repository: repository,
    transport: transport,
  ),
);

void main() {
  test('reentrant disposal on busy notification starts no transport', () async {
    final repository = ControlledRepository();
    var sends = 0;
    final model = createModel(
      repository,
      transport: FakeSyncTransport(
        onSend: (update) async {
          sends += 1;
          return Ack(
            operationId: update.operationId,
            datasetId: update.datasetId,
            stopId: update.stopId,
          );
        },
      ),
    );
    await model.load();
    await model.submit('stop-0', DeliveryStatus.completed);
    Future<void>? closing;
    model.addListener(() {
      if (model.isSyncing) closing = model.close();
    });
    await model.sync();
    await closing;

    expect(sends, 0, reason: 'close must not be followed by a new send');
    expect(repository.queue, hasLength(1));
    expect(repository.isOpen, isFalse);
    expect(repository.closeCalls, 1);
  });

  test(
    'close settles initialization without starting a later refresh',
    () async {
      final repository = ControlledRepository()
        ..initializeGate = Completer<void>();
      final model = createModel(repository);
      final loading = model.load();
      await repository.initializeStarted.future;
      final closing = model.close();
      final joinedClose = model.close();
      repository.initializeGate!.complete();
      await loading;
      await closing;
      await joinedClose;

      expect(
        repository.reopenCalls,
        0,
        reason: 'close must not be followed by a database reopen',
      );
      expect(repository.stopReads, 0);
      expect(repository.queueReads, 0);
      expect(repository.events, ['initialize', 'initialized', 'close']);
      expect(repository.closeCalls, 1);
      expect(repository.isOpen, isFalse);
      expect(identical(closing, joinedClose), isTrue);
    },
  );

  test('close during a stop read skips the subsequent queue read', () async {
    final repository = ControlledRepository()..readGate = Completer<void>();
    final model = createModel(repository);
    final loading = model.load();
    await repository.readStarted.future;
    final closing = model.close();
    repository.readGate!.complete();
    await loading;
    await closing;

    expect(
      repository.reopenCalls,
      0,
      reason: 'the continuation must not reopen storage',
    );
    expect(repository.queueReads, 0);
    expect(repository.events.last, 'close');
    expect(repository.closeCalls, 1);
    expect(repository.isOpen, isFalse);
  });

  test('close settles the pending submit then releases storage once', () async {
    final repository = ControlledRepository();
    final model = createModel(repository);
    await model.load();
    final initialReads = repository.stopReads;
    final initialQueueReads = repository.queueReads;
    repository.submitGate = Completer<void>();
    final saving = model.submit('stop-0', DeliveryStatus.completed);
    await repository.submitStarted.future;
    final closing = model.close();
    await model.load();
    expect(await model.submit('stop-1', DeliveryStatus.completed), isFalse);
    await model.sync();
    repository.submitGate!.complete();
    expect(await saving, isTrue);
    await closing;

    expect(
      repository.reopenCalls,
      0,
      reason: 'a saved operation must not trigger post-close refresh',
    );
    expect(repository.stopReads, initialReads);
    expect(repository.queueReads, initialQueueReads);
    expect(
      repository.events.indexOf('submitted'),
      lessThan(repository.events.indexOf('close')),
    );
    expect(repository.queue, hasLength(1));
    expect(repository.closeCalls, 1);
    expect(repository.isOpen, isFalse);
  });

  test(
    'close waits for in-flight confirmation and leaves the next queued item',
    () async {
      final repository = ControlledRepository();
      final started = Completer<PendingUpdate>();
      final response = Completer<Ack>();
      var sends = 0;
      final model = createModel(
        repository,
        transport: FakeSyncTransport(
          onSend: (update) {
            sends += 1;
            started.complete(update);
            return response.future;
          },
        ),
      );
      await model.load();
      await model.submit('stop-0', DeliveryStatus.completed);
      await model.submit(
        'stop-1',
        DeliveryStatus.failed,
        reason: 'No recipient',
      );
      final syncing = model.sync();
      final update = await started.future;
      final reads = repository.stopReads;
      final closing = model.close();
      response.complete(
        Ack(
          operationId: update.operationId,
          datasetId: update.datasetId,
          stopId: update.stopId,
        ),
      );
      await syncing;
      await closing;

      expect(
        repository.reopenCalls,
        0,
        reason: 'ack must settle before the database closes',
      );
      expect(
        repository.events.indexOf('ack'),
        lessThan(repository.events.indexOf('close')),
      );
      expect(repository.stopReads, reads);
      expect(repository.queue, hasLength(1));
      expect(sends, 1);
      expect(model.syncCoordinator.isRunning, isFalse);
      expect(repository.closeCalls, 1);
      expect(repository.isOpen, isFalse);
    },
  );
}
