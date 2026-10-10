import '../../models/delivery.dart';

abstract interface class DeliveryRepository {
  Future<void> initialize();

  Future<List<Stop>> loadStops();

  Future<void> submit(String stopId, DeliveryStatus status, {String? reason});

  Future<List<PendingUpdate>> pendingUpdates();

  Future<bool> acknowledge(Ack ack);

  Future<void> close();
}
