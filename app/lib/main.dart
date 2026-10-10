import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'app/ocean_delivery_app.dart';
import 'app/runtime_configuration.dart';
import 'data/delivery/sqlite_delivery_repository.dart';
import 'data/delivery/sync_coordinator.dart';
import 'ui/delivery_view_model.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final configuration = RuntimeConfiguration.environment;
  runApp(
    OceanDeliveryApp(
      createViewModel: () => createLocalViewModel(configuration: configuration),
      demo: configuration.isDemo,
    ),
  );
}

Future<DeliveryViewModel> createLocalViewModel({
  RuntimeConfiguration? configuration,
}) async {
  final runtime = configuration ?? RuntimeConfiguration.environment;
  final databaseDirectory = await getDatabasesPath();
  final repository = SqliteDeliveryRepository(
    databaseFactory: databaseFactory,
    path: path.join(databaseDirectory, runtime.databaseName),
    loadCsv: () => rootBundle.loadString('assets/deliveries.csv'),
  );
  return DeliveryViewModel(
    repository: repository,
    syncCoordinator: SyncCoordinator(
      repository: repository,
      transport: runtime.isDemo
          ? const FakeSyncTransport()
          : const UnavailableTransport(),
    ),
  );
}
