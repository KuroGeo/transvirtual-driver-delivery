import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'data/delivery/sqlite_delivery_repository.dart';
import 'data/delivery/sync_coordinator.dart';
import 'models/delivery.dart';

const _failureReason = 'Harness：收件人不在，保留原失败原因';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final report = await runReliabilityProbe();
  runApp(
    MaterialApp(
      title: 'Ocean Delivery Harness',
      home: Scaffold(
        appBar: AppBar(title: const Text('原生可靠性探针')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(report),
          ),
        ),
      ),
    ),
  );
}

/// Each invocation is one native process. The controller must end that process
/// after the report is written, then launch a fresh one without clearing data.
Future<Map<String, Object?>> runReliabilityProbe() async {
  final events = <Map<String, Object?>>[];
  final report = <String, Object?>{
    'phase': 'starting',
    'pass': false,
    'processId': pid,
    'startedAt': DateTime.now().toUtc().toIso8601String(),
    'operationIds': <String>[],
    'queueCount': null,
    'events': events,
    'transport': 'fake-test-only',
  };
  SqliteDeliveryRepository? repository;
  File? reportFile;
  try {
    final directory = await getDatabasesPath();
    reportFile = File(path.join(directory, 'harness-probe.json'));
    final manifestFile = File(
      path.join(directory, 'harness-probe-manifest.json'),
    );
    repository = SqliteDeliveryRepository(
      databaseFactory: databaseFactory,
      path: path.join(directory, 'ocean_delivery_harness.sqlite'),
      loadCsv: () => rootBundle.loadString('assets/deliveries.csv'),
      eventSink: (event) => events.add({'source': 'repository', ...event}),
    );
    await repository.initialize();
    final stops = await repository.loadStops();
    _require(stops.length == 30, 'Expected the complete 30-stop fixture');
    report['stopCount'] = stops.length;

    if (!await manifestFile.exists()) {
      report['phase'] = 'saved';
      _require(
        (await repository.pendingUpdates()).isEmpty,
        'Initial queue must be empty',
      );
      final pending = stops
          .where((stop) => stop.status == DeliveryStatus.pending)
          .take(2)
          .toList();
      _require(pending.length == 2, 'Two pending stops are required');
      await repository.submit(pending[0].id, DeliveryStatus.completed);
      await repository.submit(
        pending[1].id,
        DeliveryStatus.failed,
        reason: _failureReason,
      );
      final queue = await repository.pendingUpdates();
      _require(
        queue.length == 2,
        'Both transactions must create outbox events',
      );
      final originals = queue.map(_updateJson).toList();
      _verifyStops(await repository.loadStops(), originals);
      report.addAll({
        'operationIds': queue.map((update) => update.operationId).toList(),
        'queue': originals,
        'queueCount': queue.length,
        'reason': _failureReason,
      });
      await _writeJson(manifestFile, {
        'phase': 'saved',
        'originalProcessId': pid,
        'updates': originals,
        'reason': _failureReason,
      });
      events.add({'stage': 'saved_before_process_exit', 'queueCount': 2});
    } else {
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final originals = (manifest['updates'] as List)
          .map((entry) => Map<String, Object?>.from(entry as Map))
          .toList();
      _require(
        originals.length == 2,
        'Manifest must preserve two original updates',
      );
      _require(manifest['reason'] == _failureReason, 'Manifest reason changed');
      _require(
        manifest['originalProcessId'] != pid,
        'A fresh OS process is required',
      );
      report.addAll({
        'operationIds': originals
            .map((update) => update['operationId'])
            .toList(),
        'originalProcessId': manifest['originalProcessId'],
        'reason': manifest['reason'],
      });
      _verifyStops(stops, originals);
      final beforeQueue = await repository.pendingUpdates();
      report['beforeQueue'] = beforeQueue.map(_updateJson).toList();
      report['beforeQueueCount'] = beforeQueue.length;
      final sent = <String>[];
      var activeSends = 0;
      var maxConcurrentSends = 0;
      final transport = FakeSyncTransport(
        onSend: (update) async {
          activeSends += 1;
          if (activeSends > maxConcurrentSends) {
            maxConcurrentSends = activeSends;
          }
          _require(activeSends == 1, 'Transport calls must be serial');
          sent.add(update.operationId);
          events.add({
            'stage': 'fake_send',
            'operationId': update.operationId,
            'seq': update.seq,
            'activeSends': activeSends,
          });
          // Yield once so concurrently started sends would overlap observably.
          await Future<void>.delayed(Duration.zero);
          activeSends -= 1;
          events.add({'stage': 'fake_ack', 'operationId': update.operationId});
          return Ack(
            operationId: update.operationId,
            datasetId: update.datasetId,
            stopId: update.stopId,
          );
        },
      );
      final coordinator = SyncCoordinator(
        repository: repository,
        transport: transport,
        eventSink: (event) => events.add({'source': 'coordinator', ...event}),
      );
      if (manifest['phase'] == 'saved') {
        report['phase'] = 'recovered';
        _require(
          jsonEncode(beforeQueue.map(_updateJson).toList()) ==
              jsonEncode(originals),
          'Reopened queue must preserve original IDs, sequence, statuses and reason',
        );
        events.add({
          'stage': 'reopened_original_queue_verified',
          'queueCount': 2,
        });
        await coordinator.sync();
        _require(
          jsonEncode(sent) ==
              jsonEncode(
                originals.map((update) => update['operationId']).toList(),
              ),
          'Acknowledgements must follow persisted queue order',
        );
        _require(maxConcurrentSends == 1, 'Expected serial fake confirmation');
        manifest['phase'] = 'recovered';
        manifest['recoveredProcessId'] = pid;
      } else {
        report['phase'] = 'confirmed';
        _require(manifest['phase'] == 'recovered', 'Unknown manifest phase');
        _require(
          manifest['recoveredProcessId'] != pid,
          'Confirmation requires another fresh process',
        );
        _require(
          beforeQueue.isEmpty,
          'Acknowledged queue must remain empty after restart',
        );
        await coordinator.sync();
        _require(sent.isEmpty, 'Confirmed operations must not be sent again');
        events.add({'stage': 'idempotent_reopen_verified', 'queueCount': 0});
      }
      final afterQueue = await repository.pendingUpdates();
      _require(
        afterQueue.isEmpty,
        'Only persisted confirmation may drain the queue',
      );
      _verifyStops(await repository.loadStops(), originals);
      report.addAll({
        'queue': afterQueue.map(_updateJson).toList(),
        'queueCount': afterQueue.length,
        'afterQueueCount': afterQueue.length,
        'sentOperationIds': sent,
        'maxConcurrentSends': maxConcurrentSends,
      });
      await _writeJson(manifestFile, manifest);
    }
    await repository.close();
    repository = null;
    report['pass'] = true;
  } catch (error, stackTrace) {
    report['error'] = error.toString();
    report['stackTrace'] = stackTrace.toString();
    events.add({'stage': 'probe_failed', 'error': error.toString()});
  } finally {
    if (repository != null) {
      try {
        await repository.close();
      } catch (error) {
        report['closeError'] = error.toString();
      }
    }
  }
  report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
  if (reportFile != null) await _writeJson(reportFile, report);
  debugPrint('OCEAN_HARNESS_PROBE ${jsonEncode(report)}');
  return report;
}

Map<String, Object?> _updateJson(PendingUpdate update) => {
  'seq': update.seq,
  'operationId': update.operationId,
  'datasetId': update.datasetId,
  'stopId': update.stopId,
  'status': update.status.name,
  'reason': update.reason,
};

void _verifyStops(List<Stop> stops, List<Map<String, Object?>> originals) {
  _require(stops.length == 30, 'Reopening must not re-import or lose stops');
  for (final original in originals) {
    final stop = stops.singleWhere((stop) => stop.id == original['stopId']);
    _require(stop.status.name == original['status'], 'Terminal status changed');
    _require(
      stop.operationId == original['operationId'],
      'Original operation ID changed',
    );
    _require(
      stop.reason == original['reason'],
      'Original failure reason changed',
    );
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> _writeJson(File file, Map<String, Object?> value) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(
    const JsonEncoder.withIndent('  ').convert(value),
    flush: true,
  );
  await temporary.rename(file.path);
}
