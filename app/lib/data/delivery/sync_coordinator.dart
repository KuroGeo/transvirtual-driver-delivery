import '../../models/delivery.dart';
import 'delivery_repository.dart';

abstract interface class SyncTransport {
  Future<Ack> send(PendingUpdate update);
}

class UnavailableTransport implements SyncTransport {
  const UnavailableTransport();

  @override
  Future<Ack> send(PendingUpdate update) =>
      Future.error(StateError('The delivery service is unavailable'));
}

/// Only for isolated tests and the explicit reliability probe.
class FakeSyncTransport implements SyncTransport {
  const FakeSyncTransport({this.onSend});

  final Future<Ack> Function(PendingUpdate)? onSend;

  @override
  Future<Ack> send(PendingUpdate update) async =>
      onSend != null ? await onSend!(update) : _matchingAck(update);

  static Ack _matchingAck(PendingUpdate update) => Ack(
    operationId: update.operationId,
    datasetId: update.datasetId,
    stopId: update.stopId,
  );
}

class SyncCoordinator {
  SyncCoordinator({
    required this.repository,
    SyncTransport? transport,
    this.eventSink,
  }) : transport = transport ?? const UnavailableTransport();

  final DeliveryRepository repository;
  final SyncTransport transport;
  final void Function(Map<String, Object?>)? eventSink;

  Future<void>? _running;
  bool _pauseRequested = false;

  bool get isRunning => _running != null;

  Future<void> sync() {
    final running = _running;
    if (running != null) return running;
    _pauseRequested = false;
    final future = Future<void>.microtask(
      _run,
    ).whenComplete(() => _running = null);
    _running = future;
    return future;
  }

  void pause() {
    _pauseRequested = true;
    _emit('sync_pause_requested');
  }

  Future<void> _run() async {
    var confirmed = 0;
    _emit('sync_started');
    try {
      while (!_pauseRequested) {
        final pending = await repository.pendingUpdates();
        if (_pauseRequested || pending.isEmpty) break;
        final update = pending.first;
        _emit('sync_sending', operationId: update.operationId);
        final ack = await transport.send(update);
        if (ack.operationId != update.operationId ||
            ack.datasetId != update.datasetId ||
            ack.stopId != update.stopId) {
          throw StateError('The service acknowledgement does not match');
        }
        if (!await repository.acknowledge(ack)) {
          throw StateError('The service acknowledgement was not persisted');
        }
        confirmed++;
        _emit(
          'sync_acknowledged',
          operationId: update.operationId,
          count: confirmed,
        );
      }
    } catch (_) {
      _emit('sync_failed', count: confirmed);
      rethrow;
    } finally {
      _emit('sync_finished', count: confirmed);
    }
  }

  void _emit(String stage, {String? operationId, int? count}) {
    try {
      eventSink?.call({
        'stage': stage,
        'operationId': ?operationId,
        'count': ?count,
      });
    } catch (_) {
      // Telemetry is outside the delivery/acknowledgement contract.
    }
  }
}
