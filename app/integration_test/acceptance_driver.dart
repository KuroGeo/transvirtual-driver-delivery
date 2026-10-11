import 'dart:async';
import 'dart:io';

import 'support/native_acceptance_support.dart';
import 'support/native_driver_support.dart';

/// Independent E08 functional acceptance. All business mutations below are
/// actual UI gestures/text entry; requestData only samples the readonly bridge.
Future<void> main(List<String> arguments) async {
  final options = NativeDriverOptions.parse(arguments);
  options.required('scenario');
  NativeWorkbenchDriver? client;
  NativeAcceptanceRecorder? recorder;
  try {
    client = await NativeWorkbenchDriver.connect(options);
    recorder = NativeAcceptanceRecorder(client);
    final finalSnapshot = await _run(
      recorder,
    ).timeout(const Duration(seconds: 300));
    recorder.last = finalSnapshot;
    await client.capture(finalSnapshot);
    await recorder.flush();
    await client.writeJson(
      'result.json',
      _result(client, finalSnapshot, 'passed'),
    );
  } catch (error, stack) {
    if (client != null) {
      await recorder?.flush(status: 'failed');
      await client.writeJson('result.json', {
        ..._result(client, recorder?.last, 'failed'),
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

Map<String, Object?> _result(
  NativeWorkbenchDriver client,
  Map<String, dynamic>? snapshot,
  String status,
) => {
  'schema': 1,
  'revision': acceptanceRevision,
  'scope': acceptanceScope,
  'status': status,
  'scenario': client.options.required('scenario'),
  'phase': client.options.phase,
  'processId': client.options.processId,
  'vmProcessId': client.vmProcessId,
  'session': client.options.session,
  'candidate': client.options.candidate,
  'configuration': client.options.configuration,
  'transport': snapshot?['transport'],
  'databasePath': snapshot?['databasePath'],
  'launchConfigPath': snapshot?['launchConfigPath'],
  'launchConfigByteLength': snapshot?['launchConfigByteLength'],
  'launchConfigSchema': snapshot?['launchConfigSchema'],
  'textEntry':
      'flutter-driver-emulated; OS keyboard claimed only by actual inset/PNG case',
  'hardwareBack':
      'not_applicable on iOS; actual typed UI/modal returns separately checked',
};

Future<Map<String, dynamic>> _run(NativeAcceptanceRecorder recorder) async {
  final client = recorder.client;
  if (recorder.scenario == 'N6' &&
      client.options.phase == 'saved' &&
      client.options.values['migration-fault'] == 'true') {
    await _migrationRollback(recorder);
  }
  final initial = await acceptanceReady(
    client,
    tiles:
        client.options.phase != 'saved' ||
        client.options.values['initial-tiles'] != '503',
  );
  nativeRequire(
    initial['transport'] ==
        (client.options.configuration == 'demo'
            ? 'controlled-http-simulated'
            : 'unavailable-local-client'),
    'Actual transport differs from accepted mode.',
  );
  await recorder.evidence('initial-snapshot.json', initial);
  if (client.options.phase != 'saved') {
    return _laterPhase(recorder, initial);
  }
  switch (recorder.scenario) {
    case 'N1':
      await _n1(recorder);
    case 'N2':
      await _n2(recorder);
    case 'N3':
      await _n3(recorder);
    case 'N4':
      await _n4(recorder);
    case 'N5':
      await _n5(recorder);
    case 'N6':
      await _n6(recorder);
    case 'N7':
      await _n7(recorder);
  }
  await acceptanceMap(client);
  await acceptanceOnline(client, false);
  // A real changed viewport and deliberate transient UI state are left for the
  // host's terminate/relaunch phases. Business data is never reseeded here.
  await client.tapKey('zoom-in');
  await client.waitForSnapshot(
    'final viewport persisted',
    (s) =>
        acceptanceIdle(s) &&
        acceptanceCameraMatches(
          s['camera'],
          nativeObject(s['persistedSettings'])['viewport'],
        ),
  );
  return client.snapshot();
}

void _finishedFailure(AcceptanceCase c) {
  final error = nativeObject(acceptanceModel(c.after)['syncProgress'])['error'];
  nativeRequire(
    error is String && error.isNotEmpty,
    'Finished failed run must retain its concrete error.',
  );
  final start = DateTime.parse(c.before['observedAt'] as String);
  final end = DateTime.parse(c.after['observedAt'] as String);
  final failures = acceptanceEvents(c.after, c.recorder.client, 'sync_failed')
      .where((event) {
        final observed = DateTime.parse(event['observedAt'] as String);
        return !observed.isBefore(start) && !observed.isAfter(end);
      });
  nativeRequire(
    failures.isNotEmpty,
    'Current check window must contain actual sync_failed, not an old failure.',
  );
}

Future<void> _terminal(
  AcceptanceCase c,
  String reference,
  String status,
) async {
  final selected = nativeObject(acceptanceModel(c.after)['selected']);
  nativeRequire(
    selected['reference'] == reference,
    'Selected terminal identity changed.',
  );
  await c.expect('/model/selected/status', 'eq', status);
  await c.expect('/model/selectedOrigin', 'eq', 'list');
  await c.expect('/bounds/detail-complete', 'absent', null);
  await c.expect('/bounds/detail-fail', 'absent', null);
  await c.expect('/model/panel', 'eq', 'detail');
}

Future<void> _n1(NativeAcceptanceRecorder r) async {
  final d = r.client;
  await r.check('N1.first-import', (_) async {}, (c) async {
    await c.expect('/stops', 'length', 30);
    await c.expect('/outbox', 'length', 0);
    await c.expect('/model/pendingCount', 'eq', 24);
    nativeRequire(
      acceptanceEvents(c.after, d, 'import_committed').length == 1,
      'Native import must commit exactly once.',
    );
    final index = nativeObjects(nativeObject(c.after['journal'])['events'])
        .indexWhere(
          (e) =>
              e['session'] == d.options.session &&
              e['stage'] == 'import_committed',
        );
    await c.expect('/journal/events/$index/stage', 'eq', 'import_committed');
  });
  await r.check(
    'N1.offline-two-results',
    (c) async {
      await acceptanceOnline(d, false);
      await acceptanceComplete(d, 'TV-300002');
      await c.sample('complete', await d.snapshot());
      await acceptanceReturn(d);
      await acceptanceFailureSave(
        d,
        'TV-300004',
        'other',
        '  E08 native Other explanation  ',
      );
    },
    (c) async {
      await _terminal(c, 'TV-300004', 'failed');
      await c.expect('/model/online', 'eq', false);
      await c.expect('/outbox', 'length', 2);
      await c.expect('/outbox/0/status', 'eq', 'completed');
      await c.expect('/outbox/1/status', 'eq', 'failed');
      await c.expect('/outbox/1/reason', 'eq', 'E08 native Other explanation');
      await c.expect('/outbox/1/note', 'eq', null);
      for (final event in acceptanceOutbox(c.after)) {
        final stop = acceptanceStop(
          c.after,
          nativeObjects(
                c.after['stops'],
              ).singleWhere((s) => s['id'] == event['stopId'])['reference']
              as String,
          persisted: true,
        );
        nativeRequire(
          [
                'operationId',
                'status',
                'reason',
                'note',
                'recordedAt',
              ].every((key) => stop[key] == event[key]) &&
              event['recordedAt'] is String &&
              DateTime.parse(event['recordedAt'] as String).isUtc &&
              stop['acknowledgedAt'] == null,
          'Local result and immutable UTC outbox must commit together.',
        );
      }
      await c.expect(
        '/model/selected/operationId',
        'eq',
        null,
        rightArtifact: c.afterPath,
        rightPointer: '/outbox/1/operationId',
      );
      await c.expect(
        '/model/selected/recordedAt',
        'eq',
        null,
        rightArtifact: c.afterPath,
        rightPointer: '/outbox/1/recordedAt',
      );
    },
  );
}

Future<Map<String, dynamic>> _laterPhase(
  NativeAcceptanceRecorder r,
  Map<String, dynamic> initial,
) async {
  final d = r.client;
  final baseline = await acceptanceBaseline(d);
  final recovered = d.options.phase == 'recovered';
  if (r.scenario == 'N1' && recovered) {
    await r.check('N1.cold-preservation', (_) async {}, (c) async {
      await c.expect('/databasePath', 'eq', baseline['databasePath']);
      await c.expect(
        '/outbox',
        'eq',
        null,
        rightArtifact: 'saved/snapshot.json',
        rightPointer: '/outbox',
      );
      await c.expect(
        '/persistedStops',
        'eq',
        null,
        rightArtifact: 'saved/snapshot.json',
        rightPointer: '/persistedStops',
      );
      await c.expect('/model/online', 'eq', false);
      await c.expect('/model/panel', 'eq', 'map');
      await c.expect('/model/selected', 'eq', null);
      await c.expect('/model/query/search', 'eq', '');
      await c.expect('/model/query/status', 'eq', null);
      await c.expect('/model/query/waitingOnly', 'eq', false);
      nativeRequire(
        acceptanceCameraMatches(
              c.after['camera'],
              nativeObject(baseline['persistedSettings'])['viewport'],
            ) &&
            acceptanceEvents(c.after, d, 'database_reopened').length == 1 &&
            acceptanceEvents(c.after, d, 'import_committed').isEmpty,
        'Actual new process must reuse database/settings without reimport.',
      );
    });
  }
  if (r.scenario == 'N5' && recovered) {
    final invalid =
        d.options.values['cold-fixture'] != null &&
        d.options.values['cold-fixture'] != 'none';
    await r.check(
      invalid ? 'N5.invalid-viewport-fallback' : 'N5.valid-viewport-cold',
      (_) async {},
      (c) async {
        await c.expect(
          '/outbox',
          'eq',
          null,
          rightArtifact: 'saved/snapshot.json',
          rightPointer: '/outbox',
        );
        await c.expect(
          '/persistedStops',
          'eq',
          null,
          rightArtifact: 'saved/snapshot.json',
          rightPointer: '/persistedStops',
        );
        await c.expect('/model/online', 'eq', false);
        if (invalid) {
          await c.expect('/persistedSettings/viewport', 'eq', null);
          await c.expect('/camera/latitude', 'eq', -33.884);
          await c.expect('/camera/longitude', 'eq', 151.117);
          await c.expect('/camera/zoom', 'eq', 11.0);
        } else {
          nativeRequire(
            acceptanceCameraMatches(
              c.after['camera'],
              nativeObject(baseline['persistedSettings'])['viewport'],
            ),
            'Valid saved camera was not restored.',
          );
          for (final key in ['latitude', 'longitude', 'zoom']) {
            await c.expect(
              '/camera/$key',
              'eq',
              null,
              rightArtifact: 'saved/snapshot.json',
              rightPointer: '/persistedSettings/viewport/$key',
            );
          }
        }
      },
    );
  }
  if (recovered) {
    if (r.scenario == 'N1' && d.options.configuration == 'demo') {
      await r.check(
        'N1.serial-confirmation',
        (_) async {
          await acceptanceOnline(d, true);
          await d.waitForSnapshot(
            'two serial matching acknowledgements durably drained',
            (s) => acceptanceIdle(s) && acceptanceOutbox(s).isEmpty,
          );
        },
        (c) async {
          await c.expect('/outbox', 'length', 0);
          await c.expect('/model/syncProgress/confirmedCount', 'eq', 2);
          nativeRequire(
            acceptanceEvents(c.after, d, 'ack_committed').length == 2,
            'Exactly two durable ACK commits required.',
          );
          for (final event in acceptanceOutbox(baseline)) {
            nativeRequire(
              nativeObjects(c.after['persistedStops']).singleWhere(
                    (s) => s['id'] == event['stopId'],
                  )['acknowledgedAt'] !=
                  null,
              'ACK must persist before event removal.',
            );
          }
          await c.evidence('fixture-state', await d.fixture('state'));
        },
      );
    } else {
      await acceptanceOnline(d, true);
      await d.tapKey('map-sync');
      await acceptanceWaitIdle(d);
      if (r.scenario == 'N1') {
        r.notApplicable(
          'N1.serial-confirmation',
          'Default local client has no service; actual queue retention is separately observed, never uploaded.',
        );
      }
    }
  } else if (r.scenario == 'N1') {
    await r.check(
      'N1.no-resend',
      (_) async {
        await d.tapKey('map-sync');
        await acceptanceWaitIdle(d);
      },
      (c) async {
        final demo = d.options.configuration == 'demo';
        await c.expect('/outbox', 'length', demo ? 0 : 2);
        nativeRequire(
          acceptanceEvents(c.after, d, 'submit_committed').isEmpty &&
              acceptanceEvents(c.after, d, 'import_committed').isEmpty,
          'Third native process may not resubmit or reimport.',
        );
        final fixture = await d.fixture('state');
        final ref = await c.evidence('fixture-state', fixture);
        final requests = nativeObjects(
          fixture['requests'],
        ).where((row) => row['kind'] == 'sync').toList();
        nativeRequire(
          demo ? requests.length == 2 : requests.isEmpty,
          'Third-process manual/startup sync resent a confirmed event or unavailable client sent HTTP.',
        );
        await c.expect('/state/sync', 'eq', 'match', artifact: ref);
      },
    );
  }
  // Every independent scenario still uses the host's genuine three-process
  // lifecycle, and the final phase's SQL/OS capture remains mandatory.
  nativeRequire(
    recovered || acceptanceEvents(initial, d, 'import_committed').isEmpty,
    'Cold process unexpectedly imported source data.',
  );
  return d.snapshot();
}

Future<void> _n2(NativeAcceptanceRecorder r) async {
  final d = r.client;
  nativeRequire(
    d.options.configuration == 'local-client',
    'N2 requires the default unavailable local client.',
  );
  await acceptanceOnline(d, false);
  await r.check(
    'N2.failure-options',
    (c) async {
      final reasons = {
        'recipient-unavailable': 'Recipient unavailable',
        'business-closed': 'Business closed',
        'address-not-found': 'Address not found',
      };
      final references = ['TV-300002', 'TV-300004', 'TV-300005'];
      var index = 0;
      for (final reason in reasons.entries) {
        await acceptanceFailureSave(
          d,
          references[index++],
          reason.key,
          '  preset note  ',
        );
        final sample = await d.snapshot();
        await c.sample(reason.key, sample);
        nativeRequire(
          nativeObject(acceptanceModel(sample)['selected'])['reason'] ==
                  reason.value &&
              nativeObject(acceptanceModel(sample)['selected'])['note'] ==
                  'preset note',
          'Preset reason/note failed actual native save.',
        );
        if (index < 3) await acceptanceReturn(d);
      }
    },
    (c) async {
      await c.expect('/outbox', 'length', 3);
      await _terminal(c, 'TV-300005', 'failed');
    },
  );
  await acceptanceReturn(d);
  await r.check(
    'N2.other-validation',
    (c) async {
      await acceptanceFailureOpen(d, 'TV-300006');
      await d.revealKey('failure-save', alignment: 1);
      await d.tapKey('failure-save');
      await c.evidence('no-reason-ui', {
        'text': await d.textLabel('Choose a reason to continue.'),
      });
      await c.sample('no-reason', await d.snapshot());
      await d.revealKey('failure-reason-other');
      await d.tapKey('failure-reason-other');
      await d.enterText('failure-note', '   ');
      await d.revealKey('failure-save', alignment: 1);
      await d.tapKey('failure-save');
      final blank = await d.snapshot();
      final ref = await c.sample('blank-other', blank);
      await c.expect('/outbox', 'length', 3, artifact: ref);
      await c.evidence('blank-ui', {
        'text': await d.textLabel('Enter a reason to continue.'),
      });
      await d.enterText('failure-note', '  native Other explanation  ');
      await d.revealKey('failure-save', alignment: 1);
      await d.tapKey('failure-save');
      await d.waitForSnapshot(
        'Other actual saved explanation',
        (s) =>
            acceptanceIdle(s) &&
            !nativeObject(s['bounds']).containsKey('failure-sheet'),
      );
    },
    (c) async {
      await c.expect('/outbox', 'length', 4);
      await c.expect(
        '/model/selected/reason',
        'eq',
        'native Other explanation',
      );
      await c.expect('/model/selected/note', 'eq', null);
      await _terminal(c, 'TV-300006', 'failed');
    },
  );
  await acceptanceReturn(d);
  await r.check(
    'N2.imported-unknown',
    (c) async {
      await acceptanceOpenListStop(d, 'TV-300003');
      await d.revealKey('detail-return', alignment: 1);
      final ref = await c.evidence('source-reason-ui', {
        'text': await d.textLabel('No reason provided in the source record.'),
      });
      await c.expect(
        '/text',
        'eq',
        'No reason provided in the source record.',
        artifact: ref,
      );
    },
    (c) async {
      await c.expect('/model/selected/reason', 'eq', null);
      await c.expect('/model/selected/operationId', 'eq', null);
      await c.expect('/outbox', 'length', 4);
      await _terminal(c, 'TV-300003', 'failed');
    },
  );
  await acceptanceReturn(d);
  await r.check(
    'N2.submit-rollback-retry',
    (c) async {
      await d.fixture('control', body: {'sqlFault': 'submit'});
      await acceptanceFailureOpen(d, 'TV-300007');
      await d.revealKey('failure-reason-business-closed');
      await d.tapKey('failure-reason-business-closed');
      await d.enterText('failure-note', 'retained rollback draft');
      await d.revealKey('failure-save', alignment: 1);
      await d.tapKey('failure-save');
      final failed = await d.waitForSnapshot(
        'transactional native submit rollback preserves open draft',
        (s) =>
            acceptanceIdle(s) &&
            acceptanceModel(s)['saveError'] != null &&
            nativeObject(s['bounds']).containsKey('failure-sheet'),
      );
      final ref = await c.sample('rollback', failed);
      final rollbackCapture = await d.captureNamed(
        '${c.slug}-rollback',
        failed,
      );
      await c.evidence('rollback-capture', rollbackCapture);
      c.metadata['rollback_capture'] = {
        'png': r.relative('${c.slug}-rollback.png'),
        'sqlite': r.relative('${c.slug}-rollback.sqlite'),
        'projection': r.relative('${c.slug}-rollback.sqlite.json'),
        'journal': r.relative('${c.slug}-rollback.journal.jsonl'),
      };
      await c.expect('/outbox', 'length', 4, artifact: ref);
      await c.expect('/model/selected/status', 'eq', 'pending', artifact: ref);
      final ui = await c.evidence('draft-ui', {
        'note': await d.textKey('failure-note'),
        'reasonSemanticsId': await d.semanticsKey(
          'failure-reason-business-closed',
        ),
      });
      await c.expect('/note', 'eq', 'retained rollback draft', artifact: ui);
      await d.fixture('control', body: {'sqlFault': 'none'});
      await d.revealKey('failure-save', alignment: 1);
      await d.tapKey('failure-save');
      await d.waitForSnapshot(
        'same draft Retry commits exactly once',
        (s) =>
            acceptanceIdle(s) &&
            acceptanceOutbox(s).length == 5 &&
            !nativeObject(s['bounds']).containsKey('failure-sheet'),
      );
    },
    (c) async {
      await _terminal(c, 'TV-300007', 'failed');
      await c.expect('/outbox', 'length', 5);
      await c.expect('/model/selected/reason', 'eq', 'Business closed');
      await c.expect('/model/selected/note', 'eq', 'retained rollback draft');
    },
  );
  await acceptanceReturn(d);
  await r.check(
    'N2.terminal-double-tap',
    (c) async {
      await acceptanceOpenListStop(d, 'TV-300009');
      await d.revealKey('detail-complete');
      final actual = await d.doubleComplete();
      final proof = await c.evidence('ui-gesture', actual);
      c.metadata['gesture'] = proof;
      await c.expect('/completedTaps', 'eq', 2, artifact: proof);
      await c.expect('/key', 'eq', 'detail-complete', artifact: proof);
      await c.expect('/elapsedMicros', 'lte', 1000000, artifact: proof);
      await d.waitForSnapshot(
        'two rapid pointer gestures create one durable result',
        (s) =>
            acceptanceIdle(s) &&
            acceptanceOutbox(s).length == 6 &&
            nativeObject(acceptanceModel(s)['selected'])['status'] ==
                'completed',
      );
    },
    (c) async {
      await _terminal(c, 'TV-300009', 'completed');
      await c.expect('/outbox', 'length', 6);
      nativeRequire(
        acceptanceOutbox(c.after)
                .where(
                  (e) =>
                      e['stopId'] == acceptanceStop(c.after, 'TV-300009')['id'],
                )
                .length ==
            1,
        'Rapid terminal gestures duplicated the outbox.',
      );
    },
  );
  await acceptanceMap(d);
  await r.check(
    'N2.unavailable',
    (c) async {
      await acceptanceOnline(d, true);
      await d.tapKey('map-sync');
      await acceptanceWaitIdle(d);
      await c.evidence('fixture-state', await d.fixture('state'));
    },
    (c) async {
      await c.same('/outbox');
      await c.expect('/transport', 'eq', 'unavailable-local-client');
      await c.expect('/model/syncProgress/stage', 'eq', 'finished');
      _finishedFailure(c);
      final state = await d.fixture('state');
      nativeRequire(
        !nativeObjects(state['requests']).any((e) => e['kind'] == 'sync'),
        'Unavailable client must not send HTTP or acknowledge.',
      );
    },
  );
  await r.check(
    'N2.settings-retry',
    (c) async {
      await d.fixture('control', body: {'sqlFault': 'settings'});
      await d.tapKey('online-toggle');
      final failed = await d.waitForSnapshot(
        'Online write failure retains true flag',
        (s) =>
            acceptanceIdle(s) &&
            acceptanceModel(s)['settingsError'] != null &&
            acceptanceModel(s)['online'] == true,
      );
      final failedRef = await c.sample('flag-rollback', failed);
      await c.expect(
        '/persistedSettings/online',
        'eq',
        true,
        artifact: failedRef,
      );
      await d.fixture('control', body: {'sqlFault': 'none'});
      await d.tapKey('zoom-in');
      final viewport = await d.waitForSnapshot(
        'successful viewport cannot hide pending Online retry',
        (s) =>
            acceptanceIdle(s) &&
            acceptanceModel(s)['settingsError'] != null &&
            acceptanceCameraMatches(
              s['camera'],
              nativeObject(s['persistedSettings'])['viewport'],
            ),
      );
      final viewRef = await c.sample('viewport-success', viewport);
      await c.expect('/model/online', 'eq', true, artifact: viewRef);
      await c.expect(
        '/persistedSettings/online',
        'eq',
        true,
        artifact: viewRef,
      );
      nativeRequire(
        nativeObject(viewport['bounds']).containsKey('retry-settings'),
        'Online Retry disappeared after unrelated viewport success.',
      );
      await d.tapKey('retry-settings');
      await d.waitForSnapshot(
        'actual settings Retry commits false',
        (s) =>
            acceptanceIdle(s) &&
            acceptanceModel(s)['settingsError'] == null &&
            acceptanceModel(s)['online'] == false,
      );
    },
    (c) async {
      await c.expect('/model/online', 'eq', false);
      await c.expect('/persistedSettings/online', 'eq', false);
      await c.expect('/model/settingsError', 'eq', null);
      await c.same('/outbox');
    },
  );
}

Future<void> _n3(NativeAcceptanceRecorder r) async {
  final d = r.client;
  nativeRequire(
    d.options.configuration == 'demo',
    'Transport fault acceptance requires controlled demo.',
  );
  await acceptanceOnline(d, false);
  await acceptanceComplete(d, 'TV-300002');
  await acceptanceMap(d);
  Future<void> failedRun(String sync, {String sqlFault = 'none'}) async {
    await d.fixture('control', body: {'sync': sync, 'sqlFault': sqlFault});
    await acceptanceOnline(d, true);
    await acceptanceWaitIdle(d);
  }

  for (final entry in {
    'N3.wrong-ack': 'wrong',
    'N3.send-timeout': 'never',
    'N3.ack-rollback': 'match',
  }.entries) {
    await r.check(
      entry.key,
      (c) async {
        await failedRun(
          entry.value,
          sqlFault: entry.key == 'N3.ack-rollback' ? 'ack' : 'none',
        );
        await c.evidence('fixture-state', await d.fixture('state'));
      },
      (c) async {
        await c.same('/outbox');
        await c.expect('/outbox', 'length', 1);
        await c.expect('/model/syncProgress/stage', 'eq', 'finished');
        _finishedFailure(c);
        await c.expect('/model/syncProgress/confirmedCount', 'eq', 0);
        nativeRequire(
          acceptanceStop(
                c.after,
                'TV-300002',
                persisted: true,
              )['acknowledgedAt'] ==
              null,
          'Failed ACK/timeout may not mark uploaded.',
        );
      },
    );
    await acceptanceOnline(d, false);
    await d.fixture('control', body: {'sqlFault': 'none'});
  }
  await acceptanceComplete(d, 'TV-300004');
  await acceptanceMap(d);
  await r.check(
    'N3.pause-inflight',
    (c) async {
      await d.fixture('control', body: {'sync': 'hold', 'delayMs': 0});
      await d.tapKey('online-toggle');
      await d.waitForSnapshot(
        'actual first request in flight',
        (s) =>
            acceptanceModel(s)['isSyncing'] == true &&
            nativeObject(acceptanceModel(s)['syncProgress'])['stage'] ==
                'sending',
      );
      await d.tapKey('online-toggle');
      await d.waitForSnapshot(
        'Offline persisted while owner still sending',
        (s) =>
            acceptanceModel(s)['online'] == false &&
            nativeObject(s['persistedSettings'])['online'] == false,
      );
      await c.sample('pause-requested', await d.snapshot());
      await d.fixture('control', body: {'sync': 'match'});
      await acceptanceWaitIdle(d);
    },
    (c) async {
      await c.expect('/outbox', 'length', 1);
      await c.expect('/model/online', 'eq', false);
      await c.expect('/model/syncProgress/confirmedCount', 'eq', 1);
      nativeRequire(
        acceptanceStop(
                  c.after,
                  'TV-300002',
                  persisted: true,
                )['acknowledgedAt'] !=
                null &&
            acceptanceStop(
                  c.after,
                  'TV-300004',
                  persisted: true,
                )['acknowledgedAt'] ==
                null,
        'Pause must commit only the matching in-flight ACK and retain the next event.',
      );
    },
  );
  await acceptanceOpenListStop(d, 'TV-300005');
  await d.fixture('control', body: {'sync': 'hold'});
  await r.check(
    'N3.tail-enqueue',
    (c) async {
      await d.tapKey('online-toggle');
      await d.waitForSnapshot(
        'held second operation owner',
        (s) => acceptanceModel(s)['isSyncing'] == true,
      );
      await d.revealKey('detail-complete');
      await d.tapKey('detail-complete');
      await d.waitForSnapshot(
        'tail result locally committed during active owner',
        (s) =>
            acceptanceModel(s)['isSaving'] == false &&
            acceptanceStop(s, 'TV-300005', persisted: true)['status'] ==
                'completed',
      );
      final tail = await d.snapshot();
      final ref = await c.sample('tail-enqueued', tail);
      await c.expect('/outbox', 'length', 2, artifact: ref);
      await c.expect('/model/isSyncing', 'eq', true, artifact: ref);
      nativeRequire(
        acceptanceOutbox(tail)[1]['stopId'] ==
            acceptanceStop(tail, 'TV-300005')['id'],
        'Tail enqueue order is not immutable.',
      );
      await d.fixture('control', body: {'sync': 'match'});
      await d.waitForSnapshot(
        'existing owner drains new tail',
        (s) => acceptanceIdle(s) && acceptanceOutbox(s).isEmpty,
      );
    },
    (c) async {
      await c.expect('/outbox', 'length', 0);
      await c.expect('/model/selected/status', 'eq', 'completed');
      await c.expect('/model/syncProgress/confirmedCount', 'eq', 2);
    },
  );
  await acceptanceMap(d);
  await acceptanceOnline(d, false);
  await acceptanceComplete(d, 'TV-300006');
  await acceptanceList(d);
  await r.check(
    'N3.single-owner',
    (c) async {
      await d.fixture('control', body: {'sync': 'hold'});
      await d.tapKey('online-toggle');
      final held = await d.waitForSnapshot(
        'single coordinator in flight',
        (s) => acceptanceModel(s)['isSyncing'] == true,
      );
      final runId = nativeObject(
        acceptanceModel(held)['syncProgress'],
      )['runId'];
      await d.tapKey('list-sync');
      await d.tapKey('list-sync');
      final joined = await d.snapshot();
      await c.sample('joined-owner', joined);
      nativeRequire(
        nativeObject(acceptanceModel(joined)['syncProgress'])['runId'] == runId,
        'Manual/automatic triggers created another coordinator owner.',
      );
      await d.fixture('control', body: {'sync': 'match'});
      await d.waitForSnapshot(
        'existing owner drains newly enqueued tail',
        (s) => acceptanceIdle(s) && acceptanceOutbox(s).isEmpty,
      );
      await c.evidence('fixture-state', await d.fixture('state'));
    },
    (c) async {
      await c.expect('/outbox', 'length', 0);
      await c.expect('/model/syncProgress/confirmedCount', 'eq', 1);
      await c.expect('/model/syncProgress/stage', 'eq', 'finished');
      nativeRequire(
        acceptanceEvents(c.after, d, 'ack_committed').length == 4,
        'Durable confirmation count must include exactly four unique records.',
      );
    },
  );
}

Future<void> _mapSearch(NativeWorkbenchDriver d, String text) async {
  await acceptanceMap(d);
  final current = await d.snapshot();
  if (!nativeObject(current['bounds']).containsKey('map-search')) {
    await d.tapKey('open-search');
  }
  await d.enterText('map-search', text);
  await d.waitForSnapshot(
    'map actual query $text',
    (s) => nativeObject(acceptanceModel(s)['query'])['search'] == text,
  );
}

Future<void> _openMapStop(NativeWorkbenchDriver d, String reference) async {
  await _mapSearch(d, reference);
  final current = await d.snapshot();
  final query = nativeObject(acceptanceModel(current)['query']);
  if (query['status'] != null) await d.tapKey('header-filter-all');
  if (query['waitingOnly'] == true) {
    await acceptanceSummaryKey(d, 'map-waiting-only');
    await d.tapKey('map-waiting-only');
    await acceptanceMap(d);
  }
  if ((nativeObject(current['mediaQuery'])['textScaleAt16'] as num) >= 2) {
    await acceptanceSummaryKey(d, 'nearest-stop');
    // Reading the summary does not change the typed source of a map marker.
    await acceptanceMap(d);
  }
  await d.tapKey('fit-stops');
  await d.waitForSnapshot(
    'filtered map marker visible',
    (s) => nativeObject(s['bounds']).containsKey('map-stop-$reference'),
  );
  await d.tapKey('map-stop-$reference');
  await d.waitForSnapshot(
    'actual map-origin detail',
    (s) =>
        acceptanceModel(s)['panel'] == 'detail' &&
        acceptanceModel(s)['selectedOrigin'] == 'map' &&
        nativeObject(acceptanceModel(s)['selected'])['reference'] == reference,
  );
}

Future<void> _n4(NativeAcceptanceRecorder r) async {
  final d = r.client;
  await acceptanceOnline(d, false);
  await acceptanceComplete(d, 'TV-300002');
  await acceptanceMap(d);
  await _mapSearch(d, '');
  await r.check(
    'N4.map-controls',
    (c) async {
      final first = await d.snapshot();
      final zoom = nativeObject(first['camera'])['zoom'] as num;
      await d.tapKey('zoom-in');
      final plus = await d.waitForSnapshot(
        'Zoom In changes actual camera',
        (s) => (nativeObject(s['camera'])['zoom'] as num) > zoom,
      );
      final plusRef = await c.sample('zoom-in', plus);
      await c.expect('/camera/zoom', 'gte', zoom + .9, artifact: plusRef);
      await d.tapKey('zoom-out');
      await d.waitForSnapshot(
        'Zoom Out restores camera',
        (s) => ((nativeObject(s['camera'])['zoom'] as num) - zoom).abs() < .01,
      );
      final outGesture = await d.pinchMap(outward: true);
      c.metadata['pinch_out_input'] = outGesture;
      final pinchedOut = await d.waitForSnapshot(
        'two actual touch pointers increase map zoom',
        (s) => (nativeObject(s['camera'])['zoom'] as num) > zoom + .5,
      );
      final outRef = await c.sample('pinch-out', pinchedOut);
      await c.expect('/camera/zoom', 'gte', zoom + .5, artifact: outRef);
      final pinchZoom = nativeObject(pinchedOut['camera'])['zoom'] as num;
      c.metadata['pinch_in_input'] = await d.pinchMap(outward: false);
      final pinchedIn = await d.waitForSnapshot(
        'two actual touch pointers decrease map zoom',
        (s) => (nativeObject(s['camera'])['zoom'] as num) < pinchZoom - .5,
      );
      await c.sample('pinch-in', pinchedIn);
      await d.tapKey('fit-stops');
      await c.sample('fit', await d.snapshot());
      String? cluster;
      for (var attempt = 0; attempt < 4; attempt++) {
        final readinessClock = Stopwatch()..start();
        Map<String, Object?>? previousReadiness;
        Duration? quietSince;
        String? readyCluster;
        final overview = await d.waitForSnapshot(
          'actual map camera and exposed cluster stable for 500 milliseconds',
          (s) {
            final camera = nativeObject(s['camera']);
            final bounds = nativeObject(s['bounds']);
            Map<String, dynamic>? uniqueRect(String key) {
              final rows = bounds[key];
              if (rows is! List || rows.length != 1 || rows.single is! Map) {
                return null;
              }
              final rect = nativeObject(rows.single);
              if (['left', 'top', 'right', 'bottom', 'width', 'height'].any(
                    (field) =>
                        rect[field] is! num || !(rect[field] as num).isFinite,
                  ) ||
                  (rect['right'] as num) <= (rect['left'] as num) ||
                  (rect['bottom'] as num) <= (rect['top'] as num)) {
                return null;
              }
              return rect;
            }

            final viewport = uniqueRect('delivery-map');
            final media = nativeObject(s['mediaQuery']);
            final padding = nativeObject(media['padding']);
            final dimensions = [
              media['width'],
              media['height'],
              padding['left'],
              padding['top'],
              padding['right'],
              padding['bottom'],
            ];
            final valid =
                s['mapReady'] == true &&
                nativeObject(s['model'])['panel'] == 'map' &&
                dimensions.every((value) => value is num && value.isFinite) &&
                ['latitude', 'longitude', 'zoom', 'rotation'].every(
                  (field) =>
                      camera[field] is num && (camera[field] as num).isFinite,
                );
            if (viewport == null || !valid) {
              previousReadiness = null;
              quietSince = null;
              readyCluster = null;
              return false;
            }
            String? candidate;
            Map<String, dynamic>? candidateRect;
            final clusterBounds = <String, Object?>{};
            for (final key in bounds.keys.where(
              (key) => key.startsWith('map-cluster-'),
            )) {
              clusterBounds[key] = bounds[key];
              final rect = uniqueRect(key);
              if (candidate != null ||
                  rect == null ||
                  rect['centerHit'] != true ||
                  (rect['width'] as num) < 44 ||
                  (rect['height'] as num) < 44 ||
                  (rect['left'] as num) < (viewport['left'] as num) ||
                  (rect['top'] as num) < (viewport['top'] as num) ||
                  (rect['right'] as num) > (viewport['right'] as num) ||
                  (rect['bottom'] as num) > (viewport['bottom'] as num) ||
                  (rect['left'] as num) < (padding['left'] as num) ||
                  (rect['top'] as num) < (padding['top'] as num) ||
                  (rect['right'] as num) >
                      (media['width'] as num) - (padding['right'] as num) ||
                  (rect['bottom'] as num) >
                      (media['height'] as num) - (padding['bottom'] as num)) {
                continue;
              }
              candidate = key;
              candidateRect = rect;
            }
            final readiness = <String, Object?>{
              'camera': camera,
              'viewport': viewport,
              'candidate': candidate,
              'rect': candidateRect,
              if (candidate == null) 'clusterBounds': clusterBounds,
            };
            if (previousReadiness == null ||
                !acceptanceEqual(previousReadiness, readiness)) {
              previousReadiness = readiness;
              quietSince = readinessClock.elapsed;
              readyCluster = null;
              return false;
            }
            if (readinessClock.elapsed - quietSince! <
                const Duration(milliseconds: 500)) {
              return false;
            }
            readyCluster = candidate;
            return true;
          },
          timeout: NativeWorkbenchDriver.observationDeadline,
        );
        if (readyCluster != null) {
          cluster = readyCluster;
          await c.sample('cluster-overview', overview);
          break;
        }
        await d.tapKey('zoom-out');
      }
      nativeRequire(
        cluster != null,
        'Bounded actual map overview exposed no cluster.',
      );
      await d.tapKey(cluster!);
      await c.sample('cluster-expanded', await d.snapshot());
      await _openMapStop(d, 'TV-300002');
      await c.sample('marker-selected', await d.snapshot());
      await acceptanceReturn(d);
      await d.tapKey('locate-reference');
      await d.waitForSnapshot(
        'Locate actual fixed test reference',
        (s) =>
            ((nativeObject(s['camera'])['latitude'] as num) + 33.9004).abs() <
                .00001 &&
            ((nativeObject(s['camera'])['longitude'] as num) - 151.139).abs() <
                .00001,
      );
      await c.evidence('reference-semantics', {
        'id': await d.semanticsKey('locate-reference'),
      });
    },
    (c) async {
      await c.expect('/camera/latitude', 'eq', -33.9004);
      await c.expect('/camera/longitude', 'eq', 151.139);
      for (final key in [
        'zoom-in',
        'zoom-out',
        'fit-stops',
        'locate-reference',
        'map-sync',
      ]) {
        await c.expect('/bounds/$key/0/width', 'gte', 44);
        await c.expect('/bounds/$key/0/height', 'gte', 44);
      }
    },
  );
  await r.check(
    'N4.query-intersection-empty',
    (c) async {
      await acceptanceList(d);
      await acceptanceListQueryTools(d);
      await d.enterText('stop-search', 'Coastal Electronics');
      await d.tapKey('filter-pending');
      final pending = await d.waitForSnapshot(
        'search/status shared intersection',
        (s) => nativeObject(s['result'])['matchedCount'] == 1,
      );
      final pendingRef = await c.sample('intersection', pending);
      await c.expect(
        '/result/references/0',
        'eq',
        'TV-300020',
        artifact: pendingRef,
      );
      await d.tapKey('waiting-only');
      final empty = await d.waitForSnapshot(
        'waiting/search/status empty intersection',
        (s) => nativeObject(s['result'])['matchedCount'] == 0,
      );
      final emptyRef = await c.sample('empty', empty);
      await c.expect('/result/matchedCount', 'eq', 0, artifact: emptyRef);
      await c.expect('/result/totalQueueCount', 'eq', 1, artifact: emptyRef);
      await d.tapKey('waiting-only');
      await d.tapKey('filter-all');
      await acceptanceListQueryTools(d);
      await d.enterText('stop-search', 'Sydney NSW');
      await d.waitForSnapshot(
        'actual address search',
        (s) => nativeObject(s['result'])['matchedCount'] == 1,
      );
    },
    (c) async {
      await c.expect('/result/references/0', 'eq', 'TV-300020');
      await c.expect('/model/query/search', 'eq', 'Sydney NSW');
      await c.expect('/model/query/status', 'eq', null);
      await c.expect('/model/query/waitingOnly', 'eq', false);
      await c.expect('/model/queueCount', 'eq', 1);
    },
  );
  await r.check(
    'N4.reference-nearest',
    (c) async {
      await acceptanceMap(d);
      await _mapSearch(d, '');
      await d.tapKey('header-filter-pending');
      final beforeNearest = await d.snapshot();
      final ref = await c.sample('eligible-nearest', beforeNearest);
      await acceptanceNearest(d);
      final nearest = await d.waitForSnapshot(
        'nearest action actual pending detail',
        (s) =>
            acceptanceModel(s)['panel'] == 'detail' &&
            acceptanceModel(s)['selectedOrigin'] == 'nearest',
      );
      nativeRequire(
        nativeObject(acceptanceModel(nearest)['selected'])['id'] ==
            nativeObject(beforeNearest['result'])['nearestId'],
        'Nearest action must use current eligible shared query.',
      );
      await c.expect(
        '/result/nearestId',
        'eq',
        nativeObject(acceptanceModel(nearest)['selected'])['id'],
        artifact: ref,
      );
      await c.evidence('reference-label', {
        'text': await d.textLabel('Test reference'),
      });
    },
    (c) async {
      await c.expect('/model/selectedOrigin', 'eq', 'nearest');
      await c.expect('/model/selected/status', 'eq', 'pending');
    },
  );
  await acceptanceMap(d);
  await r.check(
    'N4.typed-returns',
    (c) async {
      await _mapSearch(d, '');
      await acceptanceNearest(d);
      await d.waitForSnapshot(
        'nearest detail for typed Close',
        (s) =>
            acceptanceModel(s)['selectedOrigin'] == 'nearest' &&
            acceptanceModel(s)['panel'] == 'detail',
      );
      await c.sample('nearest-origin', await d.snapshot());
      await acceptanceCloseDetail(d);
      await c.sample('nearest-return', await d.snapshot());
      await d.tapKey('header-filter-all');
      await _openMapStop(d, 'TV-300002');
      await c.sample('map-origin', await d.snapshot());
      await d.tapKey('detail-close');
      final mapReturn = await d.waitForSnapshot(
        'Close restores map source',
        (s) => acceptanceModel(s)['panel'] == 'map',
      );
      await c.sample('map-return', mapReturn);
      // Return belongs to terminal detail; retain a real terminal Return as
      // well as the pending nearest/deep-list Close and map Close branches.
      await _openMapStop(d, 'TV-300002');
      await acceptanceReturn(d);
      await c.sample('terminal-map-return', await d.snapshot());
      await acceptanceList(d);
      await acceptanceListQueryTools(d);
      await d.enterText('stop-search', '');
      final scrollDeadline = Stopwatch()..start();
      Map<String, dynamic>? scrolled;
      for (
        var attempt = 0;
        attempt < 12 &&
            scrollDeadline.elapsed < NativeWorkbenchDriver.observationDeadline;
        attempt++
      ) {
        final row = await d.snapshot().timeout(
          NativeWorkbenchDriver.observationDeadline - scrollDeadline.elapsed,
        );
        final targetRows = nativeObject(row['bounds'])['stop-TV-300023'];
        final targetExposed =
            targetRows is List &&
            targetRows.length == 1 &&
            targetRows.single is Map &&
            (targetRows.single as Map)['centerHit'] == true;
        if (targetExposed) {
          await d
              .revealKey('stop-TV-300023')
              .timeout(
                NativeWorkbenchDriver.observationDeadline -
                    scrollDeadline.elapsed,
              );
          scrolled = await d.snapshot().timeout(
            NativeWorkbenchDriver.observationDeadline - scrollDeadline.elapsed,
          );
          break;
        }
        await d
            .scrollKey('stop-list-scroll', -350)
            .timeout(
              NativeWorkbenchDriver.observationDeadline -
                  scrollDeadline.elapsed,
            );
      }
      if (scrolled == null) {
        throw StateError(
          'Bounded real lazy-list scroll did not expose TV-300023.',
        );
      }
      nativeRequire(
        (nativeObject(acceptanceModel(scrolled)['listSession'])['scrollOffset']
                as num) >
            400,
        'Deep-list UI path must retain a real nonzero offset.',
      );
      await c.sample('scrolled-list', scrolled);
      c.metadata['list_before'] = r.relative('${c.slug}-scrolled-list.json');
      await d.tapKey('stop-TV-300023');
      final detail = await d.waitForSnapshot(
        'deep-list actual source detail',
        (s) =>
            acceptanceModel(s)['panel'] == 'detail' &&
            nativeObject(acceptanceModel(s)['selected'])['reference'] ==
                'TV-300023',
      );
      await c.sample('list-origin', detail);
      await d.revealKey('detail-fail');
      await d.tapKey('detail-fail');
      final modalReturn = await _closeListOriginFailure(d, 'TV-300023');
      await c.sample('modal-return', modalReturn);
      nativeRequire(
        acceptanceModel(modalReturn)['panel'] == 'detail' &&
            !nativeObject(modalReturn['bounds']).containsKey('failure-sheet'),
        'Modal Close must preserve selected detail.',
      );
      await acceptanceCloseDetail(d);
      await d.waitForSnapshot(
        'real list offset and row focus restored',
        (s) =>
            acceptanceModel(s)['panel'] == 'list' &&
            s['focusedWidget'] == 'Stop TV-300023',
      );
    },
    (c) async {
      await c.expect('/model/panel', 'eq', 'list');
      await c.expect('/model/query/search', 'eq', '');
      await c.expect('/model/listSession/focusedReference', 'eq', 'TV-300023');
      await c.expect('/focusedWidget', 'eq', 'Stop TV-300023');
      await c.expect('/model/selected', 'eq', null);
      await c.expect(
        '/model/listSession/scrollOffset',
        'eq',
        null,
        rightArtifact: c.metadata['list_before'] as String,
        rightPointer: '/model/listSession/scrollOffset',
      );
      await c.same('/outbox');
    },
  );
  await acceptanceMap(d);
  await _openMapStop(d, 'TV-300002');
  await r.check(
    'N4.notice-context',
    (c) async {
      await d.tapKey('map-sync');
      await acceptanceWaitIdle(d);
      await d.waitForSnapshot(
        'direct Sync yields local nonmodal notice',
        (s) => acceptanceModel(s)['notice'] != null,
      );
      await c.evidence('notice-ui', {
        'text': await d.textKey('notice-message'),
      });
    },
    (c) async {
      await c.same('/camera');
      await c.same('/model/query');
      await c.same('/model/selected');
      await c.same('/model/selectedOrigin');
      await c.same('/model/listSession');
      await c.same('/outbox');
      await c.expect('/model/panel', 'eq', 'detail');
      await c.expect('/model/online', 'eq', false);
      await c.expect('/bounds/workbench-notice/0/height', 'gte', 1);
    },
  );
}

Future<void> _n5(NativeAcceptanceRecorder r) async {
  final d = r.client;
  nativeRequire(
    d.options.values['initial-tiles'] == '503',
    'N5 must start with failing local tiles before first map mount.',
  );
  await acceptanceOnline(d, false);
  await d.waitForSnapshot(
    'actual first-mount tile503 error',
    (s) =>
        s['tileStatus'] == 'error' &&
        nativeObject(s['bounds']).containsKey('retry-map'),
  );
  await r.check(
    'N5.tile-degraded-retry',
    (c) async {
      await d.waitForSnapshot(
        'actual tile503 Retry UI',
        (s) =>
            s['tileStatus'] == 'error' &&
            nativeObject(s['bounds']).containsKey('retry-map'),
      );
      await acceptanceFailureSave(
        d,
        'TV-300002',
        'address-not-found',
        'tile fault keeps business usable',
      );
      await c.sample('business-while-degraded', await d.snapshot());
      await acceptanceMap(d);
      await _mapSearch(d, 'TV-300002');
      await d.tapKey('header-filter-failed');
      await d.tapKey('map-waiting-only');
      final degraded = await d.snapshot();
      final ref = await c.sample('degraded-query', degraded);
      await c.expect('/tileStatus', 'eq', 'error', artifact: ref);
      await c.expect('/result/matchedCount', 'eq', 1, artifact: ref);
      await c.expect('/model/queueCount', 'eq', 1, artifact: ref);
      await d.fixture('control', body: {'tiles': 'normal'});
      await d.tapKey('retry-map');
      await d.waitForSnapshot(
        'explicit Retry recovers actual local tiles',
        (s) => s['tileStatus'] == 'ready',
      );
    },
    (c) async {
      await c.expect('/tileStatus', 'eq', 'ready');
      await c.expect('/outbox', 'length', 1);
      await c.expect('/model/query/search', 'eq', 'TV-300002');
      await c.expect('/model/query/status', 'eq', 'failed');
      await c.expect('/model/query/waitingOnly', 'eq', true);
      await c.expect('/result/matchedCount', 'eq', 1);
    },
  );
  await r.check(
    'N5.cache-only-clear',
    (c) async {
      await d.tapKey('zoom-in');
      await d.waitForSnapshot(
        'changed actual viewport committed',
        (s) => acceptanceCameraMatches(
          s['camera'],
          nativeObject(s['persistedSettings'])['viewport'],
        ),
      );
      final preClear = await c.sample('pre-clear', await d.snapshot());
      c.metadata['cache_before'] = preClear;
      await d.tapKey('map-attribution');
      await d.revealKey('clear-map-cache');
      await d.tapKey('clear-map-cache');
      await d.waitForSnapshot(
        'cache recreation ready and deliveries kept',
        (s) =>
            s['tileStatus'] == 'ready' && acceptanceModel(s)['notice'] != null,
      );
    },
    (c) async {
      await c.same('/outbox');
      await c.same('/persistedStops');
      await c.same('/model/query');
      await c.expect(
        '/camera',
        'eq',
        null,
        rightArtifact: c.metadata['cache_before'] as String,
        rightPointer: '/camera',
      );
      await c.expect('/outbox', 'length', 1);
      await c.expect('/model/online', 'eq', false);
      await c.expect('/tileStatus', 'eq', 'ready');
      nativeRequire(
        acceptanceCameraMatches(
          c.after['camera'],
          nativeObject(c.after['persistedSettings'])['viewport'],
        ),
        'Cache clear lost durable camera.',
      );
    },
  );
}

Future<void> _migrationRollback(NativeAcceptanceRecorder r) async {
  final d = r.client;
  nativeRequire(
    d.options.values['fixture'] == 'legacy-v1-identity-seq',
    'Migration failure must use genuine prelaunch v1 schema/data.',
  );
  await d.waitForSnapshot(
    'actual failed v1 bootstrap with Retry',
    (s) =>
        (s['model'] == null || acceptanceModel(s)['initialized'] == false) &&
        s['outbox'] == null &&
        nativeObject(s['bounds']).containsKey('reload-data'),
  );
  await r.check(
    'N6.migration-rollback-retry',
    (c) async {
      await d.writeJson('migration-rollback-snapshot.json', c.before);
      final legacy = await d.fixture(
        'capture',
        body: {'name': 'migration-rollback'},
      );
      await c.evidence('v1-capture', legacy);
      nativeRequire(
        nativeObject(legacy['database'])['user_version'] == 1,
        'Failed migration backup must remain real v1.',
      );
      c.metadata['rollback_sqlite'] = 'saved/migration-rollback.sqlite';
      c.metadata['rollback_snapshot'] =
          'saved/migration-rollback-snapshot.json';
      c.metadata['legacy_before_sqlite'] = 'legacy-before-launch.sqlite';
      await d.fixture('control', body: {'migrationFault': 'none'});
      await d.tapKey('reload-data');
      await acceptanceReady(d);
    },
    (c) async {
      await c.expect('/model/initialized', 'eq', true);
      await c.expect('/stops', 'length', 30);
      await c.expect('/outbox', 'length', 2);
      await c.expect('/outbox/0/seq', 'eq', 7);
      await c.expect('/outbox/1/seq', 'eq', 11);
    },
  );
}

Future<void> _n6(NativeAcceptanceRecorder r) async {
  final d = r.client;
  nativeRequire(
    d.options.values['fixture'] == 'legacy-v1-identity-seq',
    'N6 requires actual legacy fixture before first launch.',
  );
  await acceptanceOnline(d, false);
  if (d.options.values['migration-fault'] != 'true') {
    r.notApplicable(
      'N6.migration-rollback-retry',
      'This job covers normal v1 upgrade; explicit migration-fault job must provide the rollback/Retry evidence.',
    );
  }
  await r.check(
    'N6.genuine-v1-upgrade',
    (c) async {
      nativeRequire(
        acceptanceOutbox(c.before).length == 2 &&
            acceptanceOutbox(c.before)[0]['seq'] == 7 &&
            acceptanceOutbox(c.before)[1]['seq'] == 11,
        'Migration rewrote original sequence/queue.',
      );
      final legacyReason = acceptanceStop(c.before, 'TV-300002');
      nativeRequire(
        legacyReason['id'] == 'legacy-TV-300002' &&
            legacyReason['reason'] == '  Historical reason  ' &&
            legacyReason['operationId'] == 'legacy-operation-1' &&
            legacyReason['note'] == null &&
            legacyReason['recordedAt'] == null &&
            legacyReason['timeWindow'] == '08:00-10:00',
        'Migration changed historical identity/reason/unknown timestamps or failed safe source backfill.',
      );
      await c.sample('migrated-before-new-record', c.before);
      await acceptanceComplete(d, 'TV-300004');
      c.metadata['legacy_before_sqlite'] = 'legacy-before-launch.sqlite';
    },
    (c) async {
      await c.expect('/outbox', 'length', 3);
      await c.expect('/outbox/0/seq', 'eq', 7);
      await c.expect('/outbox/1/seq', 'eq', 11);
      await c.expect('/outbox/2/seq', 'eq', 23);
      await c.expect('/outbox/1/reason', 'eq', '  Historical reason  ');
      await c.expect('/outbox/1/note', 'eq', null);
      await c.expect('/outbox/1/recordedAt', 'eq', null);
      await c.expect('/model/selected/id', 'eq', 'legacy-TV-300004');
      await c.expect('/model/selected/timeWindow', 'eq', '10:00-12:00');
    },
  );
  await d.fixture('control', body: {'sync': 'match'});
}

Map<String, dynamic> _rect(Map<String, dynamic> snapshot, String key) {
  final rows = nativeObject(snapshot['bounds'])[key];
  nativeRequire(
    rows is List && rows.isNotEmpty,
    'Actual UI rectangle missing: $key',
  );
  return nativeObject((rows as List).first);
}

bool _intersects(Map<String, dynamic> a, Map<String, dynamic> b) =>
    (a['left'] as num) < (b['right'] as num) &&
    (a['right'] as num) > (b['left'] as num) &&
    (a['top'] as num) < (b['bottom'] as num) &&
    (a['bottom'] as num) > (b['top'] as num);
void _visible(
  Map<String, dynamic> snapshot,
  String key, {
  bool keyboard = false,
  bool minimumTarget = true,
}) {
  final rect = _rect(snapshot, key);
  final media = nativeObject(snapshot['mediaQuery']);
  final padding = nativeObject(media['viewPadding']);
  final insets = nativeObject(media['viewInsets']);
  final bottom =
      (media['height'] as num) -
      (keyboard ? insets['bottom'] as num : padding['bottom'] as num);
  nativeRequire(
    (rect['left'] as num) >= 0 &&
        (rect['right'] as num) <= (media['width'] as num) + .5 &&
        (rect['top'] as num) >= (keyboard ? 0 : padding['top'] as num) - .5 &&
        (rect['bottom'] as num) <= bottom + .5 &&
        rect['centerHit'] == true &&
        (!minimumTarget ||
            (rect['width'] as num) >= 44 && (rect['height'] as num) >= 44),
    'Full $key rectangle must be visible, hittable and at least44px within actual safe/keyboard area.',
  );
}

Map<String, dynamic> _n7UniqueRect(Map<String, dynamic> snapshot, String key) {
  final rows = nativeObject(snapshot['bounds'])[key];
  nativeRequire(
    rows is List && rows.length == 1 && rows.single is Map,
    'N7 needs one actual onstage rectangle for $key.',
  );
  final rect = nativeObject((rows as List).single);
  nativeRequire(
    ['left', 'top', 'right', 'bottom', 'width', 'height'].every(
          (field) => rect[field] is num && (rect[field] as num).isFinite,
        ) &&
        (rect['width'] as num) > 0 &&
        (rect['height'] as num) > 0,
    'N7 requires finite positive layout for $key.',
  );
  return rect;
}

/// Retain reading states before scrolling to a different field. Text probes
/// establish widget content; actual OS PNGs remain the clipping/ellipsis check.
Future<String> _n7ReadingCapture(
  AcceptanceCase c,
  String suffix, {
  required String scrollKey,
  Map<String, String> texts = const {},
  List<String> readTextKeys = const [],
  List<String> actions = const [],
  String? rowKey,
}) async {
  final d = c.recorder.client;
  final snapshot = await acceptanceStableCapture(d);
  final media = nativeObject(snapshot['mediaQuery']);
  final padding = nativeObject(media['viewPadding']);
  final viewport = _n7UniqueRect(snapshot, scrollKey);
  final workspace = _n7UniqueRect(snapshot, 'large-text-task-workspace');
  nativeRequire(
    (media['textScaleAt16'] as num) >= 2,
    'Reading evidence must retain the actual maximum system text size.',
  );
  final ref = await c.sample(suffix, snapshot);
  await c.expect('/mediaQuery/textScaleAt16', 'gte', 2, artifact: ref);
  final safeEdges = <String, num>{
    'left': padding['left'] as num,
    'top': padding['top'] as num,
    'right': (media['width'] as num) - (padding['right'] as num),
    'bottom': (media['height'] as num) - (padding['bottom'] as num),
  };
  for (final edge in safeEdges.entries) {
    nativeRequire(edge.value.isFinite, 'Actual SafeArea edges must be finite.');
    await c.expect(
      '/bounds/large-text-task-workspace/0/${edge.key}',
      'gte',
      edge.value - .5,
      artifact: ref,
    );
    await c.expect(
      '/bounds/large-text-task-workspace/0/${edge.key}',
      'lte',
      edge.value + .5,
      artifact: ref,
    );
  }
  for (final edge in ['left', 'top']) {
    await c.expect(
      '/bounds/$scrollKey/0/$edge',
      'gte',
      (workspace[edge] as num) - .5,
      artifact: ref,
    );
  }
  for (final edge in ['right', 'bottom']) {
    await c.expect(
      '/bounds/$scrollKey/0/$edge',
      'lte',
      (workspace[edge] as num) + .5,
      artifact: ref,
    );
  }
  if (scrollKey == 'stop-list-scroll' || scrollKey == 'large-summary-scroll') {
    // A visible field inside a small inset panel is insufficient. The real
    // primary scroll occupies at least 65% of the full SafeArea and reaches its
    // actual bottom, leaving only the persistent toolbar above it.
    await c.expect(
      '/bounds/$scrollKey/0/height',
      'gte',
      (workspace['height'] as num) * .65,
      artifact: ref,
    );
    await c.expect(
      '/bounds/$scrollKey/0/bottom',
      'gte',
      (workspace['bottom'] as num) - .5,
      artifact: ref,
    );
    if (scrollKey == 'large-summary-scroll') {
      _n7UniqueRect(snapshot, 'large-summary-workspace');
      for (final edge in ['left', 'top', 'right', 'bottom']) {
        await c.expect(
          '/bounds/large-summary-workspace/0/$edge',
          'gte',
          (workspace[edge] as num) - .5,
          artifact: ref,
        );
        await c.expect(
          '/bounds/large-summary-workspace/0/$edge',
          'lte',
          (workspace[edge] as num) + .5,
          artifact: ref,
        );
      }
    }
  } else if (scrollKey == 'detail-scroll') {
    _n7UniqueRect(snapshot, 'delivery-detail-card');
    for (final edge in ['left', 'top', 'right', 'bottom']) {
      await c.expect(
        '/bounds/delivery-detail-card/0/$edge',
        'gte',
        (workspace[edge] as num) - .5,
        artifact: ref,
      );
      await c.expect(
        '/bounds/delivery-detail-card/0/$edge',
        'lte',
        (workspace[edge] as num) + .5,
        artifact: ref,
      );
    }
  }
  final observedText = <String, String>{};
  for (final key in {...texts.keys, ...readTextKeys}) {
    _n7UniqueRect(snapshot, key);
    _visible(snapshot, key, minimumTarget: false);
    for (final edge in ['left', 'top']) {
      await c.expect(
        '/bounds/$key/0/$edge',
        'gte',
        (viewport[edge] as num) - .5,
        artifact: ref,
      );
    }
    for (final edge in ['right', 'bottom']) {
      await c.expect(
        '/bounds/$key/0/$edge',
        'lte',
        (viewport[edge] as num) + .5,
        artifact: ref,
      );
    }
    await c.expect('/bounds/$key/0/centerHit', 'eq', true, artifact: ref);
    observedText[key] = await d.textKey(key);
    nativeRequire(
      observedText[key]!.trim().isNotEmpty,
      'Actual reading text must be nonempty: $key.',
    );
  }
  final textRef = await c.evidence('$suffix-text', observedText);
  for (final entry in texts.entries) {
    await c.expect('/${entry.key}', 'eq', entry.value, artifact: textRef);
  }
  for (final key in actions) {
    _n7UniqueRect(snapshot, key);
    _visible(snapshot, key);
    await c.expect('/bounds/$key/0/width', 'gte', 44, artifact: ref);
    await c.expect('/bounds/$key/0/height', 'gte', 44, artifact: ref);
    await c.expect('/bounds/$key/0/centerHit', 'eq', true, artifact: ref);
  }
  if (rowKey != null) {
    final row = _n7UniqueRect(snapshot, rowKey);
    final centerX = ((row['left'] as num) + (row['right'] as num)) / 2;
    final centerY = ((row['top'] as num) + (row['bottom'] as num)) / 2;
    nativeRequire(
      centerX >= (viewport['left'] as num) &&
          centerX <= (viewport['right'] as num) &&
          centerY >= (viewport['top'] as num) &&
          centerY <= (viewport['bottom'] as num) &&
          centerY >= (padding['top'] as num) &&
          centerY <= (media['height'] as num) - (padding['bottom'] as num),
      'The first readable row needs an actual center inside the list viewport.',
    );
    await c.expect('/bounds/$rowKey/0/width', 'gte', 44, artifact: ref);
    await c.expect('/bounds/$rowKey/0/height', 'gte', 44, artifact: ref);
    await c.expect('/bounds/$rowKey/0/centerHit', 'eq', true, artifact: ref);
  }
  final name = '${c.slug}-$suffix';
  await c.evidence('$suffix-capture', await d.captureNamed(name, snapshot));
  c.metadata['${suffix}_capture'] = {
    'snapshot': ref,
    'text': textRef,
    'png': c.recorder.relative('$name.png'),
    'sqlite': c.recorder.relative('$name.sqlite'),
    'projection': c.recorder.relative('$name.sqlite.json'),
    'journal': c.recorder.relative('$name.journal.jsonl'),
  };
  return ref;
}

Future<String> _n7MapReadingCapture(AcceptanceCase c, String suffix) async {
  final d = c.recorder.client;
  final snapshot = await acceptanceStableCapture(d);
  nativeRequire(
    acceptanceModel(snapshot)['panel'] == 'map' &&
        !nativeObject(
          snapshot['bounds'],
        ).containsKey('large-summary-workspace'),
    'Map reading requires the actual closed summary and onstage map.',
  );
  final pending = acceptanceModel(snapshot)['pendingCount'];
  nativeRequire(
    pending is int && pending >= 0,
    'Actual pending total required.',
  );
  final ref = await c.sample(suffix, snapshot);
  await c.expect('/mediaQuery/textScaleAt16', 'gte', 2, artifact: ref);
  await c.expect('/model/panel', 'eq', 'map', artifact: ref);
  await c.expect(
    '/bounds/large-summary-workspace',
    'absent',
    null,
    artifact: ref,
  );
  _n7UniqueRect(snapshot, 'map-summary-remaining');
  _visible(snapshot, 'map-summary-remaining', minimumTarget: false);
  await c.expect(
    '/bounds/map-summary-remaining/0/centerHit',
    'eq',
    true,
    artifact: ref,
  );
  final textRef = await c.evidence('$suffix-text', {
    'remaining': await d.textKey('map-summary-remaining'),
  });
  await c.expect(
    '/remaining',
    'eq',
    '$pending left to deliver',
    artifact: textRef,
  );
  for (final key in ['browse-stops', 'map-summary-open']) {
    _n7UniqueRect(snapshot, key);
    _visible(snapshot, key);
    await c.expect('/bounds/$key/0/width', 'gte', 44, artifact: ref);
    await c.expect('/bounds/$key/0/height', 'gte', 44, artifact: ref);
    await c.expect('/bounds/$key/0/centerHit', 'eq', true, artifact: ref);
  }
  final name = '${c.slug}-$suffix';
  await c.evidence('$suffix-capture', await d.captureNamed(name, snapshot));
  c.metadata['${suffix}_capture'] = {
    'snapshot': ref,
    'text': textRef,
    'png': c.recorder.relative('$name.png'),
    'sqlite': c.recorder.relative('$name.sqlite'),
    'projection': c.recorder.relative('$name.sqlite.json'),
    'journal': c.recorder.relative('$name.journal.jsonl'),
  };
  return ref;
}

Future<void> _n7SummaryReading(
  AcceptanceCase c,
  String prefix, {
  bool feedback = false,
}) async {
  final d = c.recorder.client;
  final before = await acceptanceStableCapture(d);
  nativeRequire(
    acceptanceModel(before)['panel'] == 'map' &&
        nativeObject(before['bounds']).containsKey('map-summary-open'),
    'Summary must open through its actual large-text map button.',
  );
  final beforeRef = await c.sample('$prefix-map-context', before);
  final pending = acceptanceModel(before)['pendingCount'];
  final nearestId = nativeObject(before['result'])['nearestId'];
  final nearest = nearestId == null
      ? null
      : nativeObjects(
          before['stops'],
        ).singleWhere((stop) => stop['id'] == nearestId);
  if (feedback) {
    final message = nativeObject(acceptanceModel(before)['notice'])['message'];
    nativeRequire(
      message is String && message.isNotEmpty,
      'Summary feedback must bind to the current actual UI notice.',
    );
    await acceptanceSummaryKey(d, 'notice-message', entireField: true);
    await _n7ReadingCapture(
      c,
      '$prefix-notice',
      scrollKey: 'large-summary-scroll',
      texts: {'notice-message': message as String},
      actions: ['summary-close'],
    );
  }
  await acceptanceSummaryKey(d, 'summary-remaining', entireField: true);
  await _n7ReadingCapture(
    c,
    '$prefix-remaining',
    scrollKey: 'large-summary-scroll',
    texts: {'summary-remaining': '$pending left to deliver'},
    actions: ['summary-close'],
  );
  await acceptanceSummaryKey(d, 'summary-nearest-customer', entireField: true);
  final customerRef = await _n7ReadingCapture(
    c,
    '$prefix-customer',
    scrollKey: 'large-summary-scroll',
    texts: {
      'summary-nearest-customer':
          nearest?['customerName'] as String? ?? 'No matching stops',
    },
    actions: ['summary-close'],
  );
  await c.expect('/result/nearestId', 'eq', nearestId, artifact: customerRef);
  if (nearest != null) {
    nativeRequire(
      nearest['status'] == 'pending',
      'Actual nearest summary must use the current eligible pending stop.',
    );
    await acceptanceSummaryKey(
      d,
      'summary-nearest-reference',
      entireField: true,
    );
    await _n7ReadingCapture(
      c,
      '$prefix-reference',
      scrollKey: 'large-summary-scroll',
      texts: {'summary-nearest-reference': nearest['reference'] as String},
      actions: ['summary-close'],
    );
    await acceptanceSummaryKey(
      d,
      'summary-nearest-distance',
      entireField: true,
    );
    await _n7ReadingCapture(
      c,
      '$prefix-distance',
      scrollKey: 'large-summary-scroll',
      readTextKeys: ['summary-nearest-distance'],
      actions: ['summary-close'],
    );
    final distance = await d.textKey('summary-nearest-distance');
    nativeRequire(
      RegExp(r'^\d+(?:\.\d)? (?:m|km) straight-line$').hasMatch(distance),
      'Nearest distance must expose its complete actual straight-line label.',
    );
    final exposed = await acceptanceSummaryKey(
      d,
      'nearest-stop',
      entireField: true,
    );
    _visible(exposed, 'nearest-stop');
    final nearestRef = await c.sample('$prefix-nearest-action', exposed);
    for (final field in ['width', 'height']) {
      await c.expect(
        '/bounds/nearest-stop/0/$field',
        'gte',
        44,
        artifact: nearestRef,
      );
    }
    await c.expect(
      '/bounds/nearest-stop/0/centerHit',
      'eq',
      true,
      artifact: nearestRef,
    );
  }
  await d.tapKey('summary-close');
  await d.waitForSnapshot(
    'actual summary Close restores the map',
    (s) =>
        acceptanceModel(s)['panel'] == 'map' &&
        nativeObject(s['bounds']).containsKey('map-summary-open') &&
        !nativeObject(s['bounds']).containsKey('large-summary-workspace'),
  );
  final returned = await _n7MapReadingCapture(c, '$prefix-closed');
  for (final pointer in [
    '/model/query',
    '/model/listSession',
    '/camera',
    '/outbox',
    '/persistedStops',
    '/persistedSettings',
  ]) {
    await c.expect(
      pointer,
      'eq',
      null,
      artifact: returned,
      rightArtifact: beforeRef,
      rightPointer: pointer,
    );
  }
}

Map<String, String> _n7ListTexts(
  Map<String, dynamic> snapshot,
  String reference,
) {
  final stop = acceptanceStop(snapshot, reference);
  final status = switch (stop['status']) {
    'pending' => 'Pending',
    'completed' => 'Completed',
    'failed' => 'Failed',
    _ => throw StateError('Unknown actual stop status.'),
  };
  final waiting = acceptanceOutbox(
    snapshot,
  ).any((update) => update['stopId'] == stop['id']);
  return {
    'list-customer-$reference': stop['customerName'] as String,
    'list-reference-$reference': reference,
    'list-status-$reference': '$status${waiting ? ' · Waiting to sync' : ''}',
  };
}

Future<Map<String, dynamic>> _closeListOriginFailure(
  NativeWorkbenchDriver d,
  String reference,
) async {
  final modalLayoutClock = Stopwatch()..start();
  Map<String, Object?>? previousModalLayout;
  Duration? modalLayoutQuietSince;
  await d.waitForSnapshot(
    'actual modal Close exposed and sheet stable for 500 milliseconds',
    (s) {
      final model = acceptanceModel(s);
      final media = nativeObject(s['mediaQuery']);
      final padding = nativeObject(media['viewPadding']);
      final bounds = nativeObject(s['bounds']);
      final width = media['width'];
      final height = media['height'];
      final rects = <String, Object?>{};
      var valid =
          model['panel'] == 'detail' &&
          model['selectedOrigin'] == 'list' &&
          nativeObject(model['selected'])['reference'] == reference &&
          width is num &&
          width.isFinite &&
          width > 0 &&
          height is num &&
          height.isFinite &&
          height > 0 &&
          ['left', 'top', 'right', 'bottom'].every(
            (field) =>
                padding[field] is num &&
                (padding[field] as num).isFinite &&
                (padding[field] as num) >= 0,
          );
      for (final key in ['failure-close', 'failure-sheet']) {
        final rows = bounds[key];
        if (rows is! List || rows.length != 1 || rows.single is! Map) {
          valid = false;
          break;
        }
        final rect = nativeObject(rows.single);
        if (['left', 'top', 'right', 'bottom', 'width', 'height'].any(
          (field) => rect[field] is! num || !(rect[field] as num).isFinite,
        )) {
          valid = false;
          break;
        }
        if (valid && key == 'failure-close') {
          valid =
              rect['centerHit'] == true &&
              (rect['width'] as num) >= 44 &&
              (rect['height'] as num) >= 44 &&
              (rect['left'] as num) >= (padding['left'] as num) - .5 &&
              (rect['right'] as num) <=
                  (width as num) - (padding['right'] as num) + .5 &&
              (rect['top'] as num) >= (padding['top'] as num) - .5 &&
              (rect['bottom'] as num) <=
                  (height as num) - (padding['bottom'] as num) + .5;
        }
        rects[key] = rect;
      }
      if (!valid) {
        previousModalLayout = null;
        modalLayoutQuietSince = null;
        return false;
      }
      final layout = <String, Object?>{
        'width': width,
        'height': height,
        'viewPadding': padding,
        'bounds': rects,
      };
      if (previousModalLayout == null ||
          !acceptanceEqual(previousModalLayout, layout)) {
        previousModalLayout = layout;
        modalLayoutQuietSince = modalLayoutClock.elapsed;
        return false;
      }
      return modalLayoutClock.elapsed - modalLayoutQuietSince! >=
          const Duration(milliseconds: 500);
    },
    timeout: NativeWorkbenchDriver.observationDeadline,
  );
  await d.tapKey('failure-close');
  return d.waitForSnapshot(
    'typed modal Close restores the same list-origin detail without sheet',
    (s) =>
        acceptanceIdle(s) &&
        acceptanceModel(s)['panel'] == 'detail' &&
        acceptanceModel(s)['selectedOrigin'] == 'list' &&
        nativeObject(acceptanceModel(s)['selected'])['reference'] ==
            reference &&
        !nativeObject(s['bounds']).containsKey('failure-sheet'),
    timeout: NativeWorkbenchDriver.observationDeadline,
  );
}

Future<void> _n7(NativeAcceptanceRecorder r) async {
  final d = r.client;
  await acceptanceOnline(d, false);
  await r.check(
    'N7.two-sizes-safearea',
    (c) async {
      await _openMapStop(d, 'TV-300002');
      final opened = await d.snapshot();
      if ((nativeObject(opened['mediaQuery'])['textScaleAt16'] as num) >= 2) {
        final media = nativeObject(opened['mediaQuery']);
        final padding = nativeObject(media['viewPadding']);
        final workspace = _n7UniqueRect(opened, 'large-text-task-workspace');
        final card = _n7UniqueRect(opened, 'delivery-detail-card');
        nativeRequire(
          ((workspace['left'] as num) - (padding['left'] as num)).abs() <= .5 &&
              ((workspace['right'] as num) -
                          ((media['width'] as num) - (padding['right'] as num)))
                      .abs() <=
                  .5 &&
              ((workspace['top'] as num) - (padding['top'] as num)).abs() <=
                  .5 &&
              ((workspace['bottom'] as num) -
                          ((media['height'] as num) -
                              (padding['bottom'] as num)))
                      .abs() <=
                  .5 &&
              ['left', 'top', 'right', 'bottom'].every(
                (edge) =>
                    ((card[edge] as num) - (workspace[edge] as num)).abs() <=
                    .5,
              ),
          'Large detail must use the real full SafeArea task workspace.',
        );
        final stop = acceptanceStop(opened, 'TV-300002');
        await _n7ReadingCapture(
          c,
          'large-detail',
          scrollKey: 'detail-scroll',
          texts: {
            'detail-customer': stop['customerName'] as String,
            'detail-reference': 'TV-300002',
          },
          actions: ['detail-close'],
        );
        // Map controls correctly remain Offstage during full-height detail.
        // Check their real geometry only after the user's typed map return.
        await d.tapKey('detail-close');
        final map = await d.waitForSnapshot(
          'large detail Close returns to the actual map and marker',
          (s) =>
              acceptanceModel(s)['panel'] == 'map' &&
              nativeObject(s['bounds']).containsKey('map-stop-TV-300002'),
        );
        for (final key in [
          'zoom-in',
          'zoom-out',
          'fit-stops',
          'locate-reference',
          'map-sync',
          'map-stop-TV-300002',
        ]) {
          _visible(map, key);
        }
        await c.sample('returned-map-geometry', map);
        c.metadata['geometry_mode'] = 'large full SafeArea detail then map';
        return;
      }
      final selected = await d.waitForSnapshot(
        'selected marker exposed beside actual native card',
        (s) {
          final bounds = nativeObject(s['bounds']);
          if (!bounds.containsKey('map-stop-TV-300002') ||
              !bounds.containsKey('delivery-detail-card')) {
            return false;
          }
          return !_intersects(
            _rect(s, 'map-stop-TV-300002'),
            _rect(s, 'delivery-detail-card'),
          );
        },
      );
      for (final key in [
        'zoom-in',
        'zoom-out',
        'fit-stops',
        'locate-reference',
        'map-sync',
        'detail-close',
      ]) {
        _visible(selected, key);
      }
      final marker = _rect(selected, 'map-stop-TV-300002');
      for (final key in [
        'delivery-detail-card',
        'zoom-in',
        'zoom-out',
        'fit-stops',
        'locate-reference',
        'map-sync',
        'map-attribution',
        'workbench-notice',
      ]) {
        if (nativeObject(selected['bounds']).containsKey(key)) {
          nativeRequire(
            !_intersects(marker, _rect(selected, key)),
            'Selected marker is obscured by $key.',
          );
        }
      }
      await c.sample('selected-geometry', selected);
    },
    (c) async {
      await c.expect('/mediaQuery/width', 'gte', 300);
      await c.expect('/mediaQuery/height', 'gte', 600);
      await c.expect('/bounds/map-stop-TV-300002/0/width', 'gte', 44);
      await c.expect('/bounds/map-stop-TV-300002/0/height', 'gte', 44);
      c.metadata['device_size'] = {
        'width': nativeObject(c.after['mediaQuery'])['width'],
        'height': nativeObject(c.after['mediaQuery'])['height'],
      };
    },
  );
  await acceptanceMap(d);
  await r.check(
    'N7.os-keyboard',
    (c) async {
      await acceptanceFailureOpen(d, 'TV-300004');
      await d.revealKey('failure-reason-recipient-unavailable');
      await d.tapKey('failure-reason-recipient-unavailable');
      await d.setTextEntryEmulation(enabled: false);
      await d.revealKey('failure-note');
      await d.tapKey('failure-note');
      await d.waitForSnapshot(
        'actual OS IME inset after fresh field focus',
        (s) =>
            (nativeObject(nativeObject(s['mediaQuery'])['viewInsets'])['bottom']
                as num) >
            0,
      );
      final keyboardLayoutClock = Stopwatch()..start();
      Map<String, Object?>? previousKeyboardLayout;
      Duration? keyboardLayoutQuietSince;
      await d.waitForSnapshot(
        'actual OS keyboard layout stable for 500 milliseconds',
        (s) {
          final media = nativeObject(s['mediaQuery']);
          final inset = nativeObject(media['viewInsets'])['bottom'];
          final bounds = nativeObject(s['bounds']);
          final rects = <String, Object?>{};
          var valid = inset is num && inset.isFinite && inset > 0;
          for (final key in ['failure-note', 'failure-save', 'failure-sheet']) {
            final rows = bounds[key];
            if (rows is! List || rows.length != 1 || rows.single is! Map) {
              valid = false;
              break;
            }
            final rect = nativeObject(rows.single);
            if (['left', 'top', 'right', 'bottom', 'width', 'height'].any(
              (field) => rect[field] is! num || !(rect[field] as num).isFinite,
            )) {
              valid = false;
              break;
            }
            rects[key] = rect;
          }
          if (!valid) {
            previousKeyboardLayout = null;
            keyboardLayoutQuietSince = null;
            return false;
          }
          final layout = <String, Object?>{
            'mediaQuery': media,
            'bounds': rects,
          };
          if (previousKeyboardLayout == null ||
              !acceptanceEqual(previousKeyboardLayout, layout)) {
            previousKeyboardLayout = layout;
            keyboardLayoutQuietSince = keyboardLayoutClock.elapsed;
            return false;
          }
          return keyboardLayoutClock.elapsed - keyboardLayoutQuietSince! >=
              const Duration(milliseconds: 500);
        },
        timeout: NativeWorkbenchDriver.observationDeadline,
      );
      await d.revealKey('failure-save', alignment: 1);
      final keyboard = await d.waitForSnapshot(
        'full Save exposed above actual OS keyboard',
        (s) {
          if ((nativeObject(
                    nativeObject(s['mediaQuery'])['viewInsets'],
                  )['bottom']
                  as num) <=
              0) {
            return false;
          }
          final rect = _rect(s, 'failure-save');
          final media = nativeObject(s['mediaQuery']);
          return rect['centerHit'] == true &&
              (rect['bottom'] as num) <=
                  (media['height'] as num) -
                      (nativeObject(media['viewInsets'])['bottom'] as num) +
                      .5;
        },
      );
      _visible(keyboard, 'failure-save', keyboard: true);
      final ref = await c.sample('os-keyboard', keyboard);
      c.metadata['keyboard_snapshot'] = ref;
      final capture = await d.captureNamed('${c.slug}-keyboard', keyboard);
      await c.evidence('keyboard-capture', capture);
      c.metadata['keyboard_capture'] = {
        'png': r.relative('${c.slug}-keyboard.png'),
        'sqlite': r.relative('${c.slug}-keyboard.sqlite'),
        'projection': r.relative('${c.slug}-keyboard.sqlite.json'),
        'journal': r.relative('${c.slug}-keyboard.journal.jsonl'),
      };
      await c.expect('/mediaQuery/viewInsets/bottom', 'gte', 1, artifact: ref);
      await c.expect('/bounds/failure-save/0/width', 'gte', 44, artifact: ref);
      await c.expect('/bounds/failure-save/0/height', 'gte', 44, artifact: ref);
      await c.expect(
        '/bounds/failure-save/0/centerHit',
        'eq',
        true,
        artifact: ref,
      );
      await d.tapKey('failure-save');
      await d.waitForSnapshot(
        'actual Save while OS IME visible commits',
        (s) =>
            acceptanceIdle(s) &&
            !nativeObject(s['bounds']).containsKey('failure-sheet') &&
            nativeObject(acceptanceModel(s)['selected'])['status'] == 'failed',
      );
      await d.setTextEntryEmulation(enabled: true);
    },
    (c) async {
      await c.expect('/model/selected/status', 'eq', 'failed');
      await c.expect('/model/selected/reason', 'eq', 'Recipient unavailable');
      await c.expect('/model/selected/note', 'eq', null);
      await c.expect('/outbox', 'length', 1);
    },
  );
  await acceptanceReturn(d);
  if (d.options.values['content-size'] ==
      'accessibility-extra-extra-extra-large') {
    await r.check(
      'N7.text-scale',
      (c) async {
        final initial = await d.snapshot();
        nativeRequire(
          (nativeObject(initial['mediaQuery'])['textScaleAt16'] as num) >= 2,
          'Actual system MediaQuery scale must be at least2x.',
        );
        await _mapSearch(d, '');
        await _n7MapReadingCapture(c, 'initial-map');
        nativeRequire(
          nativeObject((await d.snapshot())['result'])['nearestId'] != null,
          'Initial unfiltered map requires an actual eligible nearest stop.',
        );
        await _n7SummaryReading(c, 'initial-summary');
        await acceptanceList(d);
        c.metadata['first_page_browse_action_end'] = d.actionSequence;
        final list = await d.snapshot();
        final references = nativeObject(list['result'])['references'];
        nativeRequire(
          references is List && references.isNotEmpty,
          'Maximum text first page must have actual stop results.',
        );
        final firstReference = (references as List).first as String;
        // No reveal/scroll of a row precedes this first-page reading capture.
        final firstPage = await _n7ReadingCapture(
          c,
          'list-first-page',
          scrollKey: 'stop-list-scroll',
          texts: _n7ListTexts(list, firstReference),
          actions: ['list-query-controls', 'list-sync', 'close-list'],
          rowKey: 'stop-$firstReference',
        );
        await c.expect('/model/panel', 'eq', 'list', artifact: firstPage);
        await c.expect('/model/query/search', 'eq', '', artifact: firstPage);
        await c.expect('/model/query/status', 'eq', null, artifact: firstPage);
        await c.expect(
          '/model/query/waitingOnly',
          'eq',
          false,
          artifact: firstPage,
        );
        await c.expect(
          '/bounds/list-query-controls/0/isSelected',
          'eq',
          false,
          artifact: firstPage,
        );
        c.metadata['first_page_reference'] = firstReference;

        await acceptanceListQueryTools(d);
        await d.enterText('stop-search', 'TV-300005');
        await d.revealKey('filter-pending');
        await d.tapKey('filter-pending');
        final tools = await d.waitForSnapshot(
          'actual pending search selects one stop in query tools',
          (s) =>
              nativeObject(acceptanceModel(s)['query'])['search'] ==
                  'TV-300005' &&
              nativeObject(acceptanceModel(s)['query'])['status'] ==
                  'pending' &&
              nativeObject(s['result'])['matchedCount'] == 1,
        );
        final toolsRef = await c.sample('filtered-tools', tools);
        _visible(tools, 'list-query-controls');
        await d.tapKey('list-query-controls');
        final filtered = await d.waitForSnapshot(
          'actual query toggle returns to readable rows',
          (s) =>
              nativeObject(s['bounds']).containsKey('stop-TV-300005') &&
              _n7UniqueRect(s, 'list-query-controls')['isSelected'] == false,
        );
        final filteredRef = await _n7ReadingCapture(
          c,
          'list-filtered-page',
          scrollKey: 'stop-list-scroll',
          texts: _n7ListTexts(filtered, 'TV-300005'),
          actions: ['list-query-controls', 'list-sync', 'close-list'],
          rowKey: 'stop-TV-300005',
        );
        for (final pointer in ['/model/query', '/outbox', '/persistedStops']) {
          await c.expect(
            pointer,
            'eq',
            null,
            artifact: filteredRef,
            rightArtifact: toolsRef,
            rightPointer: pointer,
          );
        }
        await c.expect('/result/matchedCount', 'eq', 1, artifact: filteredRef);
        await c.expect(
          '/result/references/0',
          'eq',
          'TV-300005',
          artifact: filteredRef,
        );
        await d.tapKey('stop-TV-300005');
        final detail = await d.waitForSnapshot(
          'filtered row opens its actual list-origin detail',
          (s) =>
              acceptanceModel(s)['panel'] == 'detail' &&
              acceptanceModel(s)['selectedOrigin'] == 'list' &&
              nativeObject(acceptanceModel(s)['selected'])['reference'] ==
                  'TV-300005',
        );
        final stop = acceptanceStop(detail, 'TV-300005');
        c.metadata['list_origin'] = await c.sample('list-origin', detail);
        await _n7ReadingCapture(
          c,
          'detail-reading',
          scrollKey: 'detail-scroll',
          texts: {
            'detail-reference': 'TV-300005',
            'detail-customer': stop['customerName'] as String,
          },
          actions: ['detail-close'],
        );
        final address = (stop['address'] as String).split(',');
        final locality = address.skip(1).join(',').trim();
        await d.revealKey('detail-street', alignment: .25);
        await _n7ReadingCapture(
          c,
          'address-reading',
          scrollKey: 'detail-scroll',
          texts: {
            'detail-street': address.first.trim(),
            if (locality.isNotEmpty) 'detail-locality': locality,
          },
          actions: ['detail-close'],
        );
        await d.revealKey('detail-fail', alignment: 1);
        await _n7ReadingCapture(
          c,
          'detail-actions',
          scrollKey: 'detail-scroll',
          actions: ['detail-complete', 'detail-fail', 'detail-close'],
        );
        await d.tapKey('detail-fail');
        await d.waitForSnapshot(
          'actual readable detail opens failure form',
          (s) => nativeObject(s['bounds']).containsKey('failure-sheet'),
        );
        await d.revealKey('failure-reason-other');
        await d.tapKey('failure-reason-other');
        await d.enterText('failure-note', '  2x native Other reason  ');
        await d.revealKey('failure-save', alignment: 1);
        final form = await d.snapshot();
        _visible(form, 'failure-save', keyboard: true);
        await c.sample('large-form', form);
        await d.tapKey('failure-save');
        final saved = await d.waitForSnapshot(
          'large-text form actual save',
          (s) =>
              acceptanceIdle(s) &&
              !nativeObject(s['bounds']).containsKey('failure-sheet') &&
              nativeObject(acceptanceModel(s)['selected'])['status'] ==
                  'failed',
        );
        c.metadata['saved_result'] = await c.sample('saved-result', saved);
        await d.revealKey('detail-terminal-result', alignment: .25);
        await _n7ReadingCapture(
          c,
          'terminal-reading',
          scrollKey: 'detail-scroll',
          texts: {
            'detail-terminal-result': 'Delivery failed',
            'detail-terminal-reason': '2x native Other reason',
          },
          actions: ['detail-close'],
        );
        await d.revealKey('detail-recorded-time', alignment: .5);
        await _n7ReadingCapture(
          c,
          'recorded-reading',
          scrollKey: 'detail-scroll',
          readTextKeys: ['detail-recorded-time'],
          actions: ['detail-close'],
        );
        final recordedText = await d.textKey('detail-recorded-time');
        nativeRequire(
          RegExp(
                r'^Recorded at \d{4}-\d{2}-\d{2} \d{2}:\d{2}$',
              ).hasMatch(recordedText) &&
              nativeObject(acceptanceModel(saved)['selected'])['recordedAt']
                  is String,
          'Readable recorded time must accompany the actual persisted timestamp.',
        );
        await d.revealKey('detail-return', alignment: 1);
        c.metadata['saved_reading'] = await _n7ReadingCapture(
          c,
          'saved-reading',
          scrollKey: 'detail-scroll',
          texts: {'detail-saved': 'Saved locally. Waiting to sync.'},
          actions: ['detail-return', 'detail-close'],
        );
        await d.tapKey('detail-return');
        final returnedList = await d.waitForSnapshot(
          'terminal Return restores the same actual filtered list',
          (s) =>
              acceptanceModel(s)['panel'] == 'list' &&
              acceptanceModel(s)['selected'] == null &&
              nativeObject(
                    acceptanceModel(s)['listSession'],
                  )['focusedReference'] ==
                  'TV-300005',
        );
        c.metadata['list_return'] = await c.sample('list-return', returnedList);
        await acceptanceMap(d);
        await _n7MapReadingCapture(c, 'returned-map');
        // A real offline Sync creates fresh feedback after the saved-detail
        // reading sequence; the earlier transient save notice can expire.
        await d.tapKey('map-sync');
        await d.waitForSnapshot(
          'actual offline map sync feedback',
          (s) =>
              acceptanceIdle(s) &&
              acceptanceModel(s)['panel'] == 'map' &&
              nativeObject(acceptanceModel(s)['notice'])['message'] ==
                  'Offline · 2 saved updates waiting.' &&
              nativeObject(acceptanceModel(s)['notice'])['kind'] ==
                  'information' &&
              acceptanceOutbox(s).length == 2,
        );
        await _n7SummaryReading(c, 'returned-summary', feedback: true);
      },
      (c) async {
        await c.expect('/mediaQuery/textScaleAt16', 'gte', 2);
        final savedRef = c.metadata['saved_result'] as String;
        final listReturn = c.metadata['list_return'] as String;
        await c.expect(
          '/model/selected/reason',
          'eq',
          '2x native Other reason',
          artifact: savedRef,
        );
        await c.expect('/model/selected/note', 'eq', null, artifact: savedRef);
        await c.expect(
          '/model/selected/status',
          'eq',
          'failed',
          artifact: savedRef,
        );
        await c.expect('/model/panel', 'eq', 'list', artifact: listReturn);
        await c.expect('/model/panel', 'eq', 'map');
        await c.expect('/model/selected', 'eq', null);
        await c.expect('/result/matchedCount', 'eq', 0);
        await c.expect(
          '/model/listSession/focusedReference',
          'eq',
          'TV-300005',
          artifact: listReturn,
        );
        for (final pointer in [
          '/model/query',
          '/model/listSession/scrollOffset',
        ]) {
          await c.expect(
            pointer,
            'eq',
            null,
            artifact: listReturn,
            rightArtifact: c.metadata['list_origin'] as String,
            rightPointer: pointer,
          );
        }
        await c.expect('/outbox', 'length', 2);
        await c.expect(
          '/outbox/0',
          'eq',
          null,
          rightArtifact: c.beforePath!,
          rightPointer: '/outbox/0',
        );
        final stopIndex = nativeObjects(
          c.after['persistedStops'],
        ).indexWhere((stop) => stop['reference'] == 'TV-300005');
        nativeRequire(
          stopIndex >= 0,
          'Saved stop must exist in readonly SQL projection.',
        );
        for (final field in [
          'status',
          'reason',
          'note',
          'operationId',
          'recordedAt',
        ]) {
          await c.expect(
            '/persistedStops/$stopIndex/$field',
            'eq',
            null,
            rightArtifact: savedRef,
            rightPointer: '/model/selected/$field',
          );
          await c.expect(
            '/outbox/1/$field',
            'eq',
            null,
            rightArtifact: savedRef,
            rightPointer: '/model/selected/$field',
          );
        }
        await c.expect(
          '/outbox/1/stopId',
          'eq',
          null,
          rightArtifact: savedRef,
          rightPointer: '/model/selected/id',
        );
      },
    );
  } else {
    r.notApplicable(
      'N7.text-scale',
      'Normal-size OS job; separate actual accessibility text-size job must provide the >=2x proof.',
    );
  }
  if (d.options.values['reduce-motion'] == 'true') {
    await r.check(
      'N7.reduced-motion-semantics',
      (c) async {
        await acceptanceMap(d);
        await d.tapKey('zoom-in');
        final ref = await c.evidence('semantics-ui', {
          'zoomIn': await d.semanticsKey('zoom-in'),
          'sync': await d.semanticsKey('map-sync'),
          'browse': await d.semanticsKey('browse-stops'),
        });
        await c.expect('/zoomIn', 'gte', 0, artifact: ref);
        await c.expect('/sync', 'gte', 0, artifact: ref);
        await c.expect('/browse', 'gte', 0, artifact: ref);
      },
      (c) async {
        // iOS exposes Reduce Motion separately; retain the independent raw
        // MediaQuery flag rather than pretending UIKit sets disableAnimations.
        await c.expect('/platformAccessibility/platform', 'eq', 'ios');
        await c.expect('/platformAccessibility/reduceMotion', 'eq', true);
        await c.expect('/mediaQuery/disableAnimations', 'eq', false);
        await c.expect('/mapReady', 'eq', true);
      },
    );
  } else {
    r.notApplicable(
      'N7.reduced-motion-semantics',
      'Normal OS-motion job; separate actual iOS reduced-motion job must prove the platform Reduce Motion flag and native semantics, retaining raw disableAnimations independently.',
    );
  }
  await r.check(
    'N7.platform-back',
    (c) async {
      await acceptanceFailureOpen(d, 'TV-300006');
      final modal = await _closeListOriginFailure(d, 'TV-300006');
      await c.sample('modal-close', modal);
      nativeRequire(
        acceptanceModel(modal)['panel'] == 'detail' &&
            !nativeObject(modal['bounds']).containsKey('failure-sheet'),
        'Typed modal Close lost detail source.',
      );
      await acceptanceCloseDetail(d);
      final list = await d.snapshot();
      await c.sample('list-return', list);
      nativeRequire(
        acceptanceModel(list)['panel'] == 'list',
        'Pending detail Close failed list source.',
      );
      // The OS-keyboard case saved this stop. Use its genuine terminal Return
      // too, without recording a new result solely for a navigation test.
      await acceptanceOpenListStop(d, 'TV-300004');
      await acceptanceReturn(d);
      await c.sample('terminal-list-return', await d.snapshot());
      await acceptanceMap(d);
      await _openMapStop(d, 'TV-300006');
      await d.tapKey('detail-close');
      await d.waitForSnapshot(
        'typed map detail Close',
        (s) => acceptanceModel(s)['panel'] == 'map',
      );
      final mapRef = await c.sample(
        'map-typed-close',
        await acceptanceStableCapture(d),
      );
      await acceptanceNearest(d);
      final nearest = await d.waitForSnapshot(
        'actual nearest detail preserves its typed source and query target',
        (s) =>
            acceptanceModel(s)['panel'] == 'detail' &&
            acceptanceModel(s)['selectedOrigin'] == 'nearest' &&
            nativeObject(acceptanceModel(s)['selected'])['reference'] ==
                'TV-300006',
      );
      final nearestRef = await c.sample('nearest-typed-detail', nearest);
      await c.expect(
        '/model/selectedOrigin',
        'eq',
        'nearest',
        artifact: nearestRef,
      );
      await c.expect(
        '/model/selected/reference',
        'eq',
        'TV-300006',
        artifact: nearestRef,
      );
      await c.expect(
        '/model/query',
        'eq',
        null,
        artifact: nearestRef,
        rightArtifact: mapRef,
        rightPointer: '/model/query',
      );
      await d.tapKey('detail-close');
      await d.waitForSnapshot(
        'actual nearest Close restores the map',
        (s) =>
            acceptanceModel(s)['panel'] == 'map' &&
            acceptanceModel(s)['selected'] == null,
      );
      final nearestReturn = await c.sample(
        'nearest-typed-return',
        await acceptanceStableCapture(d),
      );
      await c.expect('/model/panel', 'eq', 'map', artifact: nearestReturn);
      await c.expect(
        '/model/query',
        'eq',
        null,
        artifact: nearestReturn,
        rightArtifact: mapRef,
        rightPointer: '/model/query',
      );
      // Nearest selection intentionally focuses its stop. Summary body Browse
      // starts a separate task and must preserve the resulting actual camera.
      final map = await d.snapshot();
      if ((nativeObject(map['mediaQuery'])['textScaleAt16'] as num) >= 2) {
        nativeRequire(
          nativeObject(map['bounds']).containsKey('map-summary-open') &&
              !nativeObject(
                map['bounds'],
              ).containsKey('large-summary-workspace'),
          'Maximum text must expose its actual closed-summary map entry.',
        );
        final browseBefore = await c.sample(
          'summary-browse-before',
          await acceptanceStableCapture(d),
        );
        final exposed = await acceptanceSummaryKey(
          d,
          'summary-browse-stops',
          entireField: true,
        );
        _visible(exposed, 'summary-browse-stops');
        final exposedRef = await c.sample('summary-browse-exposed', exposed);
        for (final field in ['width', 'height']) {
          await c.expect(
            '/bounds/summary-browse-stops/0/$field',
            'gte',
            44,
            artifact: exposedRef,
          );
        }
        await c.expect(
          '/bounds/summary-browse-stops/0/centerHit',
          'eq',
          true,
          artifact: exposedRef,
        );
        await d.tapKey('summary-browse-stops');
        final bodyList = await d.waitForSnapshot(
          'actual summary body Browse opens list',
          (s) =>
              acceptanceModel(s)['panel'] == 'list' &&
              acceptanceModel(s)['selected'] == null,
        );
        final listRef = await c.sample('summary-browse-list', bodyList);
        await c.expect('/model/panel', 'eq', 'list', artifact: listRef);
        await c.expect(
          '/model/query',
          'eq',
          null,
          artifact: listRef,
          rightArtifact: browseBefore,
          rightPointer: '/model/query',
        );
        await d.tapKey('close-list');
        await d.waitForSnapshot(
          'summary body Browse list Close returns map',
          (s) =>
              acceptanceModel(s)['panel'] == 'map' &&
              nativeObject(s['bounds']).containsKey('map-summary-open'),
        );
        final browseReturn = await c.sample(
          'summary-browse-return',
          await acceptanceStableCapture(d),
        );
        for (final pointer in [
          '/model/query',
          '/camera',
          '/persistedSettings',
          '/outbox',
          '/persistedStops',
        ]) {
          await c.expect(
            pointer,
            'eq',
            null,
            artifact: browseReturn,
            rightArtifact: browseBefore,
            rightPointer: pointer,
          );
        }
      } else {
        c.metadata['summary_body_browse'] =
            'not_applicable for normal actual OS text scale; normal overview Browse retained';
      }
      c.metadata['android_hardware_back'] = 'not_applicable on iOS';
    },
    (c) async {
      await c.expect('/model/panel', 'eq', 'map');
      await c.expect('/model/selected', 'eq', null);
      await c.same('/outbox');
    },
  );
}
