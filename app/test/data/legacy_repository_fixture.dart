import 'package:csv/csv.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A real file with the unmodified v1 schema, not a v2 file with a lower version.
Future<Database> createLegacyDatabase(String path, String source) async {
  final database = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      singleInstance: false,
      onConfigure: (database) => database.execute('PRAGMA foreign_keys = ON'),
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE datasets (id TEXT PRIMARY KEY NOT NULL)
        ''');
        await database.execute('''
          CREATE TABLE stops (
            id TEXT PRIMARY KEY NOT NULL,
            dataset_id TEXT NOT NULL REFERENCES datasets(id),
            reference TEXT NOT NULL,
            customer_name TEXT NOT NULL,
            address TEXT NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('pending', 'completed', 'failed')),
            reason TEXT,
            operation_id TEXT UNIQUE,
            acknowledged_at INTEGER,
            UNIQUE (dataset_id, reference),
            UNIQUE (dataset_id, id)
          )
        ''');
        await database.execute('''
          CREATE TABLE outbox (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            operation_id TEXT NOT NULL UNIQUE,
            dataset_id TEXT NOT NULL,
            stop_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('completed', 'failed')),
            reason TEXT,
            FOREIGN KEY (dataset_id, stop_id) REFERENCES stops(dataset_id, id)
          )
        ''');
      },
    ),
  );
  await database.transaction((transaction) async {
    await transaction.insert('datasets', {'id': 'legacy-dataset'});
    final rows = Csv(autoDetect: false).decode(source).skip(1).toList();
    for (final row in rows) {
      await transaction.insert('stops', {
        'id': 'legacy-${row[0]}',
        'dataset_id': 'legacy-dataset',
        'reference': row[0],
        'customer_name': row[1],
        'address': row[2],
        'latitude': double.parse(row[3].toString()),
        'longitude': double.parse(row[4].toString()),
        'status': row[5],
      });
    }
    for (var index = 0; index < 2; index++) {
      final stopId = 'legacy-${rows[index][0]}';
      final operationId = 'legacy-operation-$index';
      final status = index == 0 ? 'completed' : 'failed';
      final reason = index == 0 ? null : '  Historical reason  ';
      await transaction.update(
        'stops',
        {'status': status, 'reason': reason, 'operation_id': operationId},
        where: 'id = ?',
        whereArgs: [stopId],
      );
      await transaction.insert('outbox', {
        'seq': index == 0 ? 7 : 11,
        'operation_id': operationId,
        'dataset_id': 'legacy-dataset',
        'stop_id': stopId,
        'status': status,
        'reason': reason,
      });
    }
    await transaction.update(
      'stops',
      {
        'status': 'completed',
        'operation_id': 'historically-acknowledged',
        'acknowledged_at': 1700000000000,
      },
      where: 'id = ?',
      whereArgs: ['legacy-${rows[2][0]}'],
    );
    // A deleted old result still consumes its AUTOINCREMENT identity.
    await transaction.insert('outbox', {
      'seq': 22,
      'operation_id': 'previously-deleted',
      'dataset_id': 'legacy-dataset',
      'stop_id': 'legacy-${rows[2][0]}',
      'status': 'completed',
    });
    await transaction.delete('outbox', where: 'seq = 22');
  });
  return database;
}
