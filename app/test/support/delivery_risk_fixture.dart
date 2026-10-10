import 'dart:async';
import 'dart:io';

import 'package:ocean_delivery/data/delivery/delivery_repository.dart';
import 'package:ocean_delivery/data/delivery/sqlite_delivery_repository.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../integration_test/support/delivery_fault_fixtures.dart';

/// Owns only a newly-created temporary directory. No production database path.
class DeliveryRiskSandbox {
  DeliveryRiskSandbox._(this.directory);

  final Directory directory;
  final _repositories = <String, SqliteDeliveryRepository>{};
  final _admins = <String, Database>{};

  static Future<DeliveryRiskSandbox> create() async => DeliveryRiskSandbox._(
    await Directory.systemTemp.createTemp('ocean-e04-risk-'),
  );

  String databasePath(String name) {
    if (name.isEmpty || path.basename(name) != name) {
      throw ArgumentError.value(name, 'name', 'Expected a sandbox filename.');
    }
    return path.join(directory.path, name);
  }

  SqliteDeliveryRepository repository(String name) => _repositories.putIfAbsent(
    name,
    () => SqliteDeliveryRepository(
      databaseFactory: databaseFactoryFfi,
      path: databasePath(name),
      loadCsv: () async => independentRiskCsv,
    ),
  );

  Future<Database> admin(String name) async =>
      _admins[name] ??= await databaseFactoryFfi.openDatabase(
        databasePath(name),
        options: OpenDatabaseOptions(singleInstance: false),
      );

  Future<Map<String, Object?>> persistedSnapshot(String name) async {
    final database = await admin(name);
    return {
      'stops': await database.query('stops', orderBy: 'reference'),
      'outbox': await database.query('outbox', orderBy: 'seq'),
      'settings': await database.query('delivery_settings'),
    };
  }

  Future<SqliteDeliveryRepository> reopenWithoutSource(String name) async {
    await _admins.remove(name)?.close();
    await _repositories.remove(name)?.close();
    final reopened = SqliteDeliveryRepository(
      databaseFactory: databaseFactoryFfi,
      path: databasePath(name),
      loadCsv: () async => throw StateError('Cold reopen must not reimport.'),
    );
    _repositories[name] = reopened;
    await reopened.initialize();
    return reopened;
  }

  Future<void> dispose() async {
    for (final database in _admins.values) {
      await database.close();
    }
    for (final repository in _repositories.values) {
      await repository.close();
    }
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

List<Object?> immutableUpdateFacts(PendingUpdate update) => [
  update.seq,
  update.operationId,
  update.datasetId,
  update.stopId,
  update.status,
  update.reason,
  update.note,
  update.recordedAt,
];

/// Separates a received matching response from the actual SQLite ack commit.
/// The delegate, not this fixture, determines whether the commit succeeds.
class AcknowledgementFence implements DeliveryRepository {
  AcknowledgementFence(this.delegate);

  final DeliveryRepository delegate;
  final entered = Completer<Ack>();
  final permitCommit = Completer<void>();

  @override
  Future<bool> acknowledge(Ack ack) async {
    entered.complete(ack);
    await permitCommit.future;
    return delegate.acknowledge(ack);
  }

  @override
  Future<void> initialize() => delegate.initialize();
  @override
  Future<List<Stop>> loadStops() => delegate.loadStops();
  @override
  Future<List<PendingUpdate>> pendingUpdates() => delegate.pendingUpdates();
  @override
  Future<void> submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
    String? note,
  }) => delegate.submit(stopId, status, reason: reason, note: note);
  @override
  Future<void> close() => delegate.close();
}
