import '../../models/delivery.dart';
import '../delivery/sync_coordinator.dart';

/// Simulated acknowledgements for explicit demo mode only.
/// Normal clients must keep the default UnavailableTransport.
class DemoTransport implements SyncTransport {
  DemoTransport({this.latency = const Duration(milliseconds: 720)}) {
    if (latency.isNegative) {
      throw ArgumentError.value(latency, 'latency', 'Must not be negative');
    }
  }

  final Duration latency;

  @override
  Future<Ack> send(PendingUpdate update) async {
    await Future<void>.delayed(latency);
    return Ack(
      operationId: update.operationId,
      datasetId: update.datasetId,
      stopId: update.stopId,
    );
  }
}
