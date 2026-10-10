import 'dart:math';

import 'package:csv/csv.dart';
import 'package:sqflite/sqflite.dart';

import '../../models/delivery.dart';
import 'delivery_repository.dart';

class SqliteDeliveryRepository implements DeliveryRepository {
  SqliteDeliveryRepository({
    required this.databaseFactory,
    required this.path,
    required this.loadCsv,
    this.eventSink,
  });

  final DatabaseFactory databaseFactory;
  final String path;
  final Future<String> Function() loadCsv;
  final void Function(Map<String, Object?>)? eventSink;

  Database? _database;
  Future<void>? _initializing;

  @override
  Future<void> initialize() async {
    if (_database != null) return;
    final underway = _initializing;
    if (underway != null) return underway;
    final future = _openAndImport();
    _initializing = future;
    try {
      await future;
    } finally {
      _initializing = null;
    }
  }

  Future<void> _openAndImport() async {
    final database = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (database) => database.execute('PRAGMA foreign_keys = ON'),
        onCreate: _createSchema,
      ),
    );
    try {
      final existing = await database.query('datasets', limit: 1);
      if (existing.isEmpty) {
        // Parse the entire source before starting the short import transaction.
        final stops = _parseCsv(await loadCsv());
        final datasetId = _newId('dataset');
        await database.transaction((transaction) async {
          await transaction.insert('datasets', {'id': datasetId});
          for (final stop in stops) {
            await transaction.insert('stops', {
              'id': stop.id,
              'dataset_id': datasetId,
              'reference': stop.reference,
              'customer_name': stop.customerName,
              'address': stop.address,
              'latitude': stop.latitude,
              'longitude': stop.longitude,
              'status': stop.status.name,
              'reason': stop.reason,
            });
          }
        });
        _emit('import_committed', count: stops.length);
      } else {
        _emit('database_reopened');
      }
      _database = database;
    } catch (_) {
      await database.close();
      _emit('initialize_failed');
      rethrow;
    }
  }

  static Future<void> _createSchema(Database database, int version) async {
    await database.execute('''
      CREATE TABLE datasets (
        id TEXT PRIMARY KEY NOT NULL
      )
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
  }

  @override
  Future<List<Stop>> loadStops() async {
    await initialize();
    final rows = await _database!.query('stops', orderBy: 'rowid');
    return List<Stop>.unmodifiable(rows.map(_stopFromRow));
  }

  @override
  Future<void> submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
  }) async {
    if (status == DeliveryStatus.pending) {
      throw ArgumentError.value(
        status,
        'status',
        'A terminal result is required',
      );
    }
    final savedReason = status == DeliveryStatus.failed ? reason?.trim() : null;
    if (status == DeliveryStatus.failed &&
        (savedReason == null || savedReason.isEmpty)) {
      throw ArgumentError('A failed delivery requires a reason');
    }
    await initialize();
    final operationId = _newId('operation');
    try {
      await _database!.transaction((transaction) async {
        final rows = await transaction.query(
          'stops',
          columns: ['dataset_id'],
          where: 'id = ?',
          whereArgs: [stopId],
        );
        if (rows.isEmpty) throw StateError('The stop does not exist');
        final changed = await transaction.update(
          'stops',
          {
            'status': status.name,
            'reason': savedReason,
            'operation_id': operationId,
          },
          where: 'id = ? AND status = ?',
          whereArgs: [stopId, DeliveryStatus.pending.name],
        );
        if (changed != 1) {
          throw StateError('A terminal delivery cannot be changed');
        }
        await transaction.insert('outbox', {
          'operation_id': operationId,
          'dataset_id': rows.single['dataset_id'],
          'stop_id': stopId,
          'status': status.name,
          'reason': savedReason,
        });
      });
    } catch (_) {
      _emit('submit_failed', operationId: operationId);
      rethrow;
    }
    _emit('submit_committed', operationId: operationId, count: 1);
  }

  @override
  Future<List<PendingUpdate>> pendingUpdates() async {
    await initialize();
    final rows = await _database!.query('outbox', orderBy: 'seq');
    return List<PendingUpdate>.unmodifiable(rows.map(_updateFromRow));
  }

  @override
  Future<bool> acknowledge(Ack ack) async {
    await initialize();
    late final bool accepted;
    try {
      accepted = await _database!.transaction((transaction) async {
        final matching = await transaction.query(
          'outbox',
          columns: ['seq'],
          where: 'operation_id = ? AND dataset_id = ? AND stop_id = ?',
          whereArgs: [ack.operationId, ack.datasetId, ack.stopId],
        );
        if (matching.isEmpty) return false;
        final changed = await transaction.update(
          'stops',
          {'acknowledged_at': DateTime.now().millisecondsSinceEpoch},
          where: 'id = ? AND dataset_id = ? AND operation_id = ?',
          whereArgs: [ack.stopId, ack.datasetId, ack.operationId],
        );
        if (changed != 1) {
          throw StateError('The pending result has no matching delivery');
        }
        final deleted = await transaction.delete(
          'outbox',
          where: 'seq = ?',
          whereArgs: [matching.single['seq']],
        );
        if (deleted != 1) {
          throw StateError('The pending result was not removed');
        }
        return true;
      });
    } catch (_) {
      _emit('ack_failed', operationId: ack.operationId);
      rethrow;
    }
    _emit(
      accepted ? 'ack_committed' : 'ack_rejected',
      operationId: ack.operationId,
      count: accepted ? 1 : 0,
    );
    return accepted;
  }

  @override
  Future<void> close() async {
    final underway = _initializing;
    if (underway != null) await underway;
    final database = _database;
    _database = null;
    await database?.close();
  }

  void _emit(String stage, {String? operationId, int? count}) {
    try {
      eventSink?.call({
        'stage': stage,
        'operationId': ?operationId,
        'count': ?count,
      });
    } catch (_) {
      // An observer cannot turn an already committed transaction into a failure.
    }
  }

  static String _newId(String prefix) {
    final random = Random.secure();
    final value = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '${prefix}_$value';
  }

  static List<Stop> _parseCsv(String source) {
    _validateCsvQuotes(source);
    final rows = Csv(autoDetect: false).decode(source);
    if (rows.length < 2) throw const FormatException('The source has no stops');
    final headers = rows.first.map((value) => value.toString().trim()).toList();
    const requiredFields = [
      'reference',
      'customer_name',
      'address',
      'latitude',
      'longitude',
      'status',
    ];
    if (headers.toSet().length != headers.length ||
        requiredFields.any((field) => !headers.contains(field))) {
      throw const FormatException('The source headers are invalid');
    }
    final references = <String>{};
    final stops = <Stop>[];
    for (final row in rows.skip(1)) {
      if (row.length != headers.length) {
        throw const FormatException('A source row has an invalid field count');
      }
      String field(String name) => row[headers.indexOf(name)].toString().trim();
      final reference = field('reference');
      final customerName = field('customer_name');
      final address = field('address');
      if (reference.isEmpty || customerName.isEmpty || address.isEmpty) {
        throw const FormatException('A source row is missing a required value');
      }
      if (!references.add(reference)) {
        throw const FormatException('The source has duplicate stop references');
      }
      final latitude = double.tryParse(field('latitude'));
      final longitude = double.tryParse(field('longitude'));
      if (latitude == null ||
          !latitude.isFinite ||
          latitude < -90 ||
          latitude > 90 ||
          longitude == null ||
          !longitude.isFinite ||
          longitude < -180 ||
          longitude > 180) {
        throw const FormatException('A source coordinate is invalid');
      }
      final status = DeliveryStatus.values.where(
        (value) => value.name == field('status'),
      );
      if (status.isEmpty) {
        throw const FormatException('A source status is invalid');
      }
      final sourceReason = headers.contains('reason') ? field('reason') : null;
      stops.add(
        Stop(
          id: _newId('stop'),
          reference: reference,
          customerName: customerName,
          address: address,
          latitude: latitude,
          longitude: longitude,
          status: status.single,
          reason: sourceReason == null || sourceReason.isEmpty
              ? null
              : sourceReason,
        ),
      );
    }
    return stops;
  }

  static void _validateCsvQuotes(String source) {
    var quoted = false;
    var fieldStart = true;
    var quoteClosed = false;
    for (var index = 0; index < source.length; index++) {
      final character = source[index];
      if (index == 0 && character == '\uFEFF') continue;
      if (quoted) {
        if (character == '"') {
          if (index + 1 < source.length && source[index + 1] == '"') {
            index++;
          } else {
            quoted = false;
            quoteClosed = true;
          }
        }
      } else if (character == '"') {
        if (!fieldStart || quoteClosed) {
          throw const FormatException('A source field has invalid quoting');
        }
        quoted = true;
        fieldStart = false;
      } else if (character == ',' || character == '\n' || character == '\r') {
        fieldStart = true;
        quoteClosed = false;
      } else {
        if (quoteClosed) {
          throw const FormatException('A source field has invalid quoting');
        }
        fieldStart = false;
      }
    }
    if (quoted) {
      throw const FormatException('A source field has unclosed quoting');
    }
  }

  static Stop _stopFromRow(Map<String, Object?> row) => Stop(
    id: row['id'] as String,
    reference: row['reference'] as String,
    customerName: row['customer_name'] as String,
    address: row['address'] as String,
    latitude: (row['latitude'] as num).toDouble(),
    longitude: (row['longitude'] as num).toDouble(),
    status: DeliveryStatus.values.byName(row['status'] as String),
    reason: row['reason'] as String?,
    operationId: row['operation_id'] as String?,
  );

  static PendingUpdate _updateFromRow(Map<String, Object?> row) =>
      PendingUpdate(
        seq: row['seq'] as int,
        operationId: row['operation_id'] as String,
        datasetId: row['dataset_id'] as String,
        stopId: row['stop_id'] as String,
        status: DeliveryStatus.values.byName(row['status'] as String),
        reason: row['reason'] as String?,
      );
}
