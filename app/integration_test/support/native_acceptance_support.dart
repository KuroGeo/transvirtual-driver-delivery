import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'native_driver_support.dart';

const acceptanceScope = 'e08-native-functional-acceptance';
const acceptanceRevision = 6;
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

/// True only when an observed committed viewport agrees with the real camera.
/// Null is meaningful for invalid/absent persisted viewports and is retained.
bool acceptanceCaptureReady(Map<String, dynamic> value) {
  final settings = value['persistedSettings'];
  final viewport = settings is Map ? settings['viewport'] : null;
  if (viewport == null) return true;
  final camera = value['camera'];
  return viewport is Map &&
      camera is Map &&
      ['latitude', 'longitude', 'zoom'].every((key) {
        final actual = camera[key];
        final committed = viewport[key];
        return actual is num &&
            committed is num &&
            actual.isFinite &&
            committed.isFinite &&
            (actual - committed).abs() < .000001;
      });
}

Map<String, dynamic> acceptanceCaptureState(Map<String, dynamic> value) => {
  for (final key in ['outbox', 'persistedStops', 'persistedSettings', 'camera'])
    key: value[key],
};

/// Wait at ordinary case boundaries; held requests and failure samples keep
/// their original immediate observations inside each action callback.
Future<Map<String, dynamic>> acceptanceStableCapture(
  NativeWorkbenchDriver client,
) async {
  final clock = Stopwatch()..start();
  Map<String, dynamic>? previous;
  Duration? stableSince;
  return client.waitForSnapshot(
    'stable readonly capture and committed camera',
    (value) {
      final state = acceptanceCaptureState(value);
      if (!acceptanceCaptureReady(value)) {
        previous = null;
        stableSince = null;
        return false;
      }
      if (previous == null || !acceptanceEqual(previous, state)) {
        previous = state;
        stableSince = clock.elapsed;
        return false;
      }
      return clock.elapsed - stableSince! >= const Duration(milliseconds: 500);
    },
  );
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
      context.before = await acceptanceStableCapture(client);
      context.beforePath = await evidence(
        '${context.slug}-before.json',
        context.before,
      );
      await action(context);
      context.after = await acceptanceStableCapture(client);
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
    'revision': acceptanceRevision,
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
    if (nativeObject(model['selected'])['status'] == 'pending' &&
        !nativeObject(value['bounds']).containsKey('detail-return')) {
      await acceptanceCloseDetail(client);
    } else {
      await acceptanceReturn(client);
    }
  }
  final next = await client.snapshot();
  if (acceptanceModel(next)['panel'] == 'list') {
    await client.tapKey('close-list');
  }
  final map = await client.snapshot();
  if (nativeObject(map['bounds']).containsKey('summary-close')) {
    await client.tapKey('summary-close');
  }
  await client.waitForSnapshot(
    'typed UI map return',
    (value) =>
        acceptanceModel(value)['panel'] == 'map' &&
        !nativeObject(value['bounds']).containsKey('large-summary-workspace'),
  );
}

/// Expose a real summary field with bounded drags in its actual scroll view.
/// Large text opens a separate task; normal compact text keeps the overview.
Future<Map<String, dynamic>> acceptanceSummaryKey(
  NativeWorkbenchDriver client,
  String key, {
  bool entireField = false,
}) async {
  var value = await client.snapshot();
  if (nativeObject(value['bounds']).containsKey('map-summary-open')) {
    await client.tapKey('map-summary-open');
    value = await client.waitForSnapshot(
      'actual large-text summary opened',
      (snapshot) =>
          acceptanceModel(snapshot)['panel'] == 'map' &&
          nativeObject(snapshot['bounds']).containsKey('large-summary-scroll'),
    );
  }
  final lookupClock = Stopwatch()..start();
  for (var scrolls = 0; ; scrolls++) {
    final bounds = nativeObject(value['bounds']);
    final rows = bounds[key];
    final target = rows is List && rows.length == 1 && rows.single is Map
        ? nativeObject(rows.single)
        : null;
    final scrollKey = bounds.containsKey('large-summary-scroll')
        ? 'large-summary-scroll'
        : 'overview-summary';
    final scrollRows = bounds[scrollKey];
    final viewport =
        scrollRows is List && scrollRows.length == 1 && scrollRows.single is Map
        ? nativeObject(scrollRows.single)
        : null;
    if (target != null && target['centerHit'] == true) {
      if (!entireField ||
          viewport != null &&
              (target['top'] as num) >= (viewport['top'] as num) - .5 &&
              (target['bottom'] as num) <= (viewport['bottom'] as num) + .5 &&
              (target['left'] as num) >= (viewport['left'] as num) - .5 &&
              (target['right'] as num) <= (viewport['right'] as num) + .5) {
        return value;
      }
    }
    nativeRequire(
      scrolls < 12 &&
          lookupClock.elapsed < NativeWorkbenchDriver.observationDeadline &&
          viewport != null,
      'Summary $key was not exposed in its actual viewport '
      'within 12 drags and 15 seconds.',
    );
    final actualViewport = viewport!;
    var drag = -160.0;
    if (target != null) {
      if (entireField) {
        nativeRequire(
          (target['height'] as num) <= (actualViewport['height'] as num) + .5 &&
              (target['width'] as num) <= (actualViewport['width'] as num) + .5,
          'The full summary $key must fit its actual reading viewport.',
        );
      }
      if ((target['top'] as num) < (actualViewport['top'] as num)) {
        drag = ((actualViewport['top'] as num) - (target['top'] as num) + 8)
            .clamp(48, 160)
            .toDouble();
      } else if ((target['bottom'] as num) >
          (actualViewport['bottom'] as num)) {
        drag =
            -((target['bottom'] as num) - (actualViewport['bottom'] as num) + 8)
                .clamp(48, 160)
                .toDouble();
      }
    }
    await client
        .scrollKey(scrollKey, drag)
        .timeout(
          NativeWorkbenchDriver.observationDeadline - lookupClock.elapsed,
        );
    nativeRequire(
      lookupClock.elapsed < NativeWorkbenchDriver.observationDeadline,
      'Summary lookup exceeded its unchanged 15-second deadline.',
    );
    value = await client.snapshot().timeout(
      NativeWorkbenchDriver.observationDeadline - lookupClock.elapsed,
    );
    nativeRequire(
      acceptanceModel(value)['panel'] == 'map',
      'Summary lookup left its actual map task.',
    );
  }
}

