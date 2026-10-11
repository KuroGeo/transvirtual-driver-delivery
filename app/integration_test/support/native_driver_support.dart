import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:path/path.dart' as path;

import 'native_gesture_command.dart';

/// Shared external-driver support. Every app action uses FlutterDriver's
/// actual UI extension. requestData is used only for readonly observations.
/// This library starts no children and leaves inherited Harness lease FDs open.
class NativeDriverOptions {
  NativeDriverOptions._(this.values);
  final Map<String, String> values;

  factory NativeDriverOptions.parse(List<String> arguments) {
    const allowed = {
      'vm-service-url',
      'output',
      'phase',
      'candidate',
      'pid',
      'configuration',
      'fixture-url',
      'fixture-token',
      'session',
      'baseline',
      'fixture',
      'scenario',
      'cold-fixture',
      'migration-fault',
      'content-size',
      'reduce-motion',
      'initial-tiles',
    };
    final values = <String, String>{};
    for (var index = 0; index < arguments.length; index++) {
      final name = arguments[index];
      if (!name.startsWith('--')) {
        throw FormatException('Driver arguments require --name value pairs.');
      }
      final key = name.substring(2);
      if (!allowed.contains(key) || values.containsKey(key)) {
        throw FormatException('Unknown or duplicate driver option: $name');
      }
      if ((key == 'reduce-motion' || key == 'migration-fault') &&
          (index + 1 == arguments.length ||
              arguments[index + 1].startsWith('--'))) {
        values[key] = 'true';
      } else {
        if (index + 1 == arguments.length ||
            arguments[index + 1].startsWith('--')) {
          throw FormatException('Driver option --$key requires a value.');
        }
        values[key] = arguments[++index];
      }
    }
    final result = NativeDriverOptions._(values);
    const optional = {
      'baseline',
      'fixture',
      'scenario',
      'cold-fixture',
      'migration-fault',
      'content-size',
      'reduce-motion',
      'initial-tiles',
    };
    for (final key in allowed.difference(optional)) {
      result.required(key);
    }
    if (values['scenario'] != null &&
        !RegExp(r'^N[1-7]$').hasMatch(values['scenario']!)) {
      throw FormatException('Unknown independent acceptance scenario.');
    }
    const choices = {
      'cold-fixture': ['none', 'viewport-corrupt', 'viewport-nonfinite'],
      'migration-fault': ['false', 'true'],
      'content-size': ['large', 'accessibility-extra-extra-extra-large'],
      'reduce-motion': ['false', 'true'],
      'initial-tiles': ['normal', '503'],
    };
    for (final entry in choices.entries) {
      final value = values[entry.key];
      if (value != null && !entry.value.contains(value)) {
        throw FormatException('Invalid independent option --${entry.key}.');
      }
    }
    if (!['saved', 'recovered', 'confirmed'].contains(result.phase)) {
      throw FormatException('Unsupported tooling smoke phase.');
    }
    if (!['demo', 'local-client'].contains(result.configuration)) {
      throw FormatException('Unsupported native mode.');
    }
    final fixtureName = values['fixture'];
    if (fixtureName != null && fixtureName != 'legacy-v1-identity-seq') {
      throw FormatException('Unknown native prelaunch fixture.');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(result.candidate) ||
        !RegExp(r'^[a-zA-Z0-9_-]{16,128}$').hasMatch(result.session) ||
        result.processId <= 0) {
      throw FormatException('Invalid candidate, session or process identity.');
    }
    final fixture = result.fixtureUri;
    if (fixture.scheme != 'http' ||
        !['127.0.0.1', 'localhost', '::1'].contains(fixture.host) ||
        fixture.userInfo.isNotEmpty ||
        fixture.hasFragment ||
        fixture.hasQuery) {
      throw FormatException('Host fixture must use task loopback HTTP.');
    }
    return result;
  }

  String required(String key) {
    final value = values[key];
    if (value == null || value.isEmpty) {
      throw FormatException('Missing driver option --$key.');
    }
    return value;
  }

  String get phase => required('phase');
  String get candidate => required('candidate');
  String get session => required('session');
  String get configuration => required('configuration');
  int get processId => int.parse(required('pid'));
  Uri get fixtureUri => Uri.parse(required('fixture-url'));
  Directory get output => Directory(required('output'));
}

