import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'native_driver_support.dart';

const acceptanceScope = 'e08-native-functional-acceptance';
const acceptanceChecks = <String, List<String>>{
  'N1': [
    'N1.first-import',
    'N1.offline-two-results',
    'N1.cold-preservation',
    'N1.serial-confirmation',
    'N1.no-resend',
  ],
  'N2': [
    'N2.unavailable',
    'N2.failure-options',
    'N2.other-validation',
    'N2.imported-unknown',
    'N2.submit-rollback-retry',
    'N2.terminal-double-tap',
    'N2.settings-retry',
  ],
  'N3': [
    'N3.wrong-ack',
    'N3.send-timeout',
    'N3.ack-rollback',
    'N3.pause-inflight',
    'N3.tail-enqueue',
    'N3.single-owner',
  ],
  'N4': [
    'N4.map-controls',
    'N4.query-intersection-empty',
    'N4.reference-nearest',
    'N4.typed-returns',
    'N4.notice-context',
  ],
  'N5': [
    'N5.tile-degraded-retry',
    'N5.cache-only-clear',
    'N5.valid-viewport-cold',
    'N5.invalid-viewport-fallback',
  ],
  'N6': ['N6.genuine-v1-upgrade', 'N6.migration-rollback-retry'],
  'N7': [
    'N7.two-sizes-safearea',
    'N7.os-keyboard',
    'N7.text-scale',
    'N7.reduced-motion-semantics',
    'N7.platform-back',
  ],
};

Map<String, dynamic> acceptanceModel(Map<String, dynamic> value) =>
    nativeObject(value['model']);
List<Map<String, dynamic>> acceptanceOutbox(Map<String, dynamic> value) =>
    nativeObjects(value['outbox']);
Map<String, dynamic> acceptanceStop(
  Map<String, dynamic> value,
  String reference, {
  bool persisted = false,
}) => nativeObjects(
  value[persisted ? 'persistedStops' : 'stops'],
).singleWhere((row) => row['reference'] == reference);
bool acceptanceIdle(Map<String, dynamic> value) {
  if (value['model'] == null) return false;
  final model = acceptanceModel(value);
  return model['initialized'] == true &&
      model['isLoading'] == false &&
      model['isSaving'] == false &&
      model['isSyncing'] == false &&
      model['isChangingOnline'] == false;
}

bool acceptanceEqual(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) =>
              right.containsKey(key) && acceptanceEqual(left[key], right[key]),
        );
  }
  if (left is List && right is List) {
    return left.length == right.length &&
        List.generate(
          left.length,
          (i) => i,
        ).every((i) => acceptanceEqual(left[i], right[i]));
  }
  return left == right;
}

Object? acceptancePointer(Object? document, String pointer) {
  if (pointer.isEmpty) return document;
  nativeRequire(
    pointer.startsWith('/') && pointer.length <= 512,
    'Invalid bounded JSON pointer.',
  );
  var current = document;
  for (final component in pointer.substring(1).split('/')) {
    final key = component.replaceAll('~1', '/').replaceAll('~0', '~');
    if (current is Map && current.containsKey(key)) {
      current = current[key];
    } else if (current is List &&
        int.tryParse(key) != null &&
        int.parse(key) >= 0 &&
        int.parse(key) < current.length) {
      current = current[int.parse(key)];
    } else {
      return const _Absent();
    }
  }
  return current;
}

class _Absent {
  const _Absent();
}

/// This receipt records assertions against raw observations. It does not grant
/// acceptance: the host hashes immutable artifacts and the independent gate
/// checks its own minimum predicates and real OS lifecycle receipts.
class NativeAcceptanceRecorder {
  NativeAcceptanceRecorder(this.client)
    : scenario = client.options.required('scenario');
  final NativeWorkbenchDriver client;
  final String scenario;
  final checks = <Map<String, Object?>>[];
  final _documents = <String, Object?>{};
  Map<String, dynamic>? last;
  String relative(String name) => '${client.options.phase}/$name';

  Future<String> evidence(String name, Object? document) async {
    final file = File(path.join(client.options.output.path, name));
    nativeRequire(
      !await file.exists(),
      'Acceptance evidence cannot be overwritten: $name',
    );
    await client.writeJson(name, document);
    final reference = relative(name);
    _documents[reference] = document;
    return reference;
  }

