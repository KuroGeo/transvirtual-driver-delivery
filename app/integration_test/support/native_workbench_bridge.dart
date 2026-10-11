import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/models/workbench.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery_screen.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';
import 'package:ocean_delivery/ui/navigation/navigation_view_model.dart';

const nativeJournalName = 'native-workbench-journal.jsonl';

Map<String, Object?> nativeStop(Stop stop) => {
  'id': stop.id,
  'reference': stop.reference,
  'customerName': stop.customerName,
  'address': stop.address,
  'latitude': stop.latitude,
  'longitude': stop.longitude,
  'status': stop.status.name,
  'timeWindow': stop.timeWindow,
  'reason': stop.reason,
  'note': stop.note,
  'operationId': stop.operationId,
  'recordedAt': stop.recordedAt?.toUtc().toIso8601String(),
  'acknowledgedAt': stop.acknowledgedAt?.toUtc().toIso8601String(),
};

Map<String, Object?> nativeUpdate(PendingUpdate update) => {
  'seq': update.seq,
  'operationId': update.operationId,
  'datasetId': update.datasetId,
  'stopId': update.stopId,
  'status': update.status.name,
  'reason': update.reason,
  'note': update.note,
  'recordedAt': update.recordedAt?.toUtc().toIso8601String(),
};

Map<String, Object?>? _viewport(MapViewport? viewport) => viewport == null
    ? null
    : {
        'datasetId': viewport.datasetId,
        'latitude': viewport.latitude,
        'longitude': viewport.longitude,
        'zoom': viewport.zoom,
      };

Map<String, Object?>? _settings(DeliverySettings? settings) => settings == null
    ? null
    : {
        'datasetId': settings.datasetId,
        'online': settings.online,
        'viewport': _viewport(settings.viewport),
      };

/// An actual event journal in the task app's native database directory. The
/// observer never participates in a business transaction. Observation fails if
/// writing failed, rather than presenting missing events as successful evidence.
class NativeWorkbenchJournal {
  NativeWorkbenchJournal({
    required this.file,
    required this.candidate,
    required this.configuration,
    required this.session,
  });

  final File file;
  final String candidate;
  final String configuration;
  final String session;
  Object? _writeError;
  int _sequence = 0;

  void record(Map<String, Object?> event) {
    try {
      file.writeAsStringSync(
        '${jsonEncode({...event, 'processId': pid, 'candidate': candidate, 'configuration': configuration, 'session': session, 'sequence': ++_sequence, 'observedAt': DateTime.now().toUtc().toIso8601String()})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (error) {
      _writeError = error;
    }
  }

  Future<List<Object?>> read() async {
    if (_writeError != null) {
      throw StateError('Native journal write failed: $_writeError');
    }
    if (!await file.exists()) throw StateError('Native journal is missing.');
    if (await file.length() > 4 * 1024 * 1024) {
      throw StateError('Native journal exceeded the bounded snapshot size.');
    }
    final lines = await file.readAsLines();
    return lines.map<Object?>((line) => jsonDecode(line)).toList();
  }
}

/// The only requestData command is an observation. No UI, query, online,
/// submission, synchronization or navigation mutation is exposed here.
class NativeWorkbenchBridge {
  NativeWorkbenchBridge({
    required this.candidate,
    required this.configuration,
    required this.session,
    required this.transport,
    required this.databasePath,
    required this.launchConfigPath,
    required this.launchConfigBytes,
    required this.mapController,
    required this.journal,
  });

  final String candidate;
  final String configuration;
  final String session;
  final String transport;
  final String databasePath;
  final String launchConfigPath;
  final int launchConfigBytes;
  final DeliveryMapController mapController;
  final NativeWorkbenchJournal journal;
  DeliveryViewModel? model;
  NavigationViewModel? navigation;

  Future<String> requestData(String? command) async {
    if (command != 'snapshot') {
      throw UnsupportedError('Readonly bridge accepts only snapshot.');
    }
    return jsonEncode(await _snapshot().timeout(const Duration(seconds: 5)));
  }