Map<String, dynamic> nativeObject(Object? value) =>
    Map<String, dynamic>.from(value as Map);

List<Map<String, dynamic>> nativeObjects(Object? value) =>
    (value as List).map(nativeObject).toList();

void nativeRequire(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class NativeWorkbenchDriver {
  NativeWorkbenchDriver._(this.options, this.driver, this.vmProcessId);
  final NativeDriverOptions options;
  final FlutterDriver driver;
  final int vmProcessId;
  static const actionDeadline = Duration(seconds: 8);
  static const observationDeadline = Duration(seconds: 15);
  int _actionSequence = 0;
  int get actionSequence => _actionSequence;

  static Future<NativeWorkbenchDriver> connect(
    NativeDriverOptions options,
  ) async {
    await options.output.create(recursive: true);
    // SDK connect does not apply its timeout argument to the VM connection;
    // bound the Future itself and fail the process on expiration.
    final driver = await FlutterDriver.connect(
      dartVmServiceUrl: options.required('vm-service-url'),
      logCommunicationToFile: false,
    ).timeout(const Duration(seconds: 12));
    try {
      final vm = await driver.serviceClient.getVM().timeout(actionDeadline);
      final vmPid = vm.pid;
      nativeRequire(
        vmPid != null && vmPid == options.processId,
        'Connected VM PID does not match the task simctl launch PID.',
      );
      final result = NativeWorkbenchDriver._(options, driver, vmPid!);
      await result.snapshot();
      return result;
    } catch (_) {
      await driver.close().timeout(actionDeadline);
      rethrow;
    }
  }

  Future<T> _action<T>(String name, Future<T> Function() operation) async {
    final sequence = ++_actionSequence;
    final clock = Stopwatch()..start();
    await _log({'sequence': sequence, 'action': name, 'stage': 'started'});
    try {
      final result = await operation().timeout(actionDeadline);
      await _log({
        'sequence': sequence,
        'action': name,
        'stage': 'completed',
        'elapsedMs': clock.elapsedMilliseconds,
        if (name.startsWith('text-probe:') ||
            name.startsWith('text-probe-label:') ||
            name.startsWith('semantics-probe:') ||
            name == 'tap:double-complete')
          'response': result,
      });
      return result;
    } catch (error) {
      await _log({
        'sequence': sequence,
        'action': name,
        'stage': 'failed',
        'elapsedMs': clock.elapsedMilliseconds,
        'error': error.toString(),
      });
      rethrow;
    }
  }

  Future<void> _log(Map<String, Object?> event) async {
    await File(path.join(options.output.path, 'actions.jsonl')).writeAsString(
      '${jsonEncode({...event, 'processId': options.processId, 'vmProcessId': vmProcessId, 'candidate': options.candidate, 'configuration': options.configuration, 'session': options.session, 'observedAt': DateTime.now().toUtc().toIso8601String()})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<Map<String, dynamic>> snapshot() => _action('snapshot', () async {
    final raw = await driver.requestData('snapshot', timeout: actionDeadline);
    final value = nativeObject(jsonDecode(raw));
    nativeRequire(
      value['schema'] == 1 &&
          value['processId'] == options.processId &&
          value['candidate'] == options.candidate &&
          value['configuration'] == options.configuration &&
          value['mode'] == options.configuration &&
          value['session'] == options.session,
      'Readonly snapshot belongs to another process/candidate/mode/session.',
    );
    final configSize = value['launchConfigByteLength'];
    final databasePath = value['databasePath'];
    nativeRequire(
      databasePath is String &&
          path.isAbsolute(databasePath) &&
          value['launchConfigSchema'] == 1 &&
          configSize is int &&
          configSize > 0 &&
          configSize <= 16384 &&
          value['launchConfigPath'] ==
              path.join(
                path.dirname(databasePath),
                'native-workbench-launch.json',
              ),
      'Readonly snapshot did not consume the fixed native launch file.',
    );
    await File(
      path.join(options.output.path, 'observations.jsonl'),
    ).writeAsString('$raw\n', mode: FileMode.append, flush: true);
    return value;
  });

  Future<Map<String, dynamic>> waitForSnapshot(
    String condition,
    bool Function(Map<String, dynamic>) predicate, {
    Duration timeout = observationDeadline,
  }) async {
    final clock = Stopwatch()..start();
    Map<String, dynamic>? last;
    while (clock.elapsed < timeout) {
      last = await snapshot().timeout(timeout - clock.elapsed);
      if (predicate(last)) return last;
      // Bounded polling of an explicit observed condition, not a readiness
      // substitute or random settling delay. Every sample remains journalled.
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < const Duration(milliseconds: 100)
            ? remaining
            : const Duration(milliseconds: 100),
      );
    }
    await writeJson('last-failed-snapshot.json', last);
    throw TimeoutException('Native condition did not complete: $condition');
  }

  Future<void> tapKey(String key) => _action('tap:$key', () {
    return driver.runUnsynchronized(() async {
      final finder = find.byValueKey(key);
      await driver.waitForTappable(finder, timeout: actionDeadline);
      await driver.tap(finder, timeout: actionDeadline);
    }, timeout: actionDeadline);
  });

  Future<void> revealKey(String key, {double alignment = .5}) =>
      _action('scroll-into-view:$key', () {
        return driver.runUnsynchronized(
          () => driver.scrollIntoView(
            find.byValueKey(key),
            alignment: alignment,
            timeout: actionDeadline,
          ),
          timeout: actionDeadline,
        );
      });

  Future<void> scrollKey(String key, double dy) =>
      _action('scroll:$key:$dy', () {
        return driver.runUnsynchronized(
          () => driver.scroll(
            find.byValueKey(key),
            0,
            dy,
            const Duration(milliseconds: 300),
            timeout: actionDeadline,
          ),
          timeout: actionDeadline,
        );
      });

  /// FlutterDriver text emulation changes the real TextField. It does not prove
  /// that a real OS keyboard is displayed; snapshots record actual viewInsets.
  Future<void> enterText(String key, String text) async {
    await revealKey(key);
    await tapKey(key);
    await _action('emulated-text:$key', () {
      return driver.runUnsynchronized(
        () => driver.enterText(text, timeout: actionDeadline),
        timeout: actionDeadline,
      );
    });
  }

  /// Actual UI close/back button, not a requestData navigation command. An
  /// independent OS-back acceptance case must supply its own platform action.
  Future<void> back(String closeKey) => tapKey(closeKey);

  Future<void> setTextEntryEmulation({required bool enabled}) =>
      _action('text-entry-emulation:$enabled', () {
        return driver.setTextEntryEmulation(
          enabled: enabled,
          timeout: actionDeadline,
        );
      });

  Future<String> textKey(String key) => _action('text-probe:$key', () {
    return driver.runUnsynchronized(
      () => driver.getText(find.byValueKey(key), timeout: actionDeadline),
      timeout: actionDeadline,
    );
  });

  Future<String> textLabel(String text) =>
      _action('text-probe-label:$text', () {
        return driver.runUnsynchronized(
          () => driver.getText(find.text(text), timeout: actionDeadline),
          timeout: actionDeadline,
        );
      });

  Future<int> semanticsKey(String key) =>
      _action('semantics-probe:$key', () async {
        await driver.setSemantics(true, timeout: actionDeadline);
        return driver.runUnsynchronized(
          () => driver.getSemanticsId(
            find.byValueKey(key),
            timeout: actionDeadline,
          ),
          timeout: actionDeadline,
        );
      });

  Future<Map<String, dynamic>> doubleComplete() =>
      _action('tap:double-complete', () {
        return driver.runUnsynchronized(
          () async =>
              nativeObject(await driver.sendCommand(const DoubleComplete())),
          timeout: actionDeadline,
        );
      });

  Future<Map<String, dynamic>> pinchMap({required bool outward}) =>
      _action('pinch-map:${outward ? 'out' : 'in'}', () {
        return driver.runUnsynchronized(
          () async => nativeObject(
            await driver.sendCommand(
              outward ? const MapPinchOut() : const MapPinchIn(),
            ),
          ),
          timeout: actionDeadline,
        );
      });

  /// Immutable per-check raw evidence. Does not replace the phase-final
  /// capture used by the existing X02 orchestration/identity guard.
  Future<Map<String, dynamic>> captureNamed(
    String name,
    Map<String, dynamic> observed,
  ) async {
    nativeRequire(
      RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(name),
      'Named capture must stay within the task phase.',
    );
    await writeJson('$name-snapshot.json', observed);
    final image = await _action('flutter-screenshot:$name', () {
      return driver.runUnsynchronized(
        () => driver.screenshot(),
        timeout: actionDeadline,
      );
    });
    final output = File(path.join(options.output.path, '$name-flutter.png'));
    nativeRequire(!await output.exists(), 'Named evidence is immutable.');
    await output.writeAsBytes(image, flush: true);
    final captured = await fixture('capture', body: {'name': name});
    await writeJson('$name-host-capture.json', captured);
    return captured;
  }

  /// Separate reusable native IME observation for independent E08. The real
  /// channel is restored BEFORE a fresh TextField focus. Success requires an
  /// actual inset, snapshot and host OS PNG, never the toggle flag itself.
  /// Caller closes this form/field before reopening for emulated text entry.
  Future<Map<String, dynamic>> observeOsKeyboard(String noteKey) async {
    await setTextEntryEmulation(enabled: false);
    await revealKey(noteKey);
    await tapKey(noteKey);
    final observed = await waitForSnapshot(
      'real OS keyboard inset',
      (snapshot) =>
          (nativeObject(
                nativeObject(snapshot['mediaQuery'])['viewInsets'],
              )['bottom']
              as num) >
          0,
      timeout: actionDeadline,
    );
    await writeJson('os-keyboard-snapshot.json', observed);
    await writeJson(
      'os-keyboard-host-capture.json',
      await fixture('capture', body: {'name': 'os-keyboard'}),
    );
    return observed;
  }

  Future<Map<String, dynamic>> fixture(
    String endpoint, {
    Map<String, Object?>? body,
  }) => _action('fixture:$endpoint', () async {
    nativeRequire(
      ['control', 'capture', 'state'].contains(endpoint),
      'Unknown controlled fixture endpoint.',
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      return await (() async {
        final uri = options.fixtureUri.resolve('/$endpoint');
        final request = body == null
            ? await client.getUrl(uri)
            : await client.postUrl(uri);
        request.headers.set('X-Ocean-Task', options.required('fixture-token'));
        if (body != null) {
          final bytes = utf8.encode(jsonEncode(body));
          request.headers.contentType = ContentType.json;
          request.contentLength = bytes.length;
          request.add(bytes);
        }
        final response = await request.close();
        final raw = await utf8.decoder.bind(response).join();
        nativeRequire(
          raw.length <= 4 * 1024 * 1024,
          'Fixture response too large.',
        );
        if (response.statusCode != HttpStatus.ok) {
          throw StateError(_fixtureError(response.statusCode, raw));
        }
        return nativeObject(jsonDecode(raw));
      })().timeout(const Duration(seconds: 7));
    } finally {
      client.close(force: true);
    }
  });

  String _fixtureError(int status, String raw) {
    var message = 'No JSON error message.';
    try {
      final value = jsonDecode(raw);
      if (value is Map<String, dynamic> && value['error'] is String) {
        final sanitized = (value['error'] as String)
            .replaceAll(options.required('fixture-token'), '[redacted]')
            .replaceAll(options.required('vm-service-url'), '[redacted]')
            .replaceAll(RegExp(r'(?:https?|wss?)://\S+'), '[redacted URL]')
            .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (sanitized.isNotEmpty) {
          message = sanitized.length <= 256
              ? sanitized
              : '${sanitized.substring(0, 256)}…';
        }
      }
    } on FormatException {
      message = 'Invalid JSON error response.';
    }
    return 'Fixture HTTP $status: $message';
  }

  Future<void> writeJson(String name, Object? value) async {
    nativeRequire(
      RegExp(r'^[a-z0-9-]+\.json$').hasMatch(name),
      'Evidence filename must stay within the phase output directory.',
    );
    await File(
      path.join(options.output.path, name),
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(value)}\n');
  }

  Future<void> capture(Map<String, dynamic> snapshot) async {
    await writeJson('snapshot.json', snapshot);
    final png = await _action('flutter-screenshot', driver.screenshot);
    await File(
      path.join(options.output.path, 'screenshot.png'),
    ).writeAsBytes(png);
    await writeJson(
      'host-capture.json',
      await fixture('capture', body: {'name': options.phase}),
    );
    await writeJson('fixture-state.json', await fixture('state'));
  }

  Future<void> close() => driver.close().timeout(actionDeadline);
}
