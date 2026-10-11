import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/routes/route_repository.dart';
import 'package:ocean_delivery/data/routes/third_party_route_port.dart';
import 'package:ocean_delivery/models/route.dart';
import 'package:ocean_delivery/platform/location/location_gateway.dart';
import 'package:ocean_delivery/platform/navigation/navigation_gateway.dart';
import 'package:ocean_delivery/platform/navigation/url_navigation_gateway.dart';
import 'package:ocean_delivery/ui/navigation/navigation_view_model.dart';
import 'package:url_launcher/url_launcher.dart';

const _scope = NavigationScope(
  workspaceId: 'private-workspace',
  principalId: 'private-driver',
  sessionGeneration: 7,
  datasetId: 'private-dataset',
);
const _target = NavigationTarget(
  stopId: 'private-stop',
  coordinate: RouteCoordinate(-33.884, 151.212),
  label: 'Private recipient label',
  address: 'Private customer address',
);
const _startA = RouteCoordinate(-33.897, 151.192);
const _startB = RouteCoordinate(-33.901, 151.184);
final _time = DateTime.utc(2026, 10, 12, 9);

void main() {
  test(
    'scope invalidation rejects delayed location and launch receipts',
    () async {
      final fix = Completer<LocationResult>();
      final receipt = Completer<HandoffStatus>();
      var current = true;
      final locationVm = _vm(
        current: () => current,
        location: _Location(() => fix.future),
      );
      final pendingLocation = locationVm.useMyLocation();
      current = false;
      fix.complete(LocationResult.ready(_deviceOrigin(_time)));
      await pendingLocation;
      expect(locationVm.locationStatus, LocationStatus.invalidated);
      expect(locationVm.origin, isNull);
      expect(locationVm.route, isNull);
      current = true;
      await locationVm.launch(NavigationApp.browserMap);
      expect(locationVm.handoffStatus, HandoffStatus.invalidated);

      final gateway = _Gateway(() => receipt.future);
      final launchVm = _vm(gateway: gateway);
      final launching = launchVm.launch(NavigationApp.browserMap);
      launchVm.markBackgrounded();
      launchVm.resume();
      launchVm.invalidate();
      receipt.complete(HandoffStatus.handoffRequested);
      await launching;
      expect(launchVm.handoffStatus, HandoffStatus.invalidated);
      expect(launchVm.isValid, isFalse);
    },
  );

  test(
    'manual start revision wins over older road reply and availability',
    () async {
      final port = _RoadPort();
      final availability = Completer<bool>();
      final availabilityStarted = Completer<void>();
      var actualLaunches = 0;
      final gateway = UrlNavigationGateway(
        platform: TargetPlatform.iOS,
        supportsMode: (_) async => true,
        canLaunch: (_) {
          availabilityStarted.complete();
          return availability.future;
        },
        launchUrl: (_, _) async {
          actualLaunches++;
          return true;
        },
      );
      final vm = _vm(port: port, gateway: gateway);
      final a = vm.confirmManualStart(_startA);
      await port.arrived(1);
      final launch = vm.launch(NavigationApp.appleMaps);
      await availabilityStarted.future;
      final b = vm.confirmManualStart(_startB);
      await port.arrived(2);
      port.reply(1, _road(port.requests[1]));
      await b;
      expect(vm.route!.origin, _startB);
      port.reply(0, _road(port.requests[0]));
      availability.complete(true);
      await Future.wait([a, launch]);
      expect(vm.origin!.coordinate, _startB);
      expect(vm.route!.origin, _startB);
      expect(vm.handoffStatus, HandoffStatus.idle);
      expect(actualLaunches, 0);
    },
  );

  test(
    'origin aging during road request and before launch degrades safely',
    () async {
      var now = _time;
      final port = _RoadPort();
      final observedOrigins = <RouteCoordinate?>[];
      final gateway = _Gateway(
        () async => HandoffStatus.handoffRequested,
        origins: observedOrigins,
      );
      final vm = _vm(
        port: port,
        clock: () => now,
        location: _Location(
          () async => LocationResult.ready(_deviceOrigin(now)),
        ),
        gateway: gateway,
      );
      final pending = vm.useMyLocation();
      await port.arrived(1);
      now = now.add(const Duration(minutes: 2, milliseconds: 1));
      port.reply(0, _road(port.requests[0]));
      await pending;
      expect(vm.routeStatus, RoutePreviewStatus.failed);
      expect(vm.routeFailure, RouteFailure.staleOrigin);
      expect(vm.route, isNull);
      await vm.launch(NavigationApp.browserMap);
      expect(vm.locationStatus, LocationStatus.stale);
      expect(observedOrigins.single, isNull);
      expect(vm.handoffStatus, HandoffStatus.handoffRequested);
    },
  );

  test(
    'unconfigured roads and provider failure retain explicit Maps handoff',
    () async {
      final unavailable = _vm();
      await unavailable.requestPreview();
      expect(unavailable.routeStatus, RoutePreviewStatus.unavailable);
      expect(unavailable.route, isNull);
      await unavailable.launch(NavigationApp.browserMap);
      expect(unavailable.handoffStatus, HandoffStatus.handoffRequested);

      final port = _RoadPort();
      final vm = _vm(port: port);
      final pending = vm.confirmManualStart(_startA);
      await port.arrived(1);
      port.replies.single.completeError(
        StateError('Independent supplier failure'),
      );
      await pending;
      expect(vm.routeStatus, RoutePreviewStatus.failed);
      expect(vm.routeFailure, RouteFailure.providerFailure);
      expect(vm.route, isNull);
      await vm.launch(NavigationApp.browserMap);
      expect(vm.handoffStatus, HandoffStatus.handoffRequested);
    },
  );

  test(
    'supplier configuration changes and impossible arrival reject road results',
    () async {
      final port = _RoadPort();
      final vm = _vm(port: port);
      final pending = vm.confirmManualStart(_startA);
      await port.arrived(1);
      port.configRevision = 'rotated-during-request';
      port.reply(0, _road(port.requests[0], config: port.configRevision));
      await pending;
      expect(vm.routeFailure, RouteFailure.configMismatch);
      expect(vm.route, isNull);

      final retry = vm.requestPreview();
      await port.arrived(2);
      port.reply(
        1,
        _road(
          port.requests[1],
          config: port.configRevision,
          arrivalOffset: const Duration(seconds: 1),
        ),
      );
      await retry;
      expect(vm.routeFailure, RouteFailure.invalidResponse);
      expect(vm.route, isNull);
    },
  );

  test(
    'third party and map boundary contain only route coordinates and mode',
    () async {
      final port = _RoadPort();
      final uris = <Uri>[];
      final modes = <LaunchMode>[];
      final gateway = UrlNavigationGateway(
        platform: TargetPlatform.iOS,
        supportsMode: (_) async => true,
        canLaunch: (_) async => true,
        launchUrl: (uri, mode) async {
          uris.add(uri);
          modes.add(mode);
          return true;
        },
      );
      final vm = _vm(port: port, gateway: gateway);
      final pending = vm.confirmManualStart(_startA);
      await port.arrived(1);
      final thirdParty = port.requests.single;
      expect(thirdParty.origin, _startA);
      expect(thirdParty.destination, _target.coordinate);
      expect(thirdParty.departureAt, _time);
      expect(thirdParty.mode, RouteTravelMode.driving);
      port.reply(0, _road(thirdParty));
      await pending;
      for (final app in NavigationApp.values) {
        await vm.launch(app);
      }
      expect(uris, hasLength(3));
      expect(uris[0].queryParameters, {
        'daddr': _target.coordinate.uriValue,
        'dirflg': 'd',
        'saddr': _startA.uriValue,
      });
      expect(uris[1].queryParameters, {
        'daddr': _target.coordinate.uriValue,
        'directionsmode': 'driving',
        'saddr': _startA.uriValue,
      });
      expect(uris[2].host, 'www.google.com');
      expect(uris[2].queryParameters, {
        'api': '1',
        'destination': _target.coordinate.uriValue,
        'origin': _startA.uriValue,
        'travelmode': 'driving',
      });
      expect(modes.last, LaunchMode.inAppBrowserView);
      for (final uri in uris) {
        for (final privateValue in [
          _scope.workspaceId,
          _scope.principalId,
          _scope.datasetId,
          _target.stopId,
          _target.label,
          _target.address,
        ]) {
          expect(uri.toString(), isNot(contains(privateValue)));
        }
      }
    },
  );

  test('platform availability and launch failure remain distinct', () async {
    var installed = false;
    var launches = 0;
    var supported = true;
    final gateway = UrlNavigationGateway(
      platform: TargetPlatform.iOS,
      supportsMode: (_) async => supported,
      canLaunch: (_) async => installed,
      launchUrl: (_, _) async {
        launches++;
        return false;
      },
    );
    final vm = _vm(gateway: gateway);
    await vm.launch(NavigationApp.googleMaps);
    expect(vm.handoffStatus, HandoffStatus.unavailable);
    expect(launches, 0);
    installed = true;
    await vm.launch(NavigationApp.googleMaps);
    expect(vm.handoffStatus, HandoffStatus.launchFailed);
    expect(launches, 1);
    supported = false;
    await vm.launch(NavigationApp.browserMap);
    expect(vm.handoffStatus, HandoffStatus.unavailable);
    expect(launches, 1);
  });

  test(
    'return requires successful handoff and observed background resume',
    () async {
      final receipt = Completer<HandoffStatus>();
      final vm = _vm(gateway: _Gateway(() => receipt.future));
      final pending = vm.launch(NavigationApp.browserMap);
      vm.resume();
      receipt.complete(HandoffStatus.handoffRequested);
      await pending;
      expect(vm.handoffStatus, HandoffStatus.handoffRequested);
      vm.resume();
      expect(vm.handoffStatus, HandoffStatus.handoffRequested);
      vm.markBackgrounded();
      vm.resume();
      expect(vm.handoffStatus, HandoffStatus.returned);

      final failure = Completer<HandoffStatus>();
      final failedVm = _vm(gateway: _Gateway(() => failure.future));
      final failedLaunch = failedVm.launch(NavigationApp.browserMap);
      failedVm.markBackgrounded();
      failedVm.resume();
      failure.complete(HandoffStatus.launchFailed);
      await failedLaunch;
      expect(failedVm.handoffStatus, HandoffStatus.launchFailed);

      final raced = Completer<HandoffStatus>();
      final racedVm = _vm(gateway: _Gateway(() => raced.future));
      final racedLaunch = racedVm.launch(NavigationApp.browserMap);
      racedVm.markBackgrounded();
      racedVm.resume();
      raced.complete(HandoffStatus.handoffRequested);
      await racedLaunch;
      expect(racedVm.handoffStatus, HandoffStatus.returned);
    },
  );
}