Future<void> acceptanceNearest(NativeWorkbenchDriver client) async {
  await acceptanceSummaryKey(client, 'nearest-stop');
  await client.tapKey('nearest-stop');
}

Future<void> acceptanceListQueryTools(NativeWorkbenchDriver client) async {
  final initial = await client.snapshot();
  final bounds = nativeObject(initial['bounds']);
  final toggles = bounds['list-query-controls'];
  nativeRequire(
    toggles is List && toggles.length == 1 && toggles.single is Map,
    'Query controls require their actual persistent header button.',
  );
  // An expanded query can be outside the lazy-list cache after a typed Return.
  // Observe the actual button state rather than toggling from missing bounds.
  final selected = (toggles as List).single['isSelected'];
  nativeRequire(
    selected is bool,
    'Query button must expose its actual bool state.',
  );
  if (selected != true) {
    await client.tapKey('list-query-controls');
    await client.waitForSnapshot('expanded list search controls', (snapshot) {
      final controls = nativeObject(snapshot['bounds'])['list-query-controls'];
      return controls is List &&
          controls.length == 1 &&
          controls.single is Map &&
          controls.single['isSelected'] == true;
    });
  }
  bool searchIsExposed(Map<String, dynamic> snapshot) {
    final rows = nativeObject(snapshot['bounds'])['stop-search'];
    return rows is List &&
        rows.length == 1 &&
        rows.single is Map &&
        rows.single['centerHit'] == true;
  }

  var value = await client.snapshot();
  // A typed Return preserves the offset; a scaled heading can put the query
  // below the viewport. Choose a real drag from observed geometry in either
  // direction rather than resetting the session or inferring a hit.
  final searchClock = Stopwatch()..start();
  const maxScrolls = 12;
  for (var scrolls = 0; !searchIsExposed(value); scrolls++) {
    nativeRequire(
      scrolls < maxScrolls &&
          searchClock.elapsed < NativeWorkbenchDriver.observationDeadline,
      'List search was not exposed with a hittable center '
      'within 12 drags and 15 seconds.',
    );
    final bounds = nativeObject(value['bounds']);
    final scrollKey = bounds.containsKey('list-query-scroll')
        ? 'list-query-scroll'
        : 'stop-list-scroll';
    final scroll = nativeObject((bounds[scrollKey] as List).single);
    final search = bounds['stop-search'];
    final heading = bounds['list-title'];
    final double drag;
    if (search is List && search.length == 1 && search.single is Map) {
      final rect = nativeObject(search.single);
      drag =
          ((rect['top'] as num) + (rect['bottom'] as num)) / 2 >
              (scroll['bottom'] as num)
          ? -160
          : 160;
    } else {
      // An unbuilt query follows an exposed scrollable heading. Otherwise
      // the retained deep offset requires moving back toward the beginning.
      drag =
          heading is List &&
              heading.length == 1 &&
              heading.single is Map &&
              (nativeObject(heading.single)['bottom'] as num) >
                  (scroll['top'] as num)
          ? -160
          : 160;
    }
    await client
        .scrollKey(scrollKey, drag)
        .timeout(
          NativeWorkbenchDriver.observationDeadline - searchClock.elapsed,
        );
    nativeRequire(
      searchClock.elapsed < NativeWorkbenchDriver.observationDeadline,
      'List search was not exposed with a hittable center '
      'within its 15-second lookup deadline.',
    );
    value = await client.snapshot().timeout(
      NativeWorkbenchDriver.observationDeadline - searchClock.elapsed,
    );
    nativeRequire(
      acceptanceModel(value)['panel'] == 'list',
      'Search exposure left the actual list panel.',
    );
  }
}

