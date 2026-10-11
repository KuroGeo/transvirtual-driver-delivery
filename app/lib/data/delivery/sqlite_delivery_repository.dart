import 'dart:math';

import 'package:csv/csv.dart';
import 'package:sqflite/sqflite.dart';

import '../../models/delivery.dart';
import '../../models/workbench.dart';
import 'delivery_repository.dart';
import 'delivery_settings_store.dart';

class SqliteDeliveryRepository
    implements DeliveryRepository, DeliverySettingsStore {
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
  String? _datasetId;
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
    Database? database;
    try {
      database = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onConfigure: (database) =>
              database.execute('PRAGMA foreign_keys = ON'),
          onCreate: _createSchema,
          onUpgrade: _upgradeSchema,
        ),
      );
      final existing = await database.query(
        'datasets',
        orderBy: 'rowid',
        limit: 1,
      );
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
              'time_window': stop.timeWindow,
            });
          }
        });
        _datasetId = datasetId;
        _emit('import_committed', count: stops.length);
      } else {
        _datasetId = existing.single['id'] as String;
        _emit('database_reopened');
      }
      _database = database;
    } catch (_) {
      await database?.close();
      _datasetId = null;
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
        time_window TEXT,
        note TEXT,
        recorded_at INTEGER,
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
        note TEXT,
        recorded_at INTEGER,
        FOREIGN KEY (dataset_id, stop_id) REFERENCES stops(dataset_id, id)
      )
    ''');
    await _createSettingsSchema(database);
  }

  static Future<void> _createSettingsSchema(DatabaseExecutor database) async {
    await database.execute('''
      CREATE TABLE delivery_settings (
        dataset_id TEXT PRIMARY KEY NOT NULL REFERENCES datasets(id),
        online INTEGER NOT NULL DEFAULT 1 CHECK (online IN (0, 1)),
        viewport_latitude REAL,
        viewport_longitude REAL,
        viewport_zoom REAL
      )
    ''');
  }

  Future<void> _upgradeSchema(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      // sqflite wraps onUpgrade and user_version in one transaction. A failed
      // source read or SQL write therefore leaves the v1 file ready to retry.
      final source = _parseCsv(await loadCsv());
      await database.execute('ALTER TABLE stops ADD COLUMN time_window TEXT');
      await database.execute('ALTER TABLE stops ADD COLUMN note TEXT');
      await database.execute(
        'ALTER TABLE stops ADD COLUMN recorded_at INTEGER',
      );
      await database.execute('ALTER TABLE outbox ADD COLUMN note TEXT');
      await database.execute(
        'ALTER TABLE outbox ADD COLUMN recorded_at INTEGER',
      );
      await _createSettingsSchema(database);
      for (final stop in source) {
        await database.update(
          'stops',
          {'time_window': stop.timeWindow},
          where: '''reference = ? AND customer_name = ? AND address = ?
            AND latitude = ? AND longitude = ?''',
          whereArgs: [
            stop.reference,
            stop.customerName,
            stop.address,
            stop.latitude,
            stop.longitude,
          ],
        );
      }
    }
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
    String? note,
  }) async {
    if (status == DeliveryStatus.pending) {
      throw ArgumentError.value(
        status,
        'status',
        'A terminal result is required',
      );
    }
    final savedReason = status == DeliveryStatus.failed ? reason?.trim() : null;
    final trimmedNote = note?.trim();
    final savedNote = status == DeliveryStatus.failed && trimmedNote != ''
        ? trimmedNote
        : null;
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
        final recordedAt = DateTime.now().toUtc().millisecondsSinceEpoch;
        final changed = await transaction.update(
          'stops',
          {
            'status': status.name,
            'reason': savedReason,
            'note': savedNote,
            'recorded_at': recordedAt,
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
          'note': savedNote,
          'recorded_at': recordedAt,
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
          {'acknowledged_at': DateTime.now().toUtc().millisecondsSinceEpoch},
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
  Future<DeliverySettings> loadSettings() async {
    await initialize();
    final datasetId = _datasetId!;
    final rows = await _database!.query(
      'delivery_settings',
      where: 'dataset_id = ?',
      whereArgs: [datasetId],
    );
    if (rows.isEmpty) return DeliverySettings(datasetId: datasetId);
    final row = rows.single;
    final latitude = row['viewport_latitude'];
    final longitude = row['viewport_longitude'];
    final zoom = row['viewport_zoom'];
    MapViewport? viewport;
    if (latitude is num && longitude is num && zoom is num) {
      final candidate = MapViewport(
        datasetId: datasetId,
        latitude: latitude.toDouble(),
        longitude: longitude.toDouble(),
        zoom: zoom.toDouble(),
      );
      if (_validViewport(candidate)) viewport = candidate;
    }
    return DeliverySettings(
      datasetId: datasetId,
      online: row['online'] != 0,
      viewport: viewport,
    );
  }

  @override
  Future<void> saveOnline(bool online) async {
    await initialize();
    await _saveSettings({'online': online ? 1 : 0});
  }

  @override
  Future<void> saveViewport(MapViewport viewport) async {
    if (!_validViewport(viewport)) {
      throw ArgumentError.value(viewport, 'viewport', 'Invalid map viewport');
    }
    await initialize();
    if (viewport.datasetId != _datasetId) {
      throw ArgumentError.value(
        viewport.datasetId,
        'datasetId',
        'The viewport belongs to a different dataset',
      );
    }
    await _saveSettings({
      'viewport_latitude': viewport.latitude,
      'viewport_longitude': viewport.longitude,
      'viewport_zoom': viewport.zoom,
    });
  }

  Future<void> _saveSettings(Map<String, Object?> values) async {
    final datasetId = _datasetId!;
    await _database!.transaction((transaction) async {
      final changed = await transaction.update(
        'delivery_settings',
        values,
        where: 'dataset_id = ?',
        whereArgs: [datasetId],
      );
      if (changed == 0) {
        await transaction.insert('delivery_settings', {
          'dataset_id': datasetId,
          ...values,
        });
      }
    });
  }

  static bool _validViewport(MapViewport viewport) =>
      viewport.latitude.isFinite &&
      viewport.latitude >= -90 &&
      viewport.latitude <= 90 &&
      viewport.longitude.isFinite &&
      viewport.longitude >= -180 &&
      viewport.longitude <= 180 &&
      viewport.zoom.isFinite &&
      viewport.zoom >= 0 &&
      viewport.zoom <= 22;

  @override
  Future<void> close() async {
    final underway = _initializing;
    if (underway != null) await underway;
    final database = _database;
    _database = null;
    _datasetId = null;
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
      'time_window',
    ];
    if (headers.length != requiredFields.length ||
        headers.toSet().length != headers.length ||
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
      final timeWindow = field('time_window');
      if (reference.isEmpty ||
          customerName.isEmpty ||
          address.isEmpty ||
          timeWindow.isEmpty) {
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
      stops.add(
        Stop(
          id: _newId('stop'),
          reference: reference,
          customerName: customerName,
          address: address,
          latitude: latitude,
          longitude: longitude,
          status: status.single,
          timeWindow: timeWindow,
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
    timeWindow: row['time_window'] as String?,
    note: row['note'] as String?,
    recordedAt: _dateFromRow(row['recorded_at']),
    acknowledgedAt: _dateFromRow(row['acknowledged_at']),
  );

  static PendingUpdate _updateFromRow(Map<String, Object?> row) =>
      PendingUpdate(
        seq: row['seq'] as int,
        operationId: row['operation_id'] as String,
        datasetId: row['dataset_id'] as String,
        stopId: row['stop_id'] as String,
        status: DeliveryStatus.values.byName(row['status'] as String),
        reason: row['reason'] as String?,
        note: row['note'] as String?,
        recordedAt: _dateFromRow(row['recorded_at']),
      );

  static DateTime? _dateFromRow(Object? value) => value == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(value as int, isUtc: true);
}
