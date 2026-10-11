import 'dart:convert';
import 'dart:io';

import 'support/native_driver_support.dart';

/// X02 tooling smoke only. Independent E08 acceptance supplies its own driver.
Future<void> main(List<String> arguments) async {
  final options = NativeDriverOptions.parse(arguments);
  if (options.values.containsKey('fixture')) {
    throw UnsupportedError(
      'Legacy fixture requires an independent E08 driver.',
    );
  }
  NativeWorkbenchDriver? client;
  try {
    client = await NativeWorkbenchDriver.connect(options);
    final snapshot = await _run(client).timeout(const Duration(seconds: 150));
    await Future<void>.delayed(const Duration(seconds: 5));
    await client.capture(snapshot);
    await client.writeJson('result.json', {
      'schema': 1,
      'status': 'passed',
      'scope': 'paced-native-demo-recording',
      'phase': options.phase,
      'processId': options.processId,
      'vmProcessId': client.vmProcessId,
      'session': options.session,
      'candidate': options.candidate,
      'configuration': options.configuration,
      'transport': snapshot['transport'],
      'launchConfigPath': snapshot['launchConfigPath'],
      'launchConfigByteLength': snapshot['launchConfigByteLength'],
      'launchConfigSchema': snapshot['launchConfigSchema'],
      'textEntry': 'flutter-driver-emulated',
      'osKeyboard': 'not_run; no real IME claim',
      'hardwareBack': 'not_applicable on iOS; typed UI Return exercised',
    });
  } catch (error, stack) {
    if (client != null) {
      await client.writeJson('result.json', {
        'schema': 1,
        'status': 'failed',
        'scope': 'paced-native-demo-recording',
        'phase': options.phase,
        'processId': options.processId,
        'vmProcessId': client.vmProcessId,
        'session': options.session,
        'candidate': options.candidate,
        'configuration': options.configuration,
        'error': error.toString(),
        'stack': stack.toString(),
      });
    }
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    await client?.close();
  }
  // A timed-out SDK connection can still own a socket Future. End the failed
  // driver process after bounded cleanup; the parent retains the resource lease.
  if (exitCode != 0) exit(exitCode);
}

Map<String, dynamic> _model(Map<String, dynamic> snapshot) =>
    nativeObject(snapshot['model']);

bool _idle(Map<String, dynamic> snapshot) {
  final value = snapshot['model'];
  if (value == null) return false;
  final model = nativeObject(value);
  return model['initialized'] == true &&
      model['isLoading'] == false &&
      model['isSaving'] == false &&
      model['isSyncing'] == false &&
      model['isChangingOnline'] == false;
}

List<Map<String, dynamic>> _outbox(Map<String, dynamic> snapshot) =>
    nativeObjects(snapshot['outbox']);

List<Map<String, dynamic>> _currentEvents(
  Map<String, dynamic> snapshot,
  NativeDriverOptions options,
) => nativeObjects(nativeObject(snapshot['journal'])['events']).where((event) {
  return event['session'] == options.session &&
      event['processId'] == options.processId &&
      event['candidate'] == options.candidate &&
      event['configuration'] == options.configuration;
}).toList();

Future<Map<String, dynamic>> _run(NativeWorkbenchDriver client) async {
  final initial = await client.waitForSnapshot(
    'formal30/native database/map ready',
    (snapshot) =>
        _idle(snapshot) &&
        nativeObjects(snapshot['stops']).length == 30 &&
        snapshot['mapReady'] == true &&
        snapshot['tileStatus'] == 'ready',
  );
  nativeRequire(
    initial['transport'] ==
        (client.options.configuration == 'demo'
            ? 'controlled-http-simulated'
            : 'unavailable-local-client'),
    'Launch transport does not match the controlled native configuration.',
  );
  final media = nativeObject(initial['mediaQuery']);
  nativeRequire(
    (media['width'] as num) > 0 && (media['height'] as num) > 0,
    'Actual native MediaQuery is missing.',
  );
  await client.writeJson('initial-snapshot.json', initial);
  await Future<void>.delayed(const Duration(seconds: 5));
  return client.options.phase == 'saved'
      ? _save(client, initial)
      : _recover(client, initial);
}