  Future<Object?> document(String reference) async {
    if (_documents.containsKey(reference)) return _documents[reference];
    nativeRequire(
      RegExp(
        r'^(saved|recovered|confirmed)/[a-z0-9-]+\.json$',
      ).hasMatch(reference),
      'Evidence reference must remain inside the native run.',
    );
    final file = File(
      path.join(path.dirname(client.options.output.path), reference),
    );
    nativeRequire(
      await file.exists() && await file.length() <= 8 * 1024 * 1024,
      'Missing or oversized raw evidence $reference',
    );
    return _documents[reference] = jsonDecode(await file.readAsString());
  }

  Future<void> check(
    String id,
    Future<void> Function(AcceptanceCase) action,
    Future<void> Function(AcceptanceCase) verify,
  ) async {
    nativeRequire(
      acceptanceChecks[scenario]!.contains(id) &&
          !checks.any((row) => row['id'] == id),
      'Unknown or duplicate acceptance check $id',
    );
    final context = AcceptanceCase(this, id, client.actionSequence + 1);
    try {
      context.before = await client.snapshot();
      context.beforePath = await evidence(
        '${context.slug}-before.json',
        context.before,
      );
      await action(context);
      context.after = await client.snapshot();
      context.afterPath = await evidence(
        '${context.slug}-after.json',
        context.after,
      );
      last = context.after;
      context.capture = await client.captureNamed(context.slug, context.after);
      await verify(context);
      checks.add(context.record('passed'));
    } catch (error) {
      checks.add(context.record('failed', reason: error.toString()));
      await flush(status: 'failed');
      rethrow;
    }
  }

  void notApplicable(String id, String reason) {
    nativeRequire(
      acceptanceChecks[scenario]!.contains(id) &&
          !checks.any((row) => row['id'] == id),
      'Unknown/duplicate check',
    );
    checks.add({
      'id': id,
      'status': 'not_applicable',
      'reason': reason,
      'actionSequenceStart': null,
      'actionSequenceEnd': null,
      'artifacts': <String>[],
      'assertions': <Object>[],
    });
  }

  Future<void> flush({
    String status = 'passed',
  }) => client.writeJson('e08-phase-receipt.json', {
    'schema': 1,
    'revision': 5,
    'scope': acceptanceScope,
    'status': status,
    'scenario': scenario,
    'phase': client.options.phase,
    'processId': client.options.processId,
    'vmProcessId': client.vmProcessId,
    'session': client.options.session,
    'candidate': client.options.candidate,
    'configuration': client.options.configuration,
    'databasePath': last?['databasePath'],
    'transport': last?['transport'],
    'launchConfigPath': last?['launchConfigPath'],
    'launchConfigByteLength': last?['launchConfigByteLength'],
    'launchConfigSchema': last?['launchConfigSchema'],
    'checks': checks,
    'textEntry':
        'flutter-driver-emulated unless an OS-inset check explicitly proves otherwise',
    'hardwareBack':
        'not_applicable on iOS; typed UI/modal actions recorded separately',
  });
}

class AcceptanceCase {
  AcceptanceCase(this.recorder, this.id, this.start);
  final NativeAcceptanceRecorder recorder;
  final String id;
  final int start;
  String get slug => 'case-${id.toLowerCase().replaceAll('.', '-')}';
  Map<String, dynamic> before = {}, after = {}, capture = {};
  String? beforePath, afterPath;
  final assertions = <Map<String, Object?>>[];
  final extraArtifacts = <String>[];
  final samples = <String>[];
  final metadata = <String, Object?>{};
  Future<String> evidence(String suffix, Object? value) async {
    final reference = await recorder.evidence('$slug-$suffix.json', value);
    extraArtifacts.add(reference);
    return reference;
  }

  Future<String> sample(String suffix, Map<String, dynamic> value) async {
    final reference = await evidence(suffix, value);
    samples.add(reference);
    return reference;
  }

