import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'repository_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<RepositoryFixture> fixture() async {
    final value = await RepositoryFixture.create();
    addTearDown(value.dispose);
    return value;
  }

  test(
    'result and immutable outbox snapshot preserve trimmed note and UTC time',
    () async {
      final value = await fixture();
      final original = (await value.repository.loadStops()).first;
      final earliest = DateTime.now().toUtc().millisecondsSinceEpoch;
      await value.repository.submit(
        original.id,
        DeliveryStatus.failed,
        reason: '  Recipient unavailable  ',
        note: '  Called twice\n  ',
      );
      final latest = DateTime.now().toUtc().millisecondsSinceEpoch;
      final snapshot = (await value.repository.pendingUpdates()).single;
      final saved = (await value.repository.loadStops()).first;
      expect(saved.reason, 'Recipient unavailable');
      expect(saved.note, 'Called twice');
      expect(saved.timeWindow, original.timeWindow);
      expect(saved.recordedAt!.isUtc, isTrue);
      expect(
        saved.recordedAt!.millisecondsSinceEpoch,
        inInclusiveRange(earliest, latest),
      );
      expect(saved.acknowledgedAt, isNull);
      expect(snapshot.note, saved.note);
      expect(snapshot.recordedAt, saved.recordedAt);
      expect(snapshot.operationId, saved.operationId);
      expect(snapshot.reason, saved.reason);
      await expectLater(
        value.repository.submit(
          original.id,
          DeliveryStatus.failed,
          reason: 'Address not found',
          note: 'Replacement attempt',
        ),
        throwsStateError,
      );
      await value.reopen();
      final reopened = (await value.repository.loadStops()).first;
      expect(reopened.recordedAt, saved.recordedAt);
      expect(reopened.note, saved.note);
      expect(
        updateIdentity((await value.repository.pendingUpdates()).single),
        updateIdentity(snapshot),
      );
    },
  );

  test(
    'blank note is absent and completed result discards failure fields',
    () async {
      final value = await fixture();
      final initial = await value.repository.loadStops();
      await value.repository.submit(
        initial[0].id,
        DeliveryStatus.failed,
        reason: '  Leave package with reception  ',
        note: ' \n\t ',
      );
      await value.repository.submit(
        initial[1].id,
        DeliveryStatus.completed,
        reason: 'Stale failure reason',
        note: 'Stale failure note',
      );
      final saved = await value.repository.loadStops();
      expect(saved[0].reason, 'Leave package with reception');
      expect(saved[0].note, isNull);
      expect(saved[1].reason, isNull);
      expect(saved[1].note, isNull);
      expect(
        (await value.repository.pendingUpdates()).every((e) => e.note == null),
        isTrue,
      );
    },
  );

  test('only matching committed ack exposes UTC confirmation, once', () async {
    final value = await fixture();
    final stop = (await value.repository.loadStops()).first;
    await value.repository.submit(stop.id, DeliveryStatus.completed);
    final snapshot = (await value.repository.pendingUpdates()).single;
    expect(
      await value.repository.acknowledge(
        Ack(
          operationId: snapshot.operationId,
          datasetId: 'another-dataset',
          stopId: snapshot.stopId,
        ),
      ),
      isFalse,
    );
    expect((await value.repository.loadStops()).first.acknowledgedAt, isNull);
    await (await value.admin).execute('''
      CREATE TRIGGER reject_ack BEFORE DELETE ON outbox
      BEGIN SELECT RAISE(ABORT, 'controlled queue removal failure'); END
    ''');
    await expectLater(
      value.repository.acknowledge(matchingAck(snapshot)),
      throwsA(isA<DatabaseException>()),
    );
    expect((await value.repository.loadStops()).first.acknowledgedAt, isNull);
    expect(
      updateIdentity((await value.repository.pendingUpdates()).single),
      updateIdentity(snapshot),
    );
    await (await value.admin).execute('DROP TRIGGER reject_ack');
    expect(await value.repository.acknowledge(matchingAck(snapshot)), isTrue);
    final acknowledged = (await value.repository.loadStops()).first;
    expect(acknowledged.acknowledgedAt!.isUtc, isTrue);
    expect(
      acknowledged.acknowledgedAt!.isBefore(acknowledged.recordedAt!),
      isFalse,
    );
    expect(await value.repository.acknowledge(matchingAck(snapshot)), isFalse);
    await value.reopen();
    final reopened = (await value.repository.loadStops()).first;
    expect(reopened.acknowledgedAt, acknowledged.acknowledgedAt);
    expect(reopened.recordedAt, snapshot.recordedAt);
  });
}
