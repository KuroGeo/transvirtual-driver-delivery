import 'dart:convert';
import 'dart:io';

import 'support/native_driver_support.dart';

/// Independent F1 navigation UI/SQLite recovery evidence. The private entry's
/// Maps gateway is explicitly a fixture. This driver does not sign OS Maps,
/// GPS, real roads, physical devices, or production acceptance.
Future<void> main(List<String> arguments) async {
  final options = NativeDriverOptions.parse(arguments);
  NativeWorkbenchDriver? client;
  try {
    client = await NativeWorkbenchDriver.connect(options);
    final checks = <Map<String, Object?>>[];
    final snapshot = await _run(
      client,
      checks,
    ).timeout(const Duration(seconds: 150));
    await client.capture(snapshot);
    await client.writeJson('result.json', {
      'schema': 1,
      'status': 'passed',
      'scope': 'f1-native-navigation-fixture',
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
      'f1Checks': checks,
      'textEntry': 'flutter-driver-emulated',
      'osKeyboard': 'not_run',
      'maps': 'controlled-fixture; real-external-maps not_run',
      'gps': 'controlled-fixture; real-gps not_run',
      'roads': 'unavailable; real-road not_run',
      'hardwareBack': 'not_run; actual typed UI Return exercised',
    });
  } catch (error, stack) {
    if (client != null) {
      await client.writeJson('result.json', {
        'schema': 1,
        'status': 'failed',
        'scope': 'f1-native-navigation-fixture',
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
  if (exitCode != 0) exit(exitCode);
}

Map<String, dynamic> _model(Map<String, dynamic> snapshot) =>
    nativeObject(snapshot['model']);

bool _idle(Map<String, dynamic> snapshot) {
  if (snapshot['model'] == null) return false;
  final model = _model(snapshot);
  return model['initialized'] == true &&
      model['isLoading'] == false &&
      model['isSaving'] == false &&
      model['isSyncing'] == false &&
      model['isChangingOnline'] == false;
}

bool _hit(Map<String, dynamic> snapshot, String key) {
  final rows = nativeObject(snapshot['bounds'])[key];
  return rows is List &&
      rows.length == 1 &&
      nativeObject(rows.single)['centerHit'] == true;
}

void _sameDurable(Map<String, dynamic> before, Map<String, dynamic> after) {
  for (final key in ['stops', 'persistedStops', 'outbox']) {
    nativeRequire(
      jsonEncode(before[key]) == jsonEncode(after[key]),
      'F1 navigation changed $key; delivery results and outbox must be immutable.',
    );
  }
}

void _check(
  List<Map<String, Object?>> checks,
  String id,
  List<String> actions, {
  String before = 'initial-snapshot.json',
  String after = 'snapshot.json',
  String? sourceReturned,
  String? preview,
  String? handoff,
}) => checks.add({
  'id': id,
  'status': 'passed',
  'actions': actions,
  'before': before,
  'after': after,
  'sourceReturned': sourceReturned,
  'preview': preview,
  'handoff': handoff,
});

Future<Map<String, dynamic>> _run(
  NativeWorkbenchDriver client,
  List<Map<String, Object?>> checks,
) async {
  var initial = await client.waitForSnapshot(
    'native formal30 database and task tile source ready',
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
    'Native candidate configuration has unexpected transport provenance.',
  );
  await client.writeJson('bootstrap-snapshot.json', initial);
  if (client.options.phase == 'saved') {
    initial = await _prepareOfflineQueue(client, initial);
  } else {
    final baseline = nativeObject(
      jsonDecode(
        await File(client.options.required('baseline')).readAsString(),
      ),
    );
    nativeRequire(
      baseline['candidate'] == client.options.candidate &&
          baseline['configuration'] == client.options.configuration &&
          baseline['processId'] != client.options.processId &&
          baseline['session'] != client.options.session &&
          baseline['databasePath'] == initial['databasePath'],
      'Cold recovery must be a different OS PID/session of the same native data.',
    );
    _sameDurable(baseline, initial);
    final query = nativeObject(_model(initial)['query']);
    nativeRequire(
      _model(initial)['panel'] == 'map' &&
          _model(initial)['selected'] == null &&
          _model(initial)['online'] == false &&
          query['search'] == '' &&
          query['status'] == null &&
          query['waitingOnly'] == false,
      'Cold recovery lost offline setting or persisted transient detail/query.',
    );
    final events = nativeObjects(
      nativeObject(initial['journal'])['events'],
    ).where((event) => event['session'] == client.options.session).toList();
    nativeRequire(
      events.where((event) => event['stage'] == 'database_reopened').length ==
              1 &&
          !events.any((event) => event['stage'] == 'import_committed'),
      'Actual OS recovery must reopen the existing database without reimport.',
    );
    if (client.options.phase == 'recovered') {
      _check(checks, 'F1.cold-recovery', ['snapshot']);
    }
  }
  await client.writeJson('initial-snapshot.json', initial);
  nativeRequire(
    nativeObjects(initial['outbox']).length == 2 &&
        _model(initial)['online'] == false,
    'Navigation evidence must protect two existing offline outbox events.',
  );

  final stop = nativeObjects(
    initial['stops'],
  ).firstWhere((value) => value['status'] == 'pending');
  if (client.options.phase == 'saved') {
    await client.tapKey('browse-stops');
    await _openListStop(client, stop);
    final before = await client.snapshot();
    final after = await _navigateAndReturn(client, 'list');
    nativeRequire(
      jsonEncode(_model(before)['query']) ==
              jsonEncode(_model(after)['query']) &&
          jsonEncode(_model(before)['listSession']) ==
              jsonEncode(_model(after)['listSession']),
      'List query, focus or scroll session changed during F1 navigation.',
    );
    _check(
      checks,
      'F1.route-preview',
      [
        'tap:detail-navigate',
        'tap:navigation-choose-map',
        'tap:navigation-app-browserMap',
      ],
      before: 'list-before.json',
      after: 'list-preview.json',
    );
    _check(
      checks,
      'F1.return-list',
      ['tap:navigation-return-detail', 'tap:detail-close'],
      before: 'list-before.json',
      after: 'list-original-detail.json',
      sourceReturned: 'list-returned.json',
      preview: 'list-preview.json',
      handoff: 'list-handoff.json',
    );
    _check(
      checks,
      'F1.return-query',
      [
        'emulated-text:stop-search',
        'tap:stop-${stop['reference']}',
        'tap:detail-close',
      ],
      before: 'list-before.json',
      after: 'list-original-detail.json',
      sourceReturned: 'list-returned.json',
      preview: 'list-preview.json',
      handoff: 'list-handoff.json',
    );
    await _clearListAndClose(client);
  } else if (client.options.phase == 'recovered') {
    final map = await client.snapshot();
    final visible = nativeObjects(
      map['stops'],
    ).where((value) => _hit(map, 'map-stop-${value['reference']}'));
    nativeRequire(visible.isNotEmpty, 'No actually hittable formal map stop.');
    final marker = 'map-stop-${visible.first['reference']}';
    await client.tapKey(marker);
    await client.waitForSnapshot(
      'actual map-origin detail',
      (snapshot) => _model(snapshot)['selectedOrigin'] == 'map',
    );
    await _navigateAndReturn(client, 'map');
    _check(
      checks,
      'F1.return-map',
      [
        'tap:$marker',
        'tap:detail-navigate',
        'tap:navigation-return-detail',
        'tap:detail-close',
      ],
      before: 'map-before.json',
      after: 'map-original-detail.json',
      sourceReturned: 'map-returned.json',
      preview: 'map-preview.json',
      handoff: 'map-handoff.json',
    );
    // The existing nearest entry focuses and persists the delivery map. Keep
    // this actual UI action in recovery; confirmed remains a strictly readonly
    // third OS process against the entire recovered SQLite state.
    await client.revealKey('nearest-stop');
    await client.tapKey('nearest-stop');
    await client.waitForSnapshot(
      'actual nearest-origin detail',
      (snapshot) => _model(snapshot)['selectedOrigin'] == 'nearest',
    );
    await _navigateAndReturn(client, 'nearest');
    _check(
      checks,
      'F1.return-nearest',
      [
        'tap:nearest-stop',
        'tap:detail-navigate',
        'tap:navigation-return-detail',
        'tap:detail-close',
      ],
      before: 'nearest-before.json',
      after: 'nearest-original-detail.json',
      sourceReturned: 'nearest-returned.json',
      preview: 'nearest-preview.json',
      handoff: 'nearest-handoff.json',
    );
  }
  final finalSnapshot = await client.waitForSnapshot(
    'original task map returned with idle immutable queue',
    (snapshot) =>
        _idle(snapshot) &&
        _model(snapshot)['panel'] == 'map' &&
        !nativeObject(snapshot['bounds']).containsKey('navigation-preview'),
  );
  _sameDurable(initial, finalSnapshot);
  if (client.options.phase == 'confirmed') {
    _check(checks, 'F1.outbox-invariance', ['snapshot']);
  }
  return finalSnapshot;
}

Future<Map<String, dynamic>> _prepareOfflineQueue(
  NativeWorkbenchDriver client,
  Map<String, dynamic> bootstrap,
) async {
  nativeRequire(
    nativeObjects(bootstrap['outbox']).isEmpty,
    'Setup requires a fresh task sandbox; never overwrite user data.',
  );
  final pending = nativeObjects(
    bootstrap['stops'],
  ).where((stop) => stop['status'] == 'pending').toList();
  await client.tapKey('online-toggle');
  await client.waitForSnapshot(
    'offline setting durably committed',
    (snapshot) =>
        _idle(snapshot) &&
        _model(snapshot)['online'] == false &&
        nativeObject(snapshot['persistedSettings'])['online'] == false,
  );
  await client.tapKey('browse-stops');
  await _openListStop(client, pending[0]);
  await client.revealKey('detail-complete');
  await client.tapKey('detail-complete');
  await client.waitForSnapshot(
    'first actual offline manual completion saved',
    (snapshot) =>
        _idle(snapshot) &&
        nativeObject(_model(snapshot)['selected'])['status'] == 'completed' &&
        nativeObjects(snapshot['outbox']).length == 1,
  );
  await client.revealKey('detail-return');
  await client.tapKey('detail-return');
  await _openListStop(client, pending[1]);
  await client.revealKey('detail-fail');
  await client.tapKey('detail-fail');
  await client.revealKey('failure-reason-recipient-unavailable');
  await client.tapKey('failure-reason-recipient-unavailable');
  await client.enterText('failure-note', 'F1 independent offline queue guard');
  await client.revealKey('failure-save', alignment: 1);
  await client.tapKey('failure-save');
  await client.waitForSnapshot(
    'second actual offline failure and immutable operation saved',
    (snapshot) =>
        _idle(snapshot) &&
        nativeObject(_model(snapshot)['selected'])['status'] == 'failed' &&
        nativeObjects(snapshot['outbox']).length == 2 &&
        !nativeObject(snapshot['bounds']).containsKey('failure-sheet'),
  );
  await client.revealKey('detail-return');
  await client.tapKey('detail-return');
  await _clearListAndClose(client);
  return client.waitForSnapshot(
    'native navigation baseline offline on map with two existing operations',
    (snapshot) =>
        _idle(snapshot) &&
        _model(snapshot)['panel'] == 'map' &&
        nativeObjects(snapshot['outbox']).length == 2,
  );
}

Future<void> _openListStop(
  NativeWorkbenchDriver client,
  Map<String, dynamic> stop,
) async {
  await _showListSearch(client);
  final reference = stop['reference'] as String;
  await client.enterText('stop-search', reference);
  await client.waitForSnapshot(
    'actual list query $reference',
    (snapshot) =>
        _model(snapshot)['panel'] == 'list' &&
        nativeObject(_model(snapshot)['query'])['search'] == reference &&
        nativeObject(snapshot['result'])['matchedCount'] == 1,
  );
  await client.revealKey('stop-$reference');
  await client.tapKey('stop-$reference');
  await client.waitForSnapshot(
    'actual list detail $reference',
    (snapshot) =>
        _model(snapshot)['panel'] == 'detail' &&
        _model(snapshot)['selectedOrigin'] == 'list' &&
        nativeObject(_model(snapshot)['selected'])['id'] == stop['id'],
  );
}

Future<void> _showListSearch(NativeWorkbenchDriver client) async {
  var snapshot = await client.snapshot();
  if (!nativeObject(snapshot['bounds']).containsKey('stop-search')) {
    await client.tapKey('list-query-controls');
  }
  for (var attempt = 0; attempt < 8; attempt++) {
    snapshot = await client.snapshot();
    if (_hit(snapshot, 'stop-search')) return;
    await client.scrollKey('stop-list-scroll', 350);
  }
  throw StateError('Actual list scroll did not expose the search control.');
}

Future<void> _clearListAndClose(NativeWorkbenchDriver client) async {
  await _showListSearch(client);
  await client.enterText('stop-search', '');
  await client.tapKey('close-list');
  await client.waitForSnapshot(
    'list closed to map with cleared query',
    (snapshot) =>
        _model(snapshot)['panel'] == 'map' &&
        nativeObject(_model(snapshot)['query'])['search'] == '',
  );
}

Future<Map<String, dynamic>> _navigateAndReturn(
  NativeWorkbenchDriver client,
  String origin,
) async {
  final before = await client.snapshot();
  final selected = nativeObject(_model(before)['selected']);
  final camera = jsonEncode(before['camera']);
  await client.writeJson('$origin-before.json', before);
  await client.revealKey('detail-navigate');
  await client.tapKey('detail-navigate');
  final preview = await client.waitForSnapshot(
    'actual route preview with truthful unavailable roads',
    (snapshot) =>
        nativeObject(snapshot['bounds']).containsKey('navigation-preview') &&
        snapshot['navigation'] != null &&
        nativeObject(snapshot['navigation'])['previewStatus'] == 'unavailable',
  );
  nativeRequire(
    nativeObject(preview['navigation'])['targetStopId'] == selected['id'],
    'Route preview changed the selected destination.',
  );
  _sameDurable(before, preview);
  await client.writeJson('$origin-preview.json', preview);
  await client.captureNamed('$origin-navigation-preview', preview);
  await client.revealKey('navigation-choose-map');
  await client.tapKey('navigation-choose-map');
  await client.revealKey('navigation-app-appleMaps');
  await client.tapKey('navigation-app-appleMaps');
  final missingMap = await client.waitForSnapshot(
    'fixture Maps unavailable retains explicit fallback choices',
    (snapshot) =>
        snapshot['navigation'] != null &&
        nativeObject(snapshot['navigation'])['handoffStatus'] ==
            'unavailable' &&
        nativeObject(
          snapshot['bounds'],
        ).containsKey('navigation-app-googleMaps'),
  );
  _sameDurable(before, missingMap);
  await client.writeJson('$origin-map-unavailable.json', missingMap);
  await client.revealKey('navigation-app-googleMaps');
  await client.tapKey('navigation-app-googleMaps');
  final failedLaunch = await client.waitForSnapshot(
    'fixture Maps launch failure retains browser choice',
    (snapshot) =>
        snapshot['navigation'] != null &&
        nativeObject(snapshot['navigation'])['handoffStatus'] ==
            'launchFailed' &&
        nativeObject(
          snapshot['bounds'],
        ).containsKey('navigation-app-browserMap'),
  );
  _sameDurable(before, failedLaunch);
  await client.writeJson('$origin-map-launch-failed.json', failedLaunch);
  await client.revealKey('navigation-app-browserMap');
  await client.tapKey('navigation-app-browserMap');
  final handoff = await client.waitForSnapshot(
    'explicitly fixture map handoff requested, never arrived',
    (snapshot) =>
        snapshot['navigation'] != null &&
        nativeObject(snapshot['navigation'])['handoffStatus'] ==
            'handoffRequested',
  );
  nativeRequire(
    nativeObject(handoff['navigation'])['gatewaySource'] ==
        'controlled-navigation-fixture',
    'Native handoff must label controlled gateway provenance.',
  );
  _sameDurable(before, handoff);
  await client.writeJson('$origin-handoff.json', handoff);
  await client.revealKey('navigation-return-detail');
  await client.tapKey('navigation-return-detail');
  final originalDetail = await client.waitForSnapshot(
    'actual return to original $origin detail',
    (snapshot) =>
        !nativeObject(snapshot['bounds']).containsKey('navigation-preview') &&
        _model(snapshot)['panel'] == 'detail' &&
        _model(snapshot)['selectedOrigin'] == origin &&
        nativeObject(_model(snapshot)['selected'])['id'] == selected['id'],
  );
  _sameDurable(before, originalDetail);
  await client.writeJson('$origin-original-detail.json', originalDetail);
  await client.revealKey('detail-close');
  await client.tapKey('detail-close');
  final returned = await client.waitForSnapshot(
    'actual original $origin workspace restored',
    (snapshot) =>
        _model(snapshot)['panel'] == (origin == 'list' ? 'list' : 'map'),
  );
  nativeRequire(
    jsonEncode(returned['camera']) == camera,
    'F1 navigation changed the retained delivery map viewport.',
  );
  _sameDurable(before, returned);
  await client.writeJson('$origin-returned.json', returned);
  return returned;
}
