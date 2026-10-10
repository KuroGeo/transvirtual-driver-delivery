import 'package:ocean_delivery/data/delivery/delivery_repository.dart';
import 'package:ocean_delivery/models/delivery.dart';

class FakeDeliveryRepository implements DeliveryRepository {
  FakeDeliveryRepository()
    : stops = List.generate(
        30,
        (index) => Stop(
          id: 'stop-$index',
          reference: 'REF-${index + 1}',
          customerName: 'Customer ${index + 1}',
          address: '${index + 1} Ocean Street',
          latitude: -33.9,
          longitude: 151.1,
          status: index == 29 ? DeliveryStatus.failed : DeliveryStatus.pending,
        ),
      );

  final List<Stop> stops;
  final List<PendingUpdate> queue = [];
  bool failInitialization = false;
  bool failSubmit = false;
  bool failRefreshAfterSave = false;
  int submitCalls = 0;

  @override
  Future<void> initialize() async {
    if (failInitialization) throw StateError('fixture cannot initialize');
  }

  @override
  Future<List<Stop>> loadStops() async {
    if (failRefreshAfterSave && submitCalls > 0) {
      throw StateError('fixture cannot refresh');
    }
    return List.of(stops);
  }

  @override
  Future<void> submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
    String? note,
  }) async {
    submitCalls += 1;
    if (failSubmit) throw StateError('fixture storage failure');
    final index = stops.indexWhere((stop) => stop.id == stopId);
    final old = stops[index];
    final operationId = 'fixture-operation-$submitCalls';
    final recordedAt = DateTime.now().toUtc();
    stops[index] = Stop(
      id: old.id,
      reference: old.reference,
      customerName: old.customerName,
      address: old.address,
      latitude: old.latitude,
      longitude: old.longitude,
      status: status,
      reason: reason,
      operationId: operationId,
      timeWindow: old.timeWindow,
      note: note,
      recordedAt: recordedAt,
    );
    queue.add(
      PendingUpdate(
        seq: submitCalls,
        operationId: operationId,
        datasetId: 'fixture-dataset',
        stopId: stopId,
        status: status,
        reason: reason,
        note: note,
        recordedAt: recordedAt,
      ),
    );
  }

  @override
  Future<List<PendingUpdate>> pendingUpdates() async => List.of(queue);

  @override
  Future<bool> acknowledge(Ack ack) async {
    final before = queue.length;
    queue.removeWhere(
      (update) =>
          update.operationId == ack.operationId &&
          update.datasetId == ack.datasetId &&
          update.stopId == ack.stopId,
    );
    return before != queue.length;
  }

  @override
  Future<void> close() async {}
}
