import 'package:ocean_delivery/data/delivery/delivery_repository.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';

Stop queryStop(
  String reference, {
  DeliveryStatus status = DeliveryStatus.pending,
  String customer = 'Ocean Customer',
  String address = '10 Ocean Street, Sydney NSW',
  double latitude = TestReference.latitude,
  double longitude = TestReference.longitude,
  String? timeWindow = '08:00-10:00',
}) => Stop(
  id: 'id-$reference',
  reference: reference,
  customerName: customer,
  address: address,
  latitude: latitude,
  longitude: longitude,
  status: status,
  timeWindow: timeWindow,
);

PendingUpdate queryUpdate(String reference, {int seq = 1}) => PendingUpdate(
  seq: seq,
  operationId: 'operation-$seq',
  datasetId: 'query-fixture',
  stopId: 'id-$reference',
  status: DeliveryStatus.completed,
);

/// A separate E03 fixture, leaving the baseline lifecycle fixture untouched.
class QueryRepositoryFixture implements DeliveryRepository {
  QueryRepositoryFixture({List<Stop>? stops, List<PendingUpdate>? queue})
    : records = stops ?? [queryStop('REF-01')],
      updates = queue ?? [];

  final List<Stop> records;
  final List<PendingUpdate> updates;
  bool failSubmit = false;
  int _sequence = 0;

  DeliveryViewModel createModel() => DeliveryViewModel(
    repository: this,
    syncCoordinator: SyncCoordinator(repository: this),
  );

  @override
  Future<void> initialize() async {}

  @override
  Future<List<Stop>> loadStops() async => List.of(records);

  @override
  Future<List<PendingUpdate>> pendingUpdates() async => List.of(updates);

  @override
  Future<void> submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
    String? note,
  }) async {
    if (failSubmit) throw StateError('controlled write failure');
    final index = records.indexWhere((stop) => stop.id == stopId);
    final old = records[index];
    if (old.status != DeliveryStatus.pending) throw StateError('terminal stop');
    final operationId = 'operation-${++_sequence}';
    records[index] = Stop(
      id: old.id,
      reference: old.reference,
      customerName: old.customerName,
      address: old.address,
      latitude: old.latitude,
      longitude: old.longitude,
      timeWindow: old.timeWindow,
      status: status,
      reason: reason,
      note: note,
      operationId: operationId,
    );
    updates.add(
      PendingUpdate(
        seq: _sequence,
        operationId: operationId,
        datasetId: 'query-fixture',
        stopId: stopId,
        status: status,
        reason: reason,
        note: note,
      ),
    );
  }

  @override
  Future<bool> acknowledge(Ack ack) async {
    final previous = updates.length;
    updates.removeWhere(
      (update) =>
          update.stopId == ack.stopId &&
          update.datasetId == ack.datasetId &&
          update.operationId == ack.operationId,
    );
    return previous != updates.length;
  }

  @override
  Future<void> close() async {}
}