Future<Map<String, dynamic>> _save(
  NativeWorkbenchDriver client,
  Map<String, dynamic> initial,
) async {
  final stops = nativeObjects(initial['stops']);
  int count(String status) =>
      stops.where((stop) => stop['status'] == status).length;
  nativeRequire(
    count('pending') == 24 &&
        count('completed') == 3 &&
        count('failed') == 3 &&
        _outbox(initial).isEmpty,
    'Smoke must start in a newly-created sandbox with the approved30-stop asset.',
  );
  nativeRequire(
    _currentEvents(
          initial,
          client.options,
        ).where((event) => event['stage'] == 'import_committed').length ==
        1,
    'Actual native first import was not observed exactly once.',
  );
  final pending = stops.where((stop) => stop['status'] == 'pending').toList();
  final complete = pending[0];
  final fail = pending[1];
  await client.tapKey('online-toggle');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  await client.waitForSnapshot(
    'offline setting committed',
    (snapshot) =>
        _idle(snapshot) &&
        _model(snapshot)['online'] == false &&
        nativeObject(snapshot['persistedSettings'])['online'] == false,
  );
  await client.tapKey('browse-stops');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  await _openListStop(client, complete);
  await client.revealKey('detail-complete');
  await client.tapKey('detail-complete');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  final completed = await client.waitForSnapshot(
    'actual complete UI save remains in terminal detail',
    (snapshot) =>
        _idle(snapshot) &&
        _model(snapshot)['panel'] == 'detail' &&
        nativeObject(_model(snapshot)['selected'])['status'] == 'completed' &&
        _outbox(snapshot).length == 1,
  );
  _terminalDetail(completed, complete['id'] as String);
  await client.revealKey('detail-return');
  await client.back('detail-return');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  await _openListStop(client, fail);
  await client.revealKey('detail-fail');
  await client.tapKey('detail-fail');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  await client.revealKey('failure-reason-recipient-unavailable');
  await client.tapKey('failure-reason-recipient-unavailable');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  await client.enterText('failure-note', 'Recipient unavailable on arrival.');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  await client.revealKey('failure-save', alignment: 1);
  await client.tapKey('failure-save');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  final failed = await client.waitForSnapshot(
    'actual failure UI save/readonly detail/two immutable outbox events',
    (snapshot) =>
        _idle(snapshot) &&
        _model(snapshot)['panel'] == 'detail' &&
        nativeObject(_model(snapshot)['selected'])['status'] == 'failed' &&
        _outbox(snapshot).length == 2 &&
        !nativeObject(snapshot['bounds']).containsKey('failure-sheet'),
  );
  _terminalDetail(failed, fail['id'] as String);
  final selected = nativeObject(_model(failed)['selected']);
  nativeRequire(
    selected['reason'] == 'Recipient unavailable' &&
        selected['note'] == 'Recipient unavailable on arrival.',
    'Real failed-delivery reason/note did not persist.',
  );
  for (final event in _outbox(failed)) {
    final stop = nativeObjects(
      failed['persistedStops'],
    ).singleWhere((stop) => stop['id'] == event['stopId']);
    nativeRequire(
      stop['operationId'] == event['operationId'] &&
          stop['recordedAt'] == event['recordedAt'] &&
          stop['status'] == event['status'] &&
          stop['reason'] == event['reason'] &&
          stop['note'] == event['note'],
      'Saved native state and immutable outbox do not match.',
    );
  }
  await client.revealKey('detail-return');
  await client.back('detail-return');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  await client.back('close-list');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  // Leave deliberate transient state and an explicitly changed durable camera
  // so cold recovery must distinguish session query/panel from saved settings.
  await client.tapKey('header-filter-failed');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  await client.revealKey('map-waiting-only');
  await client.tapKey('map-waiting-only');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  await client.tapKey('zoom-in');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  return client.waitForSnapshot(
    'two saved events, offline, nondefault query and persisted camera',
    (snapshot) {
      if (!_idle(snapshot) || _outbox(snapshot).length != 2) return false;
      final model = _model(snapshot);
      final query = nativeObject(model['query']);
      final viewport = nativeObject(snapshot['persistedSettings'])['viewport'];
      return model['online'] == false &&
          model['panel'] == 'map' &&
          query['search'] == fail['reference'] &&
          query['status'] == 'failed' &&
          query['waitingOnly'] == true &&
          viewport != null &&
          _cameraMatches(snapshot['camera'], viewport);
    },
  );
}

Future<void> _openListStop(
  NativeWorkbenchDriver client,
  Map<String, dynamic> stop,
) async {
  final reference = stop['reference'] as String;
  if (!nativeObject(
    (await client.snapshot())['bounds'],
  ).containsKey('stop-search')) {
    await client.tapKey('list-query-controls');
    await Future<void>.delayed(const Duration(milliseconds: 1600));
  }
  await client.enterText('stop-search', reference);
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  await client.waitForSnapshot(
    'search $reference via actual TextField',
    (snapshot) =>
        _model(snapshot)['panel'] == 'list' &&
        nativeObject(_model(snapshot)['query'])['search'] == reference &&
        nativeObject(snapshot['result'])['matchedCount'] == 1,
  );
  await client.revealKey('stop-$reference');
  await client.tapKey('stop-$reference');
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  await client.waitForSnapshot(
    'list-origin detail $reference',
    (snapshot) =>
        _model(snapshot)['panel'] == 'detail' &&
        _model(snapshot)['selectedOrigin'] == 'list' &&
        nativeObject(_model(snapshot)['selected'])['id'] == stop['id'],
  );
}