RouteOrigin _deviceOrigin(DateTime observedAt) => RouteOrigin(
  coordinate: _startA,
  observedAt: observedAt,
  accuracyMeters: 20,
  source: OriginSource.device,
);

NavigationViewModel _vm({
  _RoadPort? port,
  bool Function()? current,
  DateTime Function()? clock,
  LocationGateway? location,
  NavigationGateway? gateway,
}) {
  final now = clock ?? () => _time;
  final model = NavigationViewModel(
    scope: _scope,
    target: _target,
    isCurrent: current ?? () => true,
    location:
        location ??
        _Location(
          () async =>
              const LocationResult.failure(LocationStatus.permissionDenied),
        ),
    gateway: gateway ?? _Gateway(() async => HandoffStatus.handoffRequested),
    routes: RouteRepository(
      port: port ?? const UnavailableThirdPartyRoutePort(),
      clock: now,
    ),
    clock: now,
  );
  addTearDown(model.dispose);
  return model;
}

RouteResult _road(
  ThirdPartyRouteRequest request, {
  String config = 'independent-fixture-v1',
  Duration arrivalOffset = Duration.zero,
}) => RouteResult(
  origin: request.origin,
  destination: request.destination,
  provider: 'independent-held-road-fixture',
  configRevision: config,
  computedAt: request.departureAt,
  expiresAt: request.departureAt.add(const Duration(minutes: 10)),
  departureAt: request.departureAt,
  arrivalAt: request.departureAt
      .add(const Duration(minutes: 3))
      .add(arrivalOffset),
  distanceMeters: 2700,
  duration: const Duration(minutes: 3),
  geometry: [request.origin, request.destination],
  durationBasis: RouteDurationBasis.staticRoad,
);

