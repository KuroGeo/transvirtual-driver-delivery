import 'dart:async';
import 'dart:collection';

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

enum SyncStage { started, sending, acknowledged, paused, failed, finished }

/// Counts only acknowledgements already committed by the repository.
/// [SyncStage.paused] requests pause; an in-flight matching ack can still commit.
class SyncProgress {
  const SyncProgress({
    required this.stage,
    required this.runId,
    required this.confirmedCount,
    this.operationId,
    this.error,
  });

  final SyncStage stage;
  final int runId;
  final int confirmedCount;
  final String? operationId;
  final Object? error;
}

typedef SyncProgressListener = void Function(SyncProgress progress);

class SyncCoordinator {
  SyncCoordinator({
    required this.repository,
    SyncTransport? transport,
    this.eventSink,
    this.requestTimeout = const Duration(seconds: 5),
  }) : transport = transport ?? const UnavailableTransport() {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'Must be positive',
      );
    }
  }

  final DeliveryRepository repository;
  final SyncTransport transport;
  final void Function(Map<String, Object?>)? eventSink;
  final Duration requestTimeout;

  _SyncRun? _active;
  int _nextRunId = 0;
  int _requested = 0;
  bool _pauseRequested = false;
  final Set<SyncProgressListener> _listeners = {};
  final Queue<SyncProgress> _notifications = Queue();
  bool _notifying = false;
  SyncProgress? _progress;

  bool get isRunning => _active != null;
  SyncProgress? get progress => _progress;

  void addListener(SyncProgressListener listener) => _listeners.add(listener);

  void removeListener(SyncProgressListener listener) =>
      _listeners.remove(listener);

  /// Join the single drain and request a fresh queue read, including after pause.
  /// A failed drain stops; only a subsequent explicit request starts a retry.
  Future<void> sync() {
    _requested++;
    _pauseRequested = false;
    final active = _active;
    if (active != null) return active.completion.future;
    final run = _SyncRun(++_nextRunId);
    _active = run;
    unawaited(Future<void>.microtask(() => _run(run)));
    return run.completion.future;
  }

  void pause() {
    if (_pauseRequested) return;
    _pauseRequested = true;
    final run = _active;
    _emit(
      SyncProgress(
        stage: SyncStage.paused,
        runId: run?.id ?? _nextRunId,
        confirmedCount: run?.confirmed ?? _progress?.confirmedCount ?? 0,
      ),
    );
  }

  Future<void> _run(_SyncRun run) async {
    Object? failure;
    StackTrace? failureStack;
    try {
      _emit(
        SyncProgress(
          stage: SyncStage.started,
          runId: run.id,
          confirmedCount: 0,
        ),
      );
      while (!_pauseRequested) {
        final requestedAtRead = _requested;
        final pending = await repository.pendingUpdates();
        if (_pauseRequested) break;
        if (pending.isEmpty) {
          // A committed addition can arrive while this empty snapshot is in
          // flight. Its trigger must be consumed by another read, not lost.
          if (requestedAtRead != _requested) continue;
          break;
        }
        final update = pending.first;
        _emit(
          SyncProgress(
            stage: SyncStage.sending,
            runId: run.id,
            confirmedCount: run.confirmed,
            operationId: update.operationId,
          ),
        );
        if (_pauseRequested) break;
        // This deadline releases the logical drain. Dart Futures cannot cancel
        // underlying network work; timeout's late result never enters ack code.
        final ack = await transport.send(update).timeout(requestTimeout);
        if (ack.operationId != update.operationId ||
            ack.datasetId != update.datasetId ||
            ack.stopId != update.stopId) {
          throw StateError('The service acknowledgement does not match');
        }
        if (!await repository.acknowledge(ack)) {
          throw StateError('The service acknowledgement was not persisted');
        }
        run.confirmed++;
        _emit(
          SyncProgress(
            stage: SyncStage.acknowledged,
            runId: run.id,
            confirmedCount: run.confirmed,
            operationId: update.operationId,
          ),
        );
      }
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      // Terminal observers may request a new run. Release this exact owner
      // first, and never clear ownership in a later whenComplete callback.
      if (identical(_active, run)) _active = null;
      if (failure != null) {
        _emit(
          SyncProgress(
            stage: SyncStage.failed,
            runId: run.id,
            confirmedCount: run.confirmed,
            error: failure,
          ),
        );
      }
      _emit(
        SyncProgress(
          stage: SyncStage.finished,
          runId: run.id,
          confirmedCount: run.confirmed,
          error: failure,
        ),
      );
      if (failure == null) {
        run.completion.complete();
      } else {
        run.completion.completeError(failure, failureStack);
      }
    }
  }

  void _emit(SyncProgress progress) {
    _notifications.add(progress);
    if (_notifying) return;
    _notifying = true;
    try {
      while (_notifications.isNotEmpty) {
        final event = _notifications.removeFirst();
        _progress = event;
        try {
          eventSink?.call({
            'stage': switch (event.stage) {
              SyncStage.paused => 'sync_pause_requested',
              _ => 'sync_${event.stage.name}',
            },
            'operationId': ?event.operationId,
            if (event.stage == SyncStage.acknowledged ||
                event.stage == SyncStage.failed ||
                event.stage == SyncStage.finished)
              'count': event.confirmedCount,
          });
        } catch (_) {
          // Observers are outside the delivery/acknowledgement transaction.
        }
        for (final listener in List<SyncProgressListener>.of(_listeners)) {
          if (!_listeners.contains(listener)) continue;
          try {
            listener(event);
          } catch (_) {
            // One observer cannot stop the drain or another observer.
          }
        }
      }
    } finally {
      _notifying = false;
    }
  }
}

class _SyncRun {
  _SyncRun(this.id);

  final int id;
  final Completer<void> completion = Completer<void>();
  int confirmed = 0;
}
