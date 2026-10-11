import '../../models/workbench.dart';

abstract interface class DeliverySettingsStore {
  Future<DeliverySettings> loadSettings();

  Future<void> saveOnline(bool online);

  Future<void> saveViewport(MapViewport viewport);
}
