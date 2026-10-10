import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'app/ocean_delivery_app.dart';
import 'data/delivery/sqlite_delivery_repository.dart';
import 'data/delivery/sync_coordinator.dart';
import 'ui/delivery_view_model.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(OceanDeliveryApp(createViewModel: createLocalViewModel));
}

Future<DeliveryViewModel> createLocalViewModel() async {
  final databaseDirectory = await getDatabasesPath();
  final repository = SqliteDeliveryRepository(
    databaseFactory: databaseFactory,
    path: path.join(databaseDirectory, 'ocean_delivery.sqlite'),
    loadCsv: () => rootBundle.loadString('assets/deliveries.csv'),
  );
  return DeliveryViewModel(
    repository: repository,
    syncCoordinator: SyncCoordinator(
      repository: repository,
      transport: UnavailableTransport(),
    ),
  );
}
