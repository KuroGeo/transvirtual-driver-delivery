import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/delivery/sqlite_delivery_repository.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'repository_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<RepositoryFixture> fixture({String csv = fixtureCsv}) async {
    final value = await RepositoryFixture.create(csv: csv);
    addTearDown(value.dispose);
    return value;
  }

  test(
    'imports the real source, preserving missing historical reasons',
    () async {
      final value = await fixture(
        csv: await File('assets/deliveries.csv').readAsString(),
      );
      await value.repository.initialize();
      final stops = await value.repository.loadStops();
      expect(stops, hasLength(30));
      expect(
        stops.where((stop) => stop.status == DeliveryStatus.pending),
        hasLength(24),
      );
      expect(
        stops.where((stop) => stop.status == DeliveryStatus.completed),
        hasLength(3),
      );
      final failed = stops.where(
        (stop) => stop.status == DeliveryStatus.failed,
      );
      expect(failed, hasLength(3));
      expect(failed.every((stop) => stop.reason == null), isTrue);
      expect(stops.map((stop) => stop.id).toSet(), hasLength(30));
      expect(stops.every((stop) => stop.id != stop.reference), isTrue);
      expect(await value.repository.pendingUpdates(), isEmpty);
      expect(() => stops.clear(), throwsUnsupportedError);
    },
  );

  const header =
      'reference,customer_name,address,latitude,longitude,status,time_window\n';
  const valid = 'A,Customer A,Test St,-33.9,151.1,pending,08:00-10:00\n';
  final invalidRows = {
    'duplicate reference':
        'A,Customer B,Other St,-33.8,151.2,pending,10:00-12:00\n',
    'missing reference':
        ',Customer B,Test St,-33.8,151.2,pending,10:00-12:00\n',
    'missing customer': 'B,,Test St,-33.8,151.2,pending,10:00-12:00\n',
    'missing address': 'B,Customer B,,-33.8,151.2,pending,10:00-12:00\n',
    'invalid latitude': 'B,Customer B,Test St,NaN,151.2,pending,10:00-12:00\n',
    'infinite longitude':
        'B,Customer B,Test St,-33.8,Infinity,pending,10:00-12:00\n',
    'latitude range': 'B,Customer B,Test St,91,151.2,pending,10:00-12:00\n',
    'longitude range': 'B,Customer B,Test St,-33.8,-181,pending,10:00-12:00\n',
    'unknown status':
        'B,Customer B,Test St,-33.8,151.2,delivered,10:00-12:00\n',
    'field count': 'B,Customer B,Test St,-33.8,151.2,pending\n',
    'unclosed quote': 'B,Customer B,Test St,-33.8,151.2,pending,"10:00-12:00\n',
    'trailing quote data':
        'B,Customer B,Test St,-33.8,151.2,pending,"10:00"extra\n',
  };
  for (final entry in invalidRows.entries) {
    test('rejects the whole import on ${entry.key}', () async {
      final value = await fixture(csv: '$header$valid${entry.value}');
      await expectLater(value.repository.initialize(), throwsFormatException);
      expect(await value.rowCount('datasets'), 0);
      expect(await value.rowCount('stops'), 0);
      expect(await value.rowCount('outbox'), 0);
      value.csv = fixtureCsv;
      await value.repository.initialize();
      expect(await value.repository.loadStops(), hasLength(4));
    });
  }

  for (final entry in {
    'empty source': '',
    'header only': header,
    'missing coordinate header': header.replaceFirst('latitude', 'lat') + valid,
    'duplicate status header':
        header.replaceFirst('time_window', 'status') + valid,
  }.entries) {
    test('rejects ${entry.key}', () async {
      final value = await fixture(csv: entry.value);
      await expectLater(value.repository.initialize(), throwsFormatException);
      expect(await value.rowCount('datasets'), 0);
      expect(await value.rowCount('stops'), 0);
    });
  }

  test('import SQLite write failure rolls back the entire batch', () async {
    final value = await fixture(csv: header);
    await expectLater(value.repository.initialize(), throwsFormatException);
    await (await value.admin).execute('''
      CREATE TRIGGER reject_second_stop BEFORE INSERT ON stops
      WHEN NEW.reference = 'B'
      BEGIN SELECT RAISE(ABORT, 'controlled import failure'); END
    ''');
    value.csv = fixtureCsv;
    await expectLater(
      value.repository.initialize(),
      throwsA(isA<DatabaseException>()),
    );
    expect(await value.rowCount('datasets'), 0);
    expect(await value.rowCount('stops'), 0);
    await (await value.admin).execute('DROP TRIGGER reject_second_stop');
    await value.repository.initialize();
    expect(await value.repository.loadStops(), hasLength(4));
  });

  test('concurrent initialization reads and imports the source once', () async {
    final value = await fixture();
    await Future.wait(List.generate(4, (_) => value.repository.initialize()));
    expect(await value.rowCount('datasets'), 1);
    expect(await value.rowCount('stops'), 4);
    expect(
      value.events.where((event) => event['stage'] == 'import_committed'),
      hasLength(1),
    );
  });

  test(
    'file reopen retains all stable identities, snapshots and sequence',
    () async {
      final value = await fixture();
      final initial = await value.repository.loadStops();
      await value.repository.submit(initial[0].id, DeliveryStatus.completed);
      await value.repository.submit(
        initial[1].id,
        DeliveryStatus.failed,
        reason: '  No access  ',
      );
      final pending = await value.repository.pendingUpdates();
      expect(pending.map((update) => update.operationId).toSet(), hasLength(2));
      expect(pending[0].seq, lessThan(pending[1].seq));
      expect(pending[1].reason, 'No access');
      await value.reopen();
      final reopened = await value.repository.loadStops();
      expect(reopened.map((stop) => stop.id), initial.map((stop) => stop.id));
      expect(reopened[0].status, DeliveryStatus.completed);
      expect(reopened[1].status, DeliveryStatus.failed);
      expect(reopened[1].reason, 'No access');
      expect(reopened[0].operationId, pending[0].operationId);
      expect(reopened[1].operationId, pending[1].operationId);
      expect(
        (await value.repository.pendingUpdates()).map(updateIdentity),
        pending.map(updateIdentity),
      );
      expect(await value.rowCount('datasets'), 1);
      expect(() => pending.clear(), throwsUnsupportedError);
    },
  );

  test(
    'duplicate and terminal submissions reject without another result',
    () async {
      final value = await fixture();
      final stops = await value.repository.loadStops();
      await value.repository.submit(stops.first.id, DeliveryStatus.completed);
      final original = (await value.repository.pendingUpdates()).single;
      await expectLater(
        value.repository.submit(
          stops.first.id,
          DeliveryStatus.failed,
          reason: 'Changed',
        ),
        throwsStateError,
      );
      for (final stop in stops.skip(2)) {
        await expectLater(
          value.repository.submit(stop.id, DeliveryStatus.completed),
          throwsStateError,
        );
      }
      await expectLater(
        value.repository.submit('missing', DeliveryStatus.completed),
        throwsStateError,
      );
      expect((await value.repository.pendingUpdates()).map(updateIdentity), [
        updateIdentity(original),
      ]);
    },
  );

  test(
    'concurrent terminal attempts commit only one result and outbox',
    () async {
      final value = await fixture();
      final stop = (await value.repository.loadStops()).first;
      final attempts = await Future.wait([
        value.repository
            .submit(stop.id, DeliveryStatus.completed)
            .then<Object?>((_) => null, onError: (Object error) => error),
        value.repository
            .submit(stop.id, DeliveryStatus.failed, reason: 'No access')
            .then<Object?>((_) => null, onError: (Object error) => error),
      ]);
      expect(attempts.where((result) => result == null), hasLength(1));
      expect(attempts.whereType<StateError>(), hasLength(1));
      expect(await value.repository.pendingUpdates(), hasLength(1));
    },
  );

  test(
    'new failure needs a nonempty reason and pending is not a result',
    () async {
      final value = await fixture();
      final stop = (await value.repository.loadStops()).first;
      for (final reason in [null, '', ' \n\t ']) {
        await expectLater(
          value.repository.submit(
            stop.id,
            DeliveryStatus.failed,
            reason: reason,
          ),
          throwsArgumentError,
        );
      }
      await expectLater(
        value.repository.submit(stop.id, DeliveryStatus.pending),
        throwsArgumentError,
      );
      expect(
        (await value.repository.loadStops()).first.status,
        DeliveryStatus.pending,
      );
      expect(await value.repository.pendingUpdates(), isEmpty);
    },
  );

  test(
    'outbox insert failure rolls back the preceding terminal update',
    () async {
      final value = await fixture();
      final stop = (await value.repository.loadStops()).first;
      await (await value.admin).execute('''
      CREATE TRIGGER reject_outbox BEFORE INSERT ON outbox
      BEGIN SELECT RAISE(ABORT, 'controlled outbox failure'); END
    ''');
      await expectLater(
        value.repository.submit(
          stop.id,
          DeliveryStatus.failed,
          reason: 'No access',
        ),
        throwsA(isA<DatabaseException>()),
      );
      final after = (await value.repository.loadStops()).first;
      expect(after.status, DeliveryStatus.pending);
      expect(after.operationId, isNull);
      expect(after.reason, isNull);
      expect(await value.repository.pendingUpdates(), isEmpty);
      await (await value.admin).execute('DROP TRIGGER reject_outbox');
      await value.repository.submit(
        stop.id,
        DeliveryStatus.failed,
        reason: 'No access',
      );
      expect(await value.repository.pendingUpdates(), hasLength(1));
    },
  );

  test(
    'ack rejects any wrong identity and repeated ack changes nothing',
    () async {
      final value = await fixture();
      final stops = await value.repository.loadStops();
      await value.repository.submit(stops[0].id, DeliveryStatus.completed);
      await value.repository.submit(
        stops[1].id,
        DeliveryStatus.failed,
        reason: 'No access',
      );
      final pending = await value.repository.pendingUpdates();
      final first = pending.first;
      for (final ack in [
        Ack(
          operationId: 'wrong',
          datasetId: first.datasetId,
          stopId: first.stopId,
        ),
        Ack(
          operationId: first.operationId,
          datasetId: 'wrong',
          stopId: first.stopId,
        ),
        Ack(
          operationId: first.operationId,
          datasetId: first.datasetId,
          stopId: pending.last.stopId,
        ),
      ]) {
        expect(await value.repository.acknowledge(ack), isFalse);
        expect(
          (await value.repository.pendingUpdates()).map(updateIdentity),
          pending.map(updateIdentity),
        );
      }
      expect(await value.repository.acknowledge(matchingAck(first)), isTrue);
      expect(await value.repository.acknowledge(matchingAck(first)), isFalse);
      expect((await value.repository.pendingUpdates()).map(updateIdentity), [
        updateIdentity(pending.last),
      ]);
      final confirmation = await (await value.admin).query(
        'stops',
        columns: ['acknowledged_at'],
        where: 'id = ?',
        whereArgs: [first.stopId],
      );
      expect(confirmation.single['acknowledged_at'], isA<int>());
      await value.reopen();
      expect(
        (await value.repository.pendingUpdates()).single.operationId,
        pending.last.operationId,
      );
      expect(
        (await value.repository.loadStops()).first.operationId,
        first.operationId,
      );
    },
  );

  for (final failAt in ['confirmation write', 'queue removal']) {
    test(
      'ack $failAt failure leaves both confirmation and queue unchanged',
      () async {
        final value = await fixture();
        final stop = (await value.repository.loadStops()).first;
        await value.repository.submit(stop.id, DeliveryStatus.completed);
        final update = (await value.repository.pendingUpdates()).single;
        final target = failAt == 'confirmation write'
            ? 'UPDATE OF acknowledged_at ON stops'
            : 'DELETE ON outbox';
        await (await value.admin).execute('''
        CREATE TRIGGER reject_ack BEFORE $target
        BEGIN SELECT RAISE(ABORT, 'controlled ack failure'); END
      ''');
        await expectLater(
          value.repository.acknowledge(matchingAck(update)),
          throwsA(isA<DatabaseException>()),
        );
        expect((await value.repository.pendingUpdates()).map(updateIdentity), [
          updateIdentity(update),
        ]);
        final confirmation = await (await value.admin).query(
          'stops',
          columns: ['acknowledged_at'],
          where: 'id = ?',
          whereArgs: [stop.id],
        );
        expect(confirmation.single['acknowledged_at'], isNull);
        await (await value.admin).execute('DROP TRIGGER reject_ack');
        expect(await value.repository.acknowledge(matchingAck(update)), isTrue);
        expect(await value.repository.pendingUpdates(), isEmpty);
      },
    );
  }

  test('events contain only stage, operation ID and counts', () async {
    final value = await fixture();
    final stop = (await value.repository.loadStops()).first;
    await value.repository.submit(
      stop.id,
      DeliveryStatus.failed,
      reason: 'Private reason',
    );
    final update = (await value.repository.pendingUpdates()).single;
    await value.repository.acknowledge(matchingAck(update));
    expect(value.events, isNotEmpty);
    expect(
      value.events.every(
        (event) => event.keys.every({'stage', 'operationId', 'count'}.contains),
      ),
      isTrue,
    );
    expect(value.events.toString(), isNot(contains('Fixture Customer')));
    expect(value.events.toString(), isNot(contains('Private reason')));
    expect(value.events.toString(), isNot(contains('Test St')));
  });

  test(
    'observer failure cannot turn a committed mutation into a rejection',
    () async {
      final value = await fixture();
      final repository = SqliteDeliveryRepository(
        databaseFactory: databaseFactoryFfi,
        path: value.databasePath,
        loadCsv: () async => fixtureCsv,
        eventSink: (_) => throw StateError('Observer failed'),
      );
      addTearDown(repository.close);
      final stop = (await repository.loadStops()).first;
      await repository.submit(stop.id, DeliveryStatus.completed);
      final update = (await repository.pendingUpdates()).single;
      expect(await repository.acknowledge(matchingAck(update)), isTrue);
      expect(await repository.pendingUpdates(), isEmpty);
    },
  );
}