  Future<void> expect(
    String pointer,
    String op,
    Object? value, {
    String? artifact,
    String? rightArtifact,
    String? rightPointer,
  }) async {
    final reference = artifact ?? afterPath!;
    final actual = acceptancePointer(
      await recorder.document(reference),
      pointer,
    );
    final wanted = rightArtifact == null
        ? value
        : acceptancePointer(
            await recorder.document(rightArtifact),
            rightPointer!,
          );
    final passed = switch (op) {
      'eq' =>
        actual is! _Absent &&
            wanted is! _Absent &&
            acceptanceEqual(actual, wanted),
      'gte' => actual is num && wanted is num && actual >= wanted,
      'lte' => actual is num && wanted is num && actual <= wanted,
      'length' =>
        (actual is List || actual is Map || actual is String) &&
            (actual as dynamic).length == wanted,
      'absent' => actual is _Absent,
      _ => false,
    };
    nativeRequire(
      passed,
      '$id raw assertion failed: $reference $pointer $op $wanted (actual $actual)',
    );
    assertions.add({
      'artifact': reference,
      'pointer': pointer,
      'op': op,
      if (op != 'absent') ...{
        if (rightArtifact == null)
          'value': value
        else
          'right': {'artifact': rightArtifact, 'pointer': rightPointer},
      },
    });
  }

  Future<void> same(String pointer, {String? beforePointer}) => expect(
    pointer,
    'eq',
    null,
    rightArtifact: beforePath!,
    rightPointer: beforePointer ?? pointer,
  );
  Map<String, Object?> record(String status, {String? reason}) => {
    'id': id,
    'status': status,
    'reason': ?reason,
    'phase': recorder.client.options.phase,
    'processId': recorder.client.options.processId,
    'vmProcessId': recorder.client.vmProcessId,
    'session': recorder.client.options.session,
    'candidate': recorder.client.options.candidate,
    'configuration': recorder.client.options.configuration,
    'transport': after['transport'],
    'actionSequenceStart': start,
    'actionSequenceEnd': recorder.client.actionSequence,
    'before': beforePath,
    'after': afterPath,
    'capture': {
      'png': recorder.relative('$slug.png'),
      'sqlite': recorder.relative('$slug.sqlite'),
      'projection': recorder.relative('$slug.sqlite.json'),
      'journal': recorder.relative('$slug.journal.jsonl'),
    },
    'artifacts': [
      if (beforePath != null) beforePath,
      if (afterPath != null) afterPath,
      ...extraArtifacts,
      recorder.relative('$slug-host-capture.json'),
      recorder.relative('$slug-flutter.png'),
    ],
    'samples': samples,
    ...metadata,
    'assertions': assertions,
  };
}

Future<Map<String, dynamic>> acceptanceReady(
  NativeWorkbenchDriver client, {
  bool tiles = true,
}) => client.waitForSnapshot(
  'actual formal native workbench ready',
  (value) =>
      acceptanceIdle(value) &&
      nativeObjects(value['stops']).length == 30 &&
      value['mapReady'] == true &&
      (!tiles || value['tileStatus'] == 'ready'),
);
Future<Map<String, dynamic>> acceptanceWaitIdle(NativeWorkbenchDriver client) =>
    client.waitForSnapshot('business UI operation settled', acceptanceIdle);
Future<void> acceptanceOnline(NativeWorkbenchDriver client, bool online) async {
  final current = await client.snapshot();
  if (acceptanceModel(current)['online'] != online) {
    await client.tapKey('online-toggle');
  }
  await client.waitForSnapshot(
    'Online flag persisted $online',
    (value) =>
        acceptanceIdle(value) &&
        acceptanceModel(value)['online'] == online &&
        nativeObject(value['persistedSettings'])['online'] == online,
  );
}

Future<void> acceptanceMap(NativeWorkbenchDriver client) async {
  final value = await client.snapshot();
  final model = acceptanceModel(value);
  if (model['panel'] == 'detail') {
    await client.revealKey('detail-return');
    await client.tapKey('detail-return');
  }
  final next = await client.snapshot();
  if (acceptanceModel(next)['panel'] == 'list') {
    await client.tapKey('close-list');
  }
  await client.waitForSnapshot(
    'typed UI map return',
    (value) => acceptanceModel(value)['panel'] == 'map',
  );
}

Future<void> acceptanceList(NativeWorkbenchDriver client) async {
  await acceptanceMap(client);
  await client.tapKey('browse-stops');
  await client.waitForSnapshot(
    'actual stop list',
    (value) => acceptanceModel(value)['panel'] == 'list',
  );
  final value = await client.snapshot();
  final query = nativeObject(acceptanceModel(value)['query']);
  if (query['status'] != null) await client.tapKey('filter-all');
  if (query['waitingOnly'] == true) await client.tapKey('waiting-only');
}