void _terminalDetail(Map<String, dynamic> snapshot, String id) {
  final model = _model(snapshot);
  final bounds = nativeObject(snapshot['bounds']);
  nativeRequire(
    model['selectedOrigin'] == 'list' &&
        nativeObject(model['selected'])['id'] == id &&
        !bounds.containsKey('detail-complete') &&
        !bounds.containsKey('detail-fail') &&
        bounds.containsKey('detail-return'),
    'Terminal detail lost its source/identity or retained record actions.',
  );
}

bool _cameraMatches(Object? camera, Object? viewport) {
  if (camera == null || viewport == null) return false;
  final observed = nativeObject(camera);
  final saved = nativeObject(viewport);
  return ['latitude', 'longitude', 'zoom'].every(
    (key) => ((observed[key] as num) - (saved[key] as num)).abs() < .00001,
  );
}

Future<Map<String, dynamic>> _recover(
  NativeWorkbenchDriver client,
  Map<String, dynamic> initial,
) async {
  final baseline = nativeObject(
    jsonDecode(await File(client.options.required('baseline')).readAsString()),
  );
  nativeRequire(
    baseline['candidate'] == client.options.candidate &&
        baseline['configuration'] == client.options.configuration &&
        baseline['processId'] != client.options.processId &&
        baseline['session'] != client.options.session &&
        baseline['databasePath'] == initial['databasePath'],
    'Cold recovery requires a different OS launch of the same candidate/data.',
  );
  final model = _model(initial);
  final query = nativeObject(model['query']);
  nativeRequire(
    model['panel'] == 'map' &&
        model['selected'] == null &&
        query['search'] == '' &&
        query['status'] == null &&
        query['waitingOnly'] == false,
    'A cold launch incorrectly restored transient query/detail state.',
  );
  nativeRequire(
    _currentEvents(
              initial,
              client.options,
            ).where((event) => event['stage'] == 'database_reopened').length ==
            1 &&
        !_currentEvents(
          initial,
          client.options,
        ).any((event) => event['stage'] == 'import_committed'),
    'Native cold launch reimported or did not reopen the existing database.',
  );
  final savedEvents = _outbox(baseline);
  nativeRequire(
    savedEvents.length == 2,
    'Saved smoke baseline must have2 events.',
  );
  for (final event in savedEvents) {
    final stop = nativeObjects(
      initial['persistedStops'],
    ).singleWhere((stop) => stop['id'] == event['stopId']);
    nativeRequire(
      [
        'operationId',
        'status',
        'reason',
        'note',
        'recordedAt',
      ].every((key) => stop[key] == event[key]),
      'Cold native result lost immutable identity/reason/note/time.',
    );
  }
  if (client.options.phase == 'recovered') {
    nativeRequire(
      model['online'] == false &&
          jsonEncode(_outbox(initial)) == jsonEncode(savedEvents) &&
          _cameraMatches(
            initial['camera'],
            nativeObject(baseline['persistedSettings'])['viewport'],
          ),
      'Cold native recovery changed saved settings/camera/outbox.',
    );
    await client.tapKey('online-toggle');
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    await client.waitForSnapshot(
      'online setting and automatic coordinator complete',
      (snapshot) => _idle(snapshot) && _model(snapshot)['online'] == true,
    );
    // Manual Sync is an actual UI action as well, including unavailable client.
    await client.tapKey('map-sync');
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    final result = await client.waitForSnapshot(
      'manual Sync completes without changing durable results',
      _idle,
    );
    _syncedState(client, result, savedEvents);
    return result;
  }
  nativeRequire(
    model['online'] == true,
    'Third process lost committed Online.',
  );
  _syncedState(client, initial, savedEvents);
  return initial;
}

void _syncedState(
  NativeWorkbenchDriver client,
  Map<String, dynamic> snapshot,
  List<Map<String, dynamic>> savedEvents,
) {
  final pending = _outbox(snapshot);
  final demo = client.options.configuration == 'demo';
  nativeRequire(
    demo ? pending.isEmpty : jsonEncode(pending) == jsonEncode(savedEvents),
    demo
        ? 'Controlled matching ACK did not persistently drain the demo outbox.'
        : 'Unavailable local-client removed or changed unacknowledged events.',
  );
  for (final event in savedEvents) {
    final stop = nativeObjects(
      snapshot['persistedStops'],
    ).singleWhere((stop) => stop['id'] == event['stopId']);
    nativeRequire(
      stop['operationId'] == event['operationId'] &&
          (demo
              ? stop['acknowledgedAt'] != null
              : stop['acknowledgedAt'] == null),
      'Durable acknowledgement projection does not match transport facts.',
    );
  }
  final current = _currentEvents(snapshot, client.options);
  nativeRequire(
    !current.any((event) => event['stage'] == 'submit_committed'),
    'A recovery/confirmation observation duplicated a delivery mutation.',
  );
  if (!demo) {
    nativeRequire(
      current.any((event) => event['stage'] == 'sync_failed'),
      'Actual unavailable coordinator outcome was not observed.',
    );
  }
}
