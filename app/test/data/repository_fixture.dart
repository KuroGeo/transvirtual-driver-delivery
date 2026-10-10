import 'dart:io';

import 'package:ocean_delivery/data/delivery/sqlite_delivery_repository.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fixtureCsv =
    '''reference,customer_name,address,latitude,longitude,status,time_window
A,Fixture Customer A,"1 Test St, Sydney",-33.9,151.1,pending,08:00-10:00
B,Fixture Customer B,"2 Test St, Sydney",-33.8,151.2,pending,10:00-12:00
C,Fixture Customer C,"3 Test St, Sydney",-33.7,151.3,completed,12:00-14:00
D,Fixture Customer D,"4 Test St, Sydney",-33.6,151.4,failed,14:00-16:00
''';

class RepositoryFixture {
  RepositoryFixture._(this.directory, this.csv, this.events) {
    repository = SqliteDeliveryRepository(
      databaseFactory: databaseFactoryFfi,
      path: databasePath,
      loadCsv: () async => csv,
      eventSink: events.add,
    );
  }

  final Directory directory;
  String csv;
  final List<Map<String, Object?>> events;
  late SqliteDeliveryRepository repository;
  Database? _admin;

  String get databasePath => path.join(directory.path, 'delivery.db');

  static Future<RepositoryFixture> create({String csv = fixtureCsv}) async {
    final directory = await Directory.systemTemp.createTemp('ocean-n01-');
    return RepositoryFixture._(directory, csv, []);
  }

  Future<Database> get admin async =>
      _admin ??= await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );

  Future<int> rowCount(String table) async {
    final rows = await (await admin).rawQuery(
      'SELECT COUNT(*) AS n FROM $table',
    );
    return rows.single['n'] as int;
  }

  Future<void> reopen({Future<String> Function()? loadCsv}) async {
    await repository.close();
    repository = SqliteDeliveryRepository(
      databaseFactory: databaseFactoryFfi,
      path: databasePath,
      loadCsv: loadCsv ?? () async => throw StateError('Must not reimport'),
      eventSink: events.add,
    );
    await repository.initialize();
  }

  Future<void> dispose() async {
    await _admin?.close();
    await repository.close();
    await directory.delete(recursive: true);
  }
}

Ack matchingAck(PendingUpdate update) => Ack(
  operationId: update.operationId,
  datasetId: update.datasetId,
  stopId: update.stopId,
);

List<Object?> updateIdentity(PendingUpdate update) => [
  update.seq,
  update.operationId,
  update.datasetId,
  update.stopId,
  update.status,
  update.reason,
  update.note,
  update.recordedAt,
];