Future<void> acceptanceOpenListStop(
  NativeWorkbenchDriver client,
  String reference,
) async {
  final value = await client.snapshot();
  if (acceptanceModel(value)['panel'] != 'list') await acceptanceList(client);
  await client.enterText('stop-search', reference);
  await client.waitForSnapshot(
    'list search $reference',
    (value) =>
        acceptanceModel(value)['panel'] == 'list' &&
        nativeObject(acceptanceModel(value)['query'])['search'] == reference &&
        nativeObject(value['result'])['matchedCount'] == 1,
  );
  await client.revealKey('stop-$reference');
  await client.tapKey('stop-$reference');
  await client.waitForSnapshot(
    'actual list-origin detail $reference',
    (value) =>
        acceptanceModel(value)['panel'] == 'detail' &&
        acceptanceModel(value)['selectedOrigin'] == 'list' &&
        nativeObject(acceptanceModel(value)['selected'])['reference'] ==
            reference,
  );
}

Future<void> acceptanceReturn(NativeWorkbenchDriver client) async {
  await client.revealKey('detail-return');
  await client.tapKey('detail-return');
  await client.waitForSnapshot(
    'typed detail Return',
    (value) => acceptanceModel(value)['panel'] != 'detail',
  );
}

Future<void> acceptanceComplete(
  NativeWorkbenchDriver client,
  String reference,
) async {
  await acceptanceOpenListStop(client, reference);
  await client.revealKey('detail-complete');
  await client.tapKey('detail-complete');
  await client.waitForSnapshot(
    'durable completed $reference',
    (value) =>
        acceptanceModel(value)['isSaving'] == false &&
        acceptanceModel(value)['isLoading'] == false &&
        nativeObject(acceptanceModel(value)['selected'])['status'] ==
            'completed' &&
        acceptanceStop(value, reference, persisted: true)['status'] ==
            'completed',
  );
}

Future<void> acceptanceFailureOpen(
  NativeWorkbenchDriver client,
  String reference,
) async {
  await acceptanceOpenListStop(client, reference);
  await client.revealKey('detail-fail');
  await client.tapKey('detail-fail');
  await client.waitForSnapshot(
    'actual failure sheet',
    (value) => nativeObject(value['bounds']).containsKey('failure-sheet'),
  );
}

Future<void> acceptanceFailureSave(
  NativeWorkbenchDriver client,
  String reference,
  String reasonKey,
  String note,
) async {
  await acceptanceFailureOpen(client, reference);
  await client.revealKey('failure-reason-$reasonKey');
  await client.tapKey('failure-reason-$reasonKey');
  if (note.isNotEmpty) await client.enterText('failure-note', note);
  await client.revealKey('failure-save', alignment: 1);
  await client.tapKey('failure-save');
  await client.waitForSnapshot(
    'durable failed $reference',
    (value) =>
        acceptanceIdle(value) &&
        !nativeObject(value['bounds']).containsKey('failure-sheet') &&
        acceptanceStop(value, reference, persisted: true)['status'] == 'failed',
  );
}

Future<Map<String, dynamic>> acceptanceBaseline(
  NativeWorkbenchDriver client,
) async {
  final value = nativeObject(
    jsonDecode(await File(client.options.required('baseline')).readAsString()),
  );
  final current = await client.snapshot();
  nativeRequire(
    value['candidate'] == current['candidate'] &&
        value['configuration'] == current['configuration'] &&
        value['databasePath'] == current['databasePath'] &&
        value['processId'] != current['processId'] &&
        value['session'] != current['session'],
    'Cold proof requires a different real PID/session on the same database.',
  );
  return value;
}

List<Map<String, dynamic>> acceptanceEvents(
  Map<String, dynamic> value,
  NativeWorkbenchDriver client,
  String stage,
) => nativeObjects(nativeObject(value['journal'])['events'])
    .where(
      (event) =>
          event['session'] == client.options.session &&
          event['processId'] == client.options.processId &&
          event['stage'] == stage,
    )
    .toList();
bool acceptanceCameraMatches(Object? camera, Object? viewport) =>
    camera is Map &&
    viewport is Map &&
    ['latitude', 'longitude', 'zoom'].every(
      (key) =>
          camera[key] is num &&
          viewport[key] is num &&
          ((camera[key] as num) - (viewport[key] as num)).abs() < .00001,
    );