class _RoadPort implements ThirdPartyRoutePort {
  @override
  bool isConfigured = true;
  @override
  String get provider => 'independent-held-road-fixture';
  @override
  String configRevision = 'independent-fixture-v1';
  final requests = <ThirdPartyRouteRequest>[];
  final replies = <Completer<ThirdPartyRouteResponse>>[];
  final _arrivals = <int, Completer<void>>{};

  @override
  Future<ThirdPartyRouteResponse> compute(ThirdPartyRouteRequest request) {
    requests.add(request);
    final reply = Completer<ThirdPartyRouteResponse>();
    replies.add(reply);
    _arrivals.remove(requests.length)?.complete();
    return reply.future;
  }

  Future<void> arrived(int count) => requests.length >= count
      ? Future.value()
      : _arrivals.putIfAbsent(count, Completer<void>.new).future;

  void reply(int index, RouteResult result) =>
      replies[index].complete(ThirdPartyRouteResponse.success(result));
}

class _Location implements LocationGateway {
  _Location(this.fix);
  final Future<LocationResult> Function() fix;
  @override
  Future<LocationResult> currentLocation() => fix();
}

class _Gateway implements NavigationGateway {
  _Gateway(this.reply, {this.origins});
  final Future<HandoffStatus> Function() reply;
  final List<RouteCoordinate?>? origins;

  @override
  Future<HandoffStatus> launch(
    NavigationApp app, {
    required RouteCoordinate destination,
    RouteCoordinate? origin,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return HandoffStatus.invalidated;
    origins?.add(origin);
    return reply();
  }
}
