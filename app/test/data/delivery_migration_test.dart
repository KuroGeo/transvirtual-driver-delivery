import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/delivery/sqlite_delivery_repository.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'legacy_repository_fixture.dart';
import 'repository_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<RepositoryFixture> fixture({String csv = fixtureCsv}) async {
    final value = await RepositoryFixture.create(csv: csv);
    addTearDown(value.dispose);
    return value;
  }

  test(
    'real v1 file migrates preserving results, identity, queue and sequence',
    () async {
      final source = await File('assets/deliveries.csv').readAsString();
      final value = await fixture(csv: source);
      final legacy = await createLegacyDatabase(value.databasePath, source);
      final oldStops = await legacy.query('stops', orderBy: 'rowid');
      final oldQueue = await legacy.query('outbox', orderBy: 'seq');
      await legacy.close();

      await value.repository.initialize();
      final stops = await value.repository.loadStops();
      expect(stops, hasLength(30));
      final rows = await (await value.admin).query('stops', orderBy: 'rowid');
      for (var index = 0; index < oldStops.length; index++) {
        final old = oldStops[index];
        expect({for (final key in old.keys) key: rows[index][key]}, old);
      }
      final queueRows = await (await value.admin).query(
        'outbox',
        orderBy: 'seq',
      );
      for (var index = 0; index < oldQueue.length; index++) {
        final old = oldQueue[index];
        expect({for (final key in old.keys) key: queueRows[index][key]}, old);
      }
      final windows = {
        for (final row in Csv(autoDetect: false).decode(source).skip(1))
          row[0].toString(): row[6].toString(),
      };
      expect(
        stops.every((stop) => stop.timeWindow == windows[stop.reference]),
        isTrue,
      );
      expect(
        stops.every((stop) => stop.recordedAt == null && stop.note == null),
        isTrue,
      );
      expect(
        stops[2].acknowledgedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
      );
      expect(stops[0].acknowledgedAt, isNull);
      final pending = await value.repository.pendingUpdates();
      expect(pending.map((update) => update.seq), [7, 11]);
      expect(pending.last.reason, '  Historical reason  ');
      expect(
        pending.every(
          (update) => update.note == null && update.recordedAt == null,
        ),
        isTrue,
      );
      expect(
        (await value.repository.loadSettings()).datasetId,
        'legacy-dataset',
      );
      expect(await (await value.admin).getVersion(), 2);

      final nextStop = stops.firstWhere(
        (stop) => stop.status == DeliveryStatus.pending,
      );
      await value.repository.submit(nextStop.id, DeliveryStatus.completed);
      expect((await value.repository.pendingUpdates()).last.seq, 23);
      expect(
        await value.repository.acknowledge(matchingAck(pending.first)),
        isTrue,
      );
      await value.reopen();
      expect(
        (await value.repository.pendingUpdates()).map((update) => update.seq),
        [11, 23],
      );
      expect(
        (await value.repository.loadStops())[1].operationId,
        'legacy-operation-1',
      );
      expect(
        (await value.repository.loadStops())[2].acknowledgedAt,
        stops[2].acknowledgedAt,
      );
    },
  );

  for (final mismatch in {
    'reference': {'reference': 'not-the-source-reference'},
    'customer identity': {'customer_name': 'Another customer'},
    'address identity': {'address': 'Another address'},
    'latitude': {'latitude': -33.900001},
    'longitude': {'longitude': 151.100001},
  }.entries) {
    test('time window is not inferred on mismatched ${mismatch.key}', () async {
      final value = await fixture();
      final legacy = await createLegacyDatabase(value.databasePath, fixtureCsv);
      await legacy.update(
        'stops',
        mismatch.value,
        where: 'id = ?',
        whereArgs: ['legacy-A'],
      );
      await legacy.close();
      await value.repository.initialize();
      final stops = await value.repository.loadStops();
      expect(stops[0].timeWindow, isNull);
      expect(stops.skip(1).every((stop) => stop.timeWindow != null), isTrue);
      expect(stops[0].operationId, 'legacy-operation-0');
      expect(stops[0].status, DeliveryStatus.completed);
      expect(
        (await value.repository.pendingUpdates()).map((update) => update.seq),
        [7, 11],
      );
    });
  }

  test(
    'unknown source identity remains null without deleting the legacy stop',
    () async {
      final value = await fixture();
      final legacy = await createLegacyDatabase(value.databasePath, fixtureCsv);
      await legacy.close();
      value.csv = fixtureCsv
          .split('\n')
          .where((line) => !line.startsWith('D,'))
          .join('\n');
      final stops = await value.repository.loadStops();
      expect(stops, hasLength(4));
      expect(stops.last.timeWindow, isNull);
      expect(stops.last.status, DeliveryStatus.failed);
      expect(stops.last.reason, isNull);
      expect(stops.last.note, isNull);
    },
  );

  for (final failure in [
    'file source read',
    'source validation',
    'SQL backfill',
  ]) {
    test(
      'v1 $failure failure rolls back version and schema, then retries',
      () async {
        final value = await fixture();
        final legacy = await createLegacyDatabase(
          value.databasePath,
          fixtureCsv,
        );
        final oldStops = await legacy.query('stops', orderBy: 'rowid');
        final oldQueue = await legacy.query('outbox', orderBy: 'seq');
        if (failure == 'SQL backfill') {
          await legacy.execute('''
          CREATE TRIGGER reject_backfill BEFORE UPDATE ON stops
          WHEN NEW.id = 'legacy-B'
          BEGIN SELECT RAISE(ABORT, 'controlled migration backfill failure'); END
        ''');
        }
        await legacy.close();
        var readFails = failure == 'file source read';
        value.repository = SqliteDeliveryRepository(
          databaseFactory: databaseFactoryFfi,
          path: value.databasePath,
          loadCsv: () async {
            if (readFails) {
              throw const FileSystemException(
                'Controlled missing migration asset',
              );
            }
            return value.csv;
          },
          eventSink: value.events.add,
        );
        if (failure == 'source validation') value.csv = 'invalid,source\n';
        await expectLater(
          value.repository.initialize(),
          failure == 'file source read'
              ? throwsA(isA<FileSystemException>())
              : failure == 'source validation'
              ? throwsFormatException
              : throwsA(isA<DatabaseException>()),
        );
        final admin = await value.admin;
        expect(await admin.getVersion(), 1);
        final columns = await admin.rawQuery('PRAGMA table_info(stops)');
        expect(
          columns.map((column) => column['name']),
          isNot(contains('time_window')),
        );
        expect(await admin.query('stops', orderBy: 'rowid'), oldStops);
        expect(await admin.query('outbox', orderBy: 'seq'), oldQueue);
        expect(
          await admin.rawQuery(
            "SELECT name FROM sqlite_master WHERE name = 'delivery_settings'",
          ),
          isEmpty,
        );
        expect(value.events.last['stage'], 'initialize_failed');
        if (failure == 'SQL backfill') {
          await admin.execute('DROP TRIGGER reject_backfill');
        }
        readFails = false;
        value.csv = fixtureCsv;
        await value.repository.initialize();
        expect(await admin.getVersion(), 2);
        expect(
          (await value.repository.loadStops()).map((stop) => stop.id),
          oldStops.map((stop) => stop['id']),
        );
        expect(
          (await value.repository.pendingUpdates()).map((update) => update.seq),
          [7, 11],
        );
      },
    );
  }
}