Future<void> acceptanceList(NativeWorkbenchDriver client) async {
  await acceptanceMap(client);
  await client.revealKey('browse-stops');
  await client.tapKey('browse-stops');
  await client.waitForSnapshot(
    'actual stop list',
    (value) => acceptanceModel(value)['panel'] == 'list',
  );
  final value = await client.snapshot();
  final query = nativeObject(acceptanceModel(value)['query']);
  if (query['status'] != null || query['waitingOnly'] == true) {
    await acceptanceListQueryTools(client);
  }
  for (final key in [
    if (query['status'] != null) 'filter-all',
    if (query['waitingOnly'] == true) 'waiting-only',
  ]) {
    // Retained query tools can also retain a horizontal chip offset. Let the
    // real nested scroll views expose the control before the original tap.
    await client.revealKey(key);
    final exposed = await client.snapshot();
    final rows = nativeObject(exposed['bounds'])[key];
    nativeRequire(
      rows is List && rows.length == 1 && rows.single is Map,
      'Query normalization requires one actual onstage $key.',
    );
    final rect = nativeObject((rows as List).single);
    nativeRequire(
      rect['centerHit'] == true &&
          rect['width'] is num &&
          (rect['width'] as num).isFinite &&
          (rect['width'] as num) >= 44 &&
          rect['height'] is num &&
          (rect['height'] as num).isFinite &&
          (rect['height'] as num) >= 44,
      'Actual query control $key must be hittable and at least44px before tap.',
    );
    await client.tapKey(key);
  }
}

Future<void> acceptanceOpenListStop(
  NativeWorkbenchDriver client,
  String reference,
) async {
  bool keyIsExposed(Map<String, dynamic> snapshot, String key) {
    final rows = nativeObject(snapshot['bounds'])[key];
    return rows is List &&
        rows.length == 1 &&
        rows.single is Map &&
        (rows.single as Map)['centerHit'] == true;
  }

  var value = await client.snapshot();
  if (acceptanceModel(value)['panel'] != 'list') {
    await acceptanceList(client);
    value = await client.snapshot();
  }
  nativeRequire(
    acceptanceModel(value)['panel'] == 'list',
    'Search exposure requires the actual list panel.',
  );
  await acceptanceListQueryTools(client);
  await client.enterText('stop-search', reference);
  var searched = await client.waitForSnapshot(
    'list search $reference',
    (value) =>
        acceptanceModel(value)['panel'] == 'list' &&
        nativeObject(acceptanceModel(value)['query'])['search'] == reference &&
        nativeObject(value['result'])['matchedCount'] == 1,
  );
  // Large text uses a separate full-height filter task. Return through its
  // real control before searching the result list; retain query and session.
  if (nativeObject(searched['bounds']).containsKey('list-query-scroll')) {
    await client.tapKey('list-query-controls');
    searched = await client.waitForSnapshot(
      'close large-text query tools before reading $reference',
      (s) =>
          !nativeObject(s['bounds']).containsKey('list-query-scroll') &&
          acceptanceModel(s)['panel'] == 'list',
    );
  }
  // SliverList may omit unbuilt rows or retain cached offstage RenderBoxes
  // that the SDK finder cannot reveal. Move the actual primary scroll view
  // until the target's real center is hittable, then use the existing
  // reveal/tap path. Each drag and observation remains journalled.
  final rowKey = 'stop-$reference';
  final lookupClock = Stopwatch()..start();
  const maxScrolls = 12;
  for (var scrolls = 0; !keyIsExposed(searched, rowKey); scrolls++) {
    nativeRequire(
      scrolls < maxScrolls &&
          lookupClock.elapsed < NativeWorkbenchDriver.observationDeadline,
      'Lazy list row $reference was not exposed with a hittable center '
      'within 12 drags and 15 seconds.',
    );
    await client
        .scrollKey('stop-list-scroll', -160)
        .timeout(
          NativeWorkbenchDriver.observationDeadline - lookupClock.elapsed,
        );
    nativeRequire(
      lookupClock.elapsed < NativeWorkbenchDriver.observationDeadline,
      'Lazy list row $reference was not exposed with a hittable center '
      'within its 15-second lookup deadline.',
    );
    searched = await client.snapshot().timeout(
      NativeWorkbenchDriver.observationDeadline - lookupClock.elapsed,
    );
    nativeRequire(
      acceptanceModel(searched)['panel'] == 'list' &&
          nativeObject(acceptanceModel(searched)['query'])['search'] ==
              reference &&
          nativeObject(searched['result'])['matchedCount'] == 1,
      'Lazy row lookup lost its unique actual list query for $reference.',
    );
  }
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

Future<void> acceptanceCloseDetail(NativeWorkbenchDriver client) async {
  final value = await client.snapshot();
  final model = acceptanceModel(value);
  nativeRequire(model['panel'] == 'detail', 'Close requires actual detail UI.');
  nativeRequire(
    const ['list', 'map', 'nearest'].contains(model['selectedOrigin']),
    'Close requires a recorded typed detail source.',
  );
  final destination = model['selectedOrigin'] == 'list' ? 'list' : 'map';
  await client.tapKey('detail-close');
  await client.waitForSnapshot(
    'actual detail Close restores $destination source',
    (value) => acceptanceModel(value)['panel'] == destination,
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