  Future<Map<String, Object?>> _snapshot() async {
    // End-of-frame observation gives bounds from a completed layout without
    // waiting for perpetual animations or changing the user's state.
    await WidgetsBinding.instance.endOfFrame;
    final current = model;
    final ready =
        current != null &&
        !current.isLoading &&
        current.settings != null &&
        current.stops.isNotEmpty;
    final outbox = ready ? await current.repository.pendingUpdates() : null;
    final persistedSettings = ready
        ? await current.settingsStore?.loadSettings()
        : null;
    final persistedStops = ready ? await current.repository.loadStops() : null;
    final tree = _observeTree();
    final progress = current?.syncProgress.value;
    final notice = current?.notice.value;
    final selected = current?.selectedStop;
    final accessibility =
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
    return {
      'schema': 1,
      'processId': pid,
      'candidate': candidate,
      'configuration': configuration,
      'session': session,
      'mode': configuration,
      'transport': transport,
      'databasePath': databasePath,
      'launchConfigPath': launchConfigPath,
      'launchConfigByteLength': launchConfigBytes,
      'launchConfigSchema': 1,
      'observedAt': DateTime.now().toUtc().toIso8601String(),
      'platformAccessibility': {
        'platform': Platform.operatingSystem,
        'reduceMotion': accessibility.reduceMotion,
        'disableAnimations': accessibility.disableAnimations,
      },
      'model': current == null
          ? null
          : {
              'initialized': ready,
              'isLoading': current.isLoading,
              'isSaving': current.isSaving,
              'isSyncing': current.isSyncing,
              'isChangingOnline': current.isChangingOnline,
              'canRecord': current.canRecord,
              'loadError': current.loadError,
              'saveError': current.saveError,
              'settingsError': current.settingsError,
              'online': current.online,
              'queueCount': current.queueCount,
              'pendingCount': current.pendingCount,
              'panel': current.panel.name,
              'query': {
                'search': current.query.search,
                'status': current.query.status?.name,
                'waitingOnly': current.query.waitingOnly,
              },
              'settings': _settings(current.settings),
              'selected': selected == null ? null : nativeStop(selected),
              'selectedOrigin': current.detailContext?.origin.name,
              'hasUnrefreshedSelection':
                  selected != null && current.hasUnrefreshedResult(selected.id),
              'listSession': {
                'scrollOffset': current.listSession.scrollOffset,
                'focusedReference': current.listSession.focusedReference,
              },
              'syncProgress': progress == null
                  ? null
                  : {
                      'stage': progress.stage.name,
                      'runId': progress.runId,
                      'confirmedCount': progress.confirmedCount,
                      'operationId': progress.operationId,
                      'error': progress.error?.toString(),
                    },
              'notice': notice == null
                  ? null
                  : {
                      'id': notice.id,
                      'kind': notice.kind.name,
                      'message': notice.message,
                      'persistent': notice.persistent,
                    },
            },
      'navigation': navigation == null
          ? null
          : {
              'previewStatus': navigation!.routeStatus.name,
              'handoffStatus': navigation!.handoffStatus.name,
              'locationStatus': navigation!.locationStatus.name,
              'targetStopId': navigation!.target.stopId,
              'inputRevision': navigation!.inputRevision,
              'isValid': navigation!.isValid,
              'gatewaySource': 'controlled-navigation-fixture',
              'routeProvider': navigation!.route?.provider,
              'sessionGeneration': navigation!.scope.sessionGeneration,
            },
      'stops': current?.stops.map(nativeStop).toList(),
      'result': current == null
          ? null
          : {
              'stopIds': current.result.stops.map((stop) => stop.id).toList(),
              'references': current.result.stops
                  .map((stop) => stop.reference)
                  .toList(),
              'matchedCount': current.result.matchedCount,
              'totalQueueCount': current.result.totalQueueCount,
              'nearestId': current.result.nearest?.id,
            },
      'outbox': outbox?.map(nativeUpdate).toList(),
      'persistedStops': persistedStops?.map(nativeStop).toList(),
      'persistedSettings': _settings(persistedSettings),
      'camera': mapController.isReady
          ? {
              'latitude': mapController.mapController.camera.center.latitude,
              'longitude': mapController.mapController.camera.center.longitude,
              'zoom': mapController.mapController.camera.zoom,
              'rotation': mapController.mapController.camera.rotation,
            }
          : null,
      'mapReady': mapController.isReady,
      'tileStatus': mapController.tileStatus.value.name,
      ...tree,
      'journal': {
        'path': journal.file.path,
        'currentSession': session,
        'events': await journal.read(),
      },
      'textEntryEvidence': 'flutter-driver-emulated; not OS keyboard evidence',
    };
  }

  Map<String, Object?> _observeTree() {
    final bounds = <String, List<Map<String, Object?>>>{};
    BuildContext? screen;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Offstage && widget.offstage) return;
      if (widget is DeliveryScreen) screen = element;
      final key = widget.key;
      if (key is ValueKey<String>) {
        final render = element.findRenderObject();
        if (render is RenderBox && render.attached && render.hasSize) {
          final rect = render.localToGlobal(Offset.zero) & render.size;
          final hits = HitTestResult();
          WidgetsBinding.instance.hitTestInView(
            hits,
            rect.center,
            View.of(element).viewId,
          );
          bounds.putIfAbsent(key.value, () => []).add({
            'left': rect.left,
            'top': rect.top,
            'right': rect.right,
            'bottom': rect.bottom,
            // Global edge subtraction can lose precision at fractional
            // offsets; the layout size retains the actual target dimensions.
            'width': render.size.width,
            'height': render.size.height,
            'centerHit': hits.path.any((hit) => identical(hit.target, render)),
            if (widget is IconButton) 'isSelected': widget.isSelected,
          });
        }
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    final context = screen;
    final media = context == null ? null : MediaQuery.maybeOf(context);
    Map<String, Object?> insets(EdgeInsets value) => {
      'left': value.left,
      'top': value.top,
      'right': value.right,
      'bottom': value.bottom,
    };
    return {
      'mediaQuery': media == null
          ? null
          : {
              'width': media.size.width,
              'height': media.size.height,
              'devicePixelRatio': media.devicePixelRatio,
              'textScaleAt16': media.textScaler.scale(16) / 16,
              'padding': insets(media.padding),
              'viewPadding': insets(media.viewPadding),
              'viewInsets': insets(media.viewInsets),
              'disableAnimations': media.disableAnimations,
              'accessibleNavigation': media.accessibleNavigation,
              'boldText': media.boldText,
            },
      'bounds': bounds,
      'focusedWidget': FocusManager.instance.primaryFocus?.debugLabel,
    };
  }
}
