import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/app/runtime_configuration.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/data/services/demo_transport.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../integration_test/support/delivery_fault_fixtures.dart';
import '../support/delivery_risk_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'demo confirmation cannot alter a separate local-client file or its retry identity',
    () async {
      final sandbox = await DeliveryRiskSandbox.create();
      addTearDown(sandbox.dispose);
      final localName = RuntimeConfiguration.parse('local-client').databaseName;
      final demoName = RuntimeConfiguration.parse('demo').databaseName;
      final local = sandbox.repository(localName);
      final demo = sandbox.repository(demoName);
      await local.initialize();
      await demo.initialize();
      final localStop = (await local.loadStops()).first;
      final demoStop = (await demo.loadStops()).first;
      await local.saveOnline(false);
      await local.submit(
        localStop.id,
        DeliveryStatus.failed,
        reason: 'Business closed',
        note: 'Local result must remain waiting',
      );
      await demo.submit(demoStop.id, DeliveryStatus.completed);
      final localUpdate = (await local.pendingUpdates()).single;
      final demoUpdate = (await demo.pendingUpdates()).single;
      final localBefore = await sandbox.persistedSnapshot(localName);
      expect(localUpdate.datasetId, isNot(demoUpdate.datasetId));
      expect(localUpdate.operationId, isNot(demoUpdate.operationId));
      final coordinator = SyncCoordinator(
        repository: demo,
        transport: DemoTransport(latency: Duration.zero),
      );
      await coordinator.sync().timeout(const Duration(seconds: 5));
      expect(coordinator.progress!.confirmedCount, 1);
      expect(await demo.pendingUpdates(), isEmpty);
      expect(await sandbox.persistedSnapshot(localName), localBefore);
      expect(await local.acknowledge(fixtureMatchingAck(demoUpdate)), isFalse);
      expect(await sandbox.persistedSnapshot(localName), localBefore);

      final reopened = await sandbox.reopenWithoutSource(localName);
      expect((await reopened.loadSettings()).online, isFalse);
      expect(
        immutableUpdateFacts((await reopened.pendingUpdates()).single),
        immutableUpdateFacts(localUpdate),
      );
      final unavailable = SyncCoordinator(repository: reopened);
      await expectLater(unavailable.sync(), throwsA(isA<StateError>()));
      expect(unavailable.isRunning, isFalse);
      expect(await sandbox.persistedSnapshot(localName), localBefore);
    },
  );

  test(
    'held matching ack plus SQL rollback never reports confirmation and survives reopen before retry',
    () async {
      final sandbox = await DeliveryRiskSandbox.create();
      addTearDown(sandbox.dispose);
      const name = 'held-ack.sqlite';
      final repository = sandbox.repository(name);
      await repository.initialize();
      final stop = (await repository.loadStops()).first;
      await repository.submit(
        stop.id,
        DeliveryStatus.failed,
        reason: 'Recipient unavailable',
        note: 'Original note',
      );
      final original = (await repository.pendingUpdates()).single;
      final beforeAck = await sandbox.persistedSnapshot(name);
      await (await sandbox.admin(name)).execute('''
        CREATE TRIGGER reject_risk_ack BEFORE DELETE ON outbox
        BEGIN SELECT RAISE(ABORT, 'independent ack rollback'); END
      ''');
      final transport = HeldAckTransport();
      final fence = AcknowledgementFence(repository);
      final progress = <SyncProgress>[];
      final coordinator = SyncCoordinator(
        repository: fence,
        transport: transport,
      )..addListener(progress.add);
      final outcome = coordinator.sync().then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      final sent = await transport.firstSent.future.timeout(
        const Duration(seconds: 5),
      );
      expect(immutableUpdateFacts(sent), immutableUpdateFacts(original));
      transport.releaseMatching();
      await fence.entered.future.timeout(const Duration(seconds: 5));
      expect(progress.every((event) => event.confirmedCount == 0), isTrue);
      expect(await sandbox.persistedSnapshot(name), beforeAck);
      fence.permitCommit.complete();
      expect(
        await outcome.timeout(const Duration(seconds: 5)),
        isA<DatabaseException>(),
      );
      expect(coordinator.isRunning, isFalse);
      expect(
        progress.where((event) => event.stage == SyncStage.failed),
        hasLength(1),
      );
      expect(progress.every((event) => event.confirmedCount == 0), isTrue);
      expect(await sandbox.persistedSnapshot(name), beforeAck);
      await (await sandbox.admin(name)).execute('DROP TRIGGER reject_risk_ack');
      final reopened = await sandbox.reopenWithoutSource(name);
      expect(
        immutableUpdateFacts((await reopened.pendingUpdates()).single),
        immutableUpdateFacts(original),
      );
      expect((await reopened.loadStops()).first.acknowledgedAt, isNull);

      final retryProgress = <SyncProgress>[];
      final retry = SyncCoordinator(
        repository: reopened,
        transport: const FakeSyncTransport(),
      )..addListener(retryProgress.add);
      await retry.sync().timeout(const Duration(seconds: 5));
      expect(
        retryProgress
            .where((event) => event.stage == SyncStage.acknowledged)
            .map((event) => event.confirmedCount),
        [1],
      );
      expect(await reopened.pendingUpdates(), isEmpty);
      final confirmed = (await reopened.loadStops()).first;
      expect(confirmed.operationId, original.operationId);
      expect(confirmed.recordedAt, original.recordedAt);
      expect(confirmed.reason, original.reason);
      expect(confirmed.note, original.note);
      expect(confirmed.acknowledgedAt!.isUtc, isTrue);
    },
  );
}
