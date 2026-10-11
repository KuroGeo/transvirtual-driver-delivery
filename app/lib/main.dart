import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'app/ocean_delivery_app.dart';
import 'app/runtime_configuration.dart';
import 'data/delivery/sqlite_delivery_repository.dart';
import 'data/delivery/sync_coordinator.dart';
import 'data/services/demo_transport.dart';
import 'models/workbench.dart';
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

/// One assembly path for the formal client and explicit test dependencies.
Future<DeliveryViewModel> createLocalViewModel({
  RuntimeConfiguration? configuration,
  DatabaseFactory? databaseFactoryOverride,
  String? databaseDirectory,
  Future<String> Function()? loadCsv,
  SyncTransport? transport,
  Duration? requestTimeout,
  void Function(Map<String, Object?>)? eventSink,
}) async {
  final runtime = configuration ?? RuntimeConfiguration.environment;
  final directory = databaseDirectory ?? await getDatabasesPath();
  final repository = SqliteDeliveryRepository(
    databaseFactory: databaseFactoryOverride ?? databaseFactory,
    path: path.join(directory, runtime.databaseName),
    loadCsv: loadCsv ?? () => rootBundle.loadString('assets/deliveries.csv'),
    eventSink: (event) => eventSink?.call({'source': 'repository', ...event}),
  );
  return DeliveryViewModel(
    repository: repository,
    settingsStore: repository,
    mode: runtime.isDemo ? ClientMode.demo : ClientMode.localClient,
    automaticSync: true,
    syncCoordinator: SyncCoordinator(
      repository: repository,
      transport:
          transport ??
          (runtime.isDemo ? DemoTransport() : const UnavailableTransport()),
      requestTimeout: requestTimeout ?? const Duration(seconds: 5),
      eventSink: (event) =>
          eventSink?.call({'source': 'coordinator', ...event}),
    ),
  );
}
