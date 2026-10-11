import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:ocean_delivery/app/ocean_delivery_app.dart';
import 'package:ocean_delivery/app/runtime_configuration.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/main.dart' as formal;
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'support/native_workbench_bridge.dart';
import 'support/f1_navigation_fixture.dart';
import 'support/native_gesture_extension.dart';

/// Private task entry. The host writes one immutable task-container launch
/// configuration before each OS launch. Public main never imports this file.
Future<void> main() async {
  final ready = Completer<NativeWorkbenchBridge>();
  // Driver binding must exist before the real sqflite platform path lookup.
  enableFlutterDriverExtension(
    commands: [
      DoubleCompleteExtension(),
      MapPinchOutExtension(),
      MapPinchInExtension(),
    ],
    handler: (command) async {
      if (command != 'snapshot') {
        throw UnsupportedError('Readonly bridge accepts only snapshot.');
      }
      // A VM connection may precede the async plugin/config lookup. Readonly
      // observation waits for real initialization; failures still time out.
      final current = await ready.future.timeout(const Duration(seconds: 5));
      return current.requestData(command);
    },
  );
  final directory = await getDatabasesPath().timeout(
    const Duration(seconds: 5),
  );
  final launch = await _LaunchConfiguration.read(
    directory,
  ).timeout(const Duration(seconds: 5));
  final mode = launch.mode;
  final candidate = launch.candidate;
  final session = launch.session;
  final syncUri = launch.syncUri;
  final journal = NativeWorkbenchJournal(
    file: File(path.join(directory, nativeJournalName)),
    candidate: candidate,
    configuration: mode.name,
    session: session,
  );
  journal.record({'source': 'instrumentation', 'stage': 'process_started'});
  final controller = DeliveryMapController();
  final bridge = NativeWorkbenchBridge(
    candidate: candidate,
    configuration: mode.name,
    session: session,
    transport: !mode.isDemo
        ? 'unavailable-local-client'
        : syncUri == null
        ? 'formal-demo-simulated'
        : 'controlled-http-simulated',
    databasePath: path.join(directory, mode.databaseName),
    launchConfigPath: launch.filePath,
    launchConfigBytes: launch.byteLength,
    mapController: controller,
    journal: journal,
  );
  ready.complete(bridge);
  final observer = bridge;
  runApp(
    OceanDeliveryApp(
      demo: mode.isDemo,
      mapController: controller,
      tileUrlTemplate: launch.tiles,
      navigationGateway: const ControlledNavigationGateway(),
      locationGateway: const ControlledLocationGateway(),
      onNavigationChanged: (navigation) => bridge.navigation = navigation,
      createViewModel: () async {
        final model = await formal.createLocalViewModel(
          configuration: mode,
          databaseDirectory: directory,
          transport: syncUri == null ? null : _ControlledTransport(syncUri),
          eventSink: journal.record,
        );
        observer.model = model;
        return model;
      },
    ),
  );
}

class _LaunchConfiguration {
  const _LaunchConfiguration({
    required this.mode,
    required this.candidate,
    required this.session,
    required this.tiles,
    required this.syncUri,
    required this.filePath,
    required this.byteLength,
  });

  final RuntimeConfiguration mode;
  final String candidate;
  final String session;
  final String tiles;
  final Uri? syncUri;
  final String filePath;
  final int byteLength;

  static Future<_LaunchConfiguration> read(String directory) async {
    final file = File(path.join(directory, 'native-workbench-launch.json'));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('Native launch configuration must be a regular file.');
    }
    final size = await file.length();
    if (size <= 0 || size > 16384) {
      throw FormatException(
        'Native launch configuration exceeds its byte bound.',
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != size) {
      throw StateError('Native launch configuration changed while being read.');
    }
    final raw = jsonDecode(utf8.decode(bytes));
    const fields = {
      'schema',
      'mode',
      'candidate',
      'session',
      'tileUrl',
      'syncUrl',
    };
    if (raw is! Map<String, dynamic> ||
        raw.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(raw.keys.toSet()).isNotEmpty ||
        raw['schema'] is! int ||
        raw['schema'] != 1) {
      throw FormatException(
        'Native launch configuration requires exact schema1.',
      );
    }
    String field(String name) {
      final value = raw[name];
      if (value is! String || value.isEmpty) {
        throw FormatException('Native launch configuration requires $name.');
      }
      return value;
    }

    final name = field('mode');
    if (!['demo', 'local-client'].contains(name)) {
      throw FormatException('Unsupported native launch mode.');
    }
    final mode = RuntimeConfiguration.parse(name);
    if (RuntimeConfiguration.environment.name != mode.name) {
      throw StateError(
        'Native launch mode does not match compiled OCEAN_MODE.',
      );
    }
    final candidate = field('candidate');
    final session = field('session');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(candidate) ||
        !RegExp(r'^[a-zA-Z0-9_-]{16,128}$').hasMatch(session)) {
      throw FormatException('Invalid native source/session identity.');
    }
    final tiles = field('tileUrl');
    _loopback(tiles.replaceAll(RegExp(r'\{[zxy]\}'), '0'));
    if (!['{z}', '{x}', '{y}'].every(tiles.contains)) {
      throw FormatException(
        'Native tiles require a controlled z/x/y template.',
      );
    }
    final sync = raw['syncUrl'];
    if (!mode.isDemo && sync != null) {
      throw StateError('Local-client must use default unavailable transport.');
    }
    if (sync != null && (sync is! String || sync.isEmpty)) {
      throw FormatException('Native sync URL must be a string or null.');
    }
    return _LaunchConfiguration(
      mode: mode,
      candidate: candidate,
      session: session,
      tiles: tiles,
      syncUri: sync == null ? null : _loopback(sync as String),
      filePath: file.path,
      byteLength: bytes.length,
    );
  }
}

Uri _loopback(String value) {
  final uri = Uri.parse(value);
  if (uri.scheme != 'http' ||
      !['127.0.0.1', 'localhost', '::1'].contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw FormatException('Native fixture URL must be loopback HTTP.');
  }
  return uri;
}

class _ControlledTransport implements SyncTransport {
  const _ControlledTransport(this.uri);
  final Uri uri;

  @override
  Future<Ack> send(PendingUpdate update) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      // The formal coordinator still owns its real five-second timeout. The
      // later socket bound only cleans up an unresponsive fixture connection.
      return await _send(client, update).timeout(const Duration(seconds: 10));
    } finally {
      client.close(force: true);
    }
  }

  Future<Ack> _send(HttpClient client, PendingUpdate update) async {
    final request = await client.postUrl(uri);
    final bytes = utf8.encode(jsonEncode(nativeUpdate(update)));
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Controlled sync HTTP ${response.statusCode}.');
    }
    final payload = await utf8.decoder.bind(response).join();
    if (payload.length > 16384) throw FormatException('Fixture ACK too large.');
    final value = jsonDecode(payload) as Map<String, dynamic>;
    String identity(String key) {
      final field = value[key];
      if (field is! String || field.isEmpty) {
        throw FormatException('Fixture ACK missing $key.');
      }
      return field;
    }

    return Ack(
      operationId: identity('operationId'),
      datasetId: identity('datasetId'),
      stopId: identity('stopId'),
    );
  }
}
