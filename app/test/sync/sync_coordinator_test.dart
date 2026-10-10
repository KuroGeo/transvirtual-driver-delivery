import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
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

  test(
    'default unavailable preserves the exact queue and releases the loop',
    () async {
      final value = await queued();
      final pending = await value.repository.pendingUpdates();
      final coordinator = SyncCoordinator(repository: value.repository);
      await expectLater(coordinator.sync(), throwsStateError);
      expect(coordinator.isRunning, isFalse);
      expect(
        (await value.repository.pendingUpdates()).map(updateIdentity),
        pending.map(updateIdentity),
      );
      await expectLater(coordinator.sync(), throwsStateError);
      expect(coordinator.isRunning, isFalse);
    },
  );

  test('repeated triggers join one strictly serial loop', () async {
    final value = await queued();
    final expected = await value.repository.pendingUpdates();
    final firstStarted = Completer<PendingUpdate>();
    final secondStarted = Completer<PendingUpdate>();
    final firstAck = Completer<Ack>();
    final secondAck = Completer<Ack>();
    final sent = <String>[];
    var inFlight = 0;
    var peak = 0;
    final coordinator = SyncCoordinator(
      repository: value.repository,
      transport: FakeSyncTransport(
        onSend: (update) async {
          sent.add(update.operationId);
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          if (sent.length == 1) {
            firstStarted.complete(update);
            final ack = await firstAck.future;
            inFlight--;
            return ack;
          }
          secondStarted.complete(update);
          final ack = await secondAck.future;
          inFlight--;
          return ack;
        },
      ),
    );
    final running = coordinator.sync();
    final joined = coordinator.sync();
    expect(identical(running, joined), isTrue);
    expect(coordinator.isRunning, isTrue);
    final first = await firstStarted.future;
    expect(sent, [expected.first.operationId]);
    expect(await value.repository.pendingUpdates(), hasLength(2));
    firstAck.complete(matchingAck(first));
    final second = await secondStarted.future;
    expect(await value.repository.pendingUpdates(), hasLength(1));
    secondAck.complete(matchingAck(second));
    await Future.wait([running, joined]);
    expect(sent, expected.map((update) => update.operationId));
    expect(peak, 1);
    expect(await value.repository.pendingUpdates(), isEmpty);
    expect(coordinator.isRunning, isFalse);
  });

  test(
    'the loop rereads the queue after each persisted acknowledgement',
    () async {
      final value = await queued(count: 1);
      final firstStarted = Completer<PendingUpdate>();
      final firstAck = Completer<Ack>();
      final sent = <String>[];
      final coordinator = SyncCoordinator(
        repository: value.repository,
        transport: FakeSyncTransport(
          onSend: (update) async {
            sent.add(update.operationId);
            if (sent.length == 1) {
              firstStarted.complete(update);
              return firstAck.future;
            }
            return matchingAck(update);
          },
        ),
      );
      final running = coordinator.sync();
      final first = await firstStarted.future;
      final secondStop = (await value.repository.loadStops())[1];
      await value.repository.submit(
        secondStop.id,
        DeliveryStatus.failed,
        reason: 'No access',
      );
      final expected = await value.repository.pendingUpdates();
      firstAck.complete(matchingAck(first));
      await running;
      expect(sent, expected.map((update) => update.operationId));
      expect(await value.repository.pendingUpdates(), isEmpty);
    },
  );

  test(
    'pause finishes an in-flight ack and leaves the next item for resume',
    () async {
      final value = await queued();
      final expected = await value.repository.pendingUpdates();
      final started = Completer<PendingUpdate>();
      final response = Completer<Ack>();
      final sent = <String>[];
      final coordinator = SyncCoordinator(
        repository: value.repository,
        transport: FakeSyncTransport(
          onSend: (update) async {
            sent.add(update.operationId);
            if (sent.length == 1) {
              started.complete(update);
              return response.future;
            }
            return matchingAck(update);
          },
        ),
      );
      final running = coordinator.sync();
      final first = await started.future;
      coordinator.pause();
      expect(coordinator.isRunning, isTrue);
      response.complete(matchingAck(first));
      await running;
      expect(sent, [expected.first.operationId]);
      expect((await value.repository.pendingUpdates()).map(updateIdentity), [
        updateIdentity(expected.last),
      ]);
      expect(coordinator.isRunning, isFalse);
      await coordinator.sync();
      expect(sent, expected.map((update) => update.operationId));
      expect(await value.repository.pendingUpdates(), isEmpty);
    },
  );

  test(
    'pause before the loop starts sends nothing and a new trigger resumes',
    () async {
      final value = await queued();
      var sends = 0;
      final coordinator = SyncCoordinator(
        repository: value.repository,
        transport: FakeSyncTransport(
          onSend: (update) async {
            sends++;
            return matchingAck(update);
          },
        ),
      );
      final running = coordinator.sync();
      coordinator.pause();
      await running;
      expect(sends, 0);
      expect(await value.repository.pendingUpdates(), hasLength(2));
      expect(coordinator.isRunning, isFalse);
      await coordinator.sync();
      expect(sends, 2);
    },
  );

  test(
    'wrong ack cannot confirm another item and retries the original ID',
    () async {
      final value = await queued();
      final expected = await value.repository.pendingUpdates();
      var returnWrongAck = true;
      final sent = <String>[];
      final coordinator = SyncCoordinator(
        repository: value.repository,
        transport: FakeSyncTransport(
          onSend: (update) async {
            sent.add(update.operationId);
            return returnWrongAck
                ? matchingAck(expected.last)
                : matchingAck(update);
          },
        ),
      );
      await expectLater(coordinator.sync(), throwsStateError);
      expect(coordinator.isRunning, isFalse);
      expect(
        (await value.repository.pendingUpdates()).map(updateIdentity),
        expected.map(updateIdentity),
      );
      returnWrongAck = false;
      await coordinator.sync();
      expect(sent, [
        expected.first.operationId,
        expected.first.operationId,
        expected.last.operationId,
      ]);
      expect(await value.repository.pendingUpdates(), isEmpty);
    },
  );

  test(
    'transport exception stops at the first item and finally permits retry',
    () async {
      final value = await queued();
      final expected = await value.repository.pendingUpdates();
      var fail = true;
      final sent = <String>[];
      final coordinator = SyncCoordinator(
        repository: value.repository,
        transport: FakeSyncTransport(
          onSend: (update) async {
            sent.add(update.operationId);
            if (fail) throw TimeoutException('Controlled transport timeout');
            return matchingAck(update);
          },
        ),
      );
      await expectLater(coordinator.sync(), throwsA(isA<TimeoutException>()));
      expect(coordinator.isRunning, isFalse);
      expect(sent, [expected.first.operationId]);
      expect(
        (await value.repository.pendingUpdates()).map(updateIdentity),
        expected.map(updateIdentity),
      );
      fail = false;
      await coordinator.sync();
      expect(sent, [
        expected.first.operationId,
        expected.first.operationId,
        expected.last.operationId,
      ]);
      expect(coordinator.isRunning, isFalse);
    },
  );

  test(
    'ack SQLite write failure preserves queue and releases for recovery',
    () async {
      final value = await queued();
      final expected = await value.repository.pendingUpdates();
      await (await value.admin).execute('''
      CREATE TRIGGER reject_confirmation BEFORE UPDATE OF acknowledged_at ON stops
      BEGIN SELECT RAISE(ABORT, 'controlled sync ack failure'); END
    ''');
      final sent = <String>[];
      final coordinator = SyncCoordinator(
        repository: value.repository,
        transport: FakeSyncTransport(
          onSend: (update) async {
            sent.add(update.operationId);
            return matchingAck(update);
          },
        ),
      );
      await expectLater(coordinator.sync(), throwsA(isA<DatabaseException>()));
      expect(coordinator.isRunning, isFalse);
      expect(sent, [expected.first.operationId]);
      expect(
        (await value.repository.pendingUpdates()).map(updateIdentity),
        expected.map(updateIdentity),
      );
      await (await value.admin).execute('DROP TRIGGER reject_confirmation');
      await coordinator.sync();
      expect(sent, [
        expected.first.operationId,
        expected.first.operationId,
        expected.last.operationId,
      ]);
      expect(await value.repository.pendingUpdates(), isEmpty);
    },
  );

  test('event-driven reentrant trigger still joins the current loop', () async {
    final value = await queued();
    final events = <Map<String, Object?>>[];
    Future<void>? joined;
    late final SyncCoordinator coordinator;
    coordinator = SyncCoordinator(
      repository: value.repository,
      transport: const FakeSyncTransport(),
      eventSink: (event) {
        events.add(event);
        if (event['stage'] == 'sync_started') joined = coordinator.sync();
      },
    );
    final running = coordinator.sync();
    await running;
    expect(identical(running, joined), isTrue);
    expect(
      events.where((event) => event['stage'] == 'sync_started'),
      hasLength(1),
    );
    expect(
      events.where((event) => event['stage'] == 'sync_sending'),
      hasLength(2),
    );
    expect(
      events
          .where((event) => event['stage'] == 'sync_acknowledged')
          .map((event) => event['count']),
      [1, 2],
    );
    expect(
      events.every(
        (event) => event.keys.every({'stage', 'operationId', 'count'}.contains),
      ),
      isTrue,
    );
    expect(coordinator.isRunning, isFalse);
  });

  test(
    'observer errors cannot interrupt confirmation or loop cleanup',
    () async {
      final value = await queued();
      final coordinator = SyncCoordinator(
        repository: value.repository,
        transport: const FakeSyncTransport(),
        eventSink: (_) => throw StateError('Observer failed'),
      );
      await coordinator.sync();
      expect(await value.repository.pendingUpdates(), isEmpty);
      expect(coordinator.isRunning, isFalse);
      await coordinator.sync();
      expect(coordinator.isRunning, isFalse);
    },
  );
}
