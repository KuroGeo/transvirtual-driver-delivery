import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/routes/route_repository.dart';
import 'package:ocean_delivery/data/routes/third_party_route_port.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/models/route.dart';
import 'package:ocean_delivery/platform/location/location_gateway.dart';
import 'package:ocean_delivery/platform/navigation/navigation_gateway.dart';
import 'package:ocean_delivery/platform/navigation/url_navigation_gateway.dart';
import 'package:ocean_delivery/ui/navigation/navigation_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data/repository_fixture.dart';
import 'route_repository_test.dart' as fixtures;

class FixGateway implements LocationGateway {
  FixGateway(this.handler);
  final Future<LocationResult> Function() handler;
  int calls = 0;
  @override
  Future<LocationResult> currentLocation() {
    calls++;
    return handler();
  }
}

class MapsGateway implements NavigationGateway {
  MapsGateway({this.result = HandoffStatus.handoffRequested});
  HandoffStatus result;
  int calls = 0;
  RouteCoordinate? receivedOrigin;
  @override
  Future<HandoffStatus> launch(
    NavigationApp app, {
    required RouteCoordinate destination,
    RouteCoordinate? origin,
    required bool Function() isCurrent,
  }) async {
    calls++;
    receivedOrigin = origin;
    return isCurrent() ? result : HandoffStatus.invalidated;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  NavigationViewModel model({
    LocationGateway? location,
    NavigationGateway? gateway,
    RouteRepository? routes,
    bool Function()? isCurrent,
    DateTime Function()? clock,
    Duration operationTimeout = const Duration(seconds: 8),
  }) {
    final value = NavigationViewModel(
      scope: fixtures.scope,
      target: fixtures.target,
      isCurrent: isCurrent ?? () => true,
      location:
          location ??
          FixGateway(
            () async =>
                const LocationResult.failure(LocationStatus.permissionDenied),
          ),
      routes: routes ?? const RouteRepository(),
      gateway: gateway ?? MapsGateway(),
      clock: clock ?? () => fixtures.now,
      operationTimeout: operationTimeout,
    );
    addTearDown(value.dispose);
    return value;
  }

  test(
    'preview alone never requests location or creates a fixture ETA',
    () async {
      final location = FixGateway(
        () async => throw StateError('unprompted location'),
      );
      final value = model(location: location);
      await value.requestPreview();
      expect(location.calls, 0);
      expect(value.route, isNull);
      expect(value.routeStatus, RoutePreviewStatus.unavailable);
      expect(value.origin, isNull);
      expect(value.handoffStatus, HandoffStatus.idle);
    },
  );

  test(
    'synchronous loading invalidation prevents a supplier dispatch',
    () async {
      final port = fixtures.RoadPort(
        (_) async => ThirdPartyRouteResponse.success(fixtures.road()),
      );
      final value = model(
        routes: RouteRepository(port: port, clock: () => fixtures.now),
      );
      value.addListener(() {
        if (value.routeStatus == RoutePreviewStatus.loading) value.invalidate();
      });
      await value.confirmManualStart(fixtures.originCoordinate);
      expect(port.requests, isEmpty);
      expect(value.routeStatus, RoutePreviewStatus.invalidated);
    },
  );

  test(
    'synchronous loading invalidation prevents a location dispatch',
    () async {
      final location = FixGateway(
        () async =>
            const LocationResult.failure(LocationStatus.permissionDenied),
      );
      final value = model(location: location);
      value.addListener(() {
        if (value.locationStatus == LocationStatus.loading) value.invalidate();
      });
      await value.useMyLocation();
      expect(location.calls, 0);
      expect(value.locationStatus, LocationStatus.invalidated);
    },
  );

  test(
    'synchronous input replacement dispatches only the newer snapshot',
    () async {
      final port = fixtures.RoadPort(
        (_) async =>
            const ThirdPartyRouteResponse.failure(RouteFailure.noRoute),
      );
      final value = model(
        routes: RouteRepository(port: port, clock: () => fixtures.now),
      );
      var replaced = false;
      const replacement = RouteCoordinate(-33.88, 151.19);
      value.addListener(() {
        if (!replaced && value.routeStatus == RoutePreviewStatus.loading) {
          replaced = true;
          unawaited(value.confirmManualStart(replacement));
        }
      });
      await value.confirmManualStart(fixtures.originCoordinate);
      await Future<void>.delayed(Duration.zero);
      expect(port.requests, hasLength(1));
      expect(port.requests.single.origin, replacement);
      expect(value.origin!.coordinate, replacement);
    },
  );

  for (final status in [
    LocationStatus.permissionDenied,
    LocationStatus.permissionDeniedForever,
    LocationStatus.serviceDisabled,
    LocationStatus.timedOut,
  ]) {
    test('$status degrades to Maps-selected origin', () async {
      final gateway = MapsGateway();
      final value = model(
        location: FixGateway(() async => LocationResult.failure(status)),
        gateway: gateway,
      );
      await value.useMyLocation();
      expect(value.locationStatus, status);
      expect(value.origin, isNull);
      await value.launch(NavigationApp.googleMaps);
      expect(gateway.receivedOrigin, isNull);
      expect(value.handoffStatus, HandoffStatus.handoffRequested);
    });
  }

  test('old device fix is not a starting point', () async {
    final value = model(
      location: FixGateway(
        () async => LocationResult.ready(
          RouteOrigin(
            coordinate: fixtures.originCoordinate,
            observedAt: fixtures.now.subtract(const Duration(minutes: 3)),
            accuracyMeters: 10,
            source: OriginSource.device,
          ),
        ),
      ),
    );
    await value.useMyLocation();
    expect(value.locationStatus, LocationStatus.stale);
    expect(value.origin, isNull);
  });

  test(
    'hung location is bounded and its late fix cannot replace manual input',
    () async {
      final late = Completer<LocationResult>();
      final value = model(
        location: FixGateway(() => late.future),
        operationTimeout: const Duration(milliseconds: 1),
      );
      await value.useMyLocation();
      expect(value.locationStatus, LocationStatus.timedOut);
      expect(value.isBusy, isFalse);
      const manual = RouteCoordinate(-33.88, 151.19);
      await value.confirmManualStart(manual);
      late.complete(
        LocationResult.ready(
          RouteOrigin(
            coordinate: fixtures.originCoordinate,
            observedAt: fixtures.now,
            accuracyMeters: 10,
            source: OriginSource.device,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(value.origin!.coordinate, manual);
    },
  );

  test('late location cannot replace explicit manual start', () async {
    final location = Completer<LocationResult>();
    final value = model(location: FixGateway(() => location.future));
    final pending = value.useMyLocation();
    const manual = RouteCoordinate(-33.88, 151.19);
    await value.confirmManualStart(manual);
    location.complete(
      LocationResult.ready(
        RouteOrigin(
          coordinate: fixtures.originCoordinate,
          observedAt: fixtures.now,
          accuracyMeters: 10,
          source: OriginSource.device,
        ),
      ),
    );
    await pending;
    expect(value.origin!.coordinate, manual);
    expect(value.origin!.source, OriginSource.manual);
    expect(value.locationStatus, LocationStatus.ready);
  });

  test('late route A cannot replace route B after start changed', () async {
    final pending = <Completer<ThirdPartyRouteResponse>>[];
    final port = fixtures.RoadPort((_) {
      final answer = Completer<ThirdPartyRouteResponse>();
      pending.add(answer);
      return answer.future;
    });
    final value = model(
      routes: RouteRepository(port: port, clock: () => fixtures.now),
    );
    final first = value.confirmManualStart(fixtures.originCoordinate);
    final second = value.requestPreview();
    final roadB = fixtures.road(distance: 2400);
    pending[1].complete(ThirdPartyRouteResponse.success(roadB));
    await second;
    pending[0].complete(
      ThirdPartyRouteResponse.success(fixtures.road(distance: 1800)),
    );
    await first;
    expect(value.route, same(roadB));
    expect(value.route!.distanceMeters, 2400);
  });

  test('scope or stop invalidation fences a late location result', () async {
    var current = true;
    final location = Completer<LocationResult>();
    final value = model(
      isCurrent: () => current,
      location: FixGateway(() => location.future),
    );
    final pending = value.useMyLocation();
    current = false;
    location.complete(
      LocationResult.ready(
        RouteOrigin(
          coordinate: fixtures.originCoordinate,
          observedAt: fixtures.now,
          accuracyMeters: 10,
          source: OriginSource.device,
        ),
      ),
    );
    await pending;
    expect(value.isValid, isFalse);
    expect(value.origin, isNull);
    expect(value.routeStatus, RoutePreviewStatus.invalidated);
    expect(value.handoffStatus, HandoffStatus.invalidated);
  });

  test(
    'return requires successful handoff and an observed background transition',
    () async {
      final value = model();
      value.markBackgrounded();
      value.resume();
      expect(value.handoffStatus, HandoffStatus.idle);
      await value.launch(NavigationApp.appleMaps);
      value.resume();
      expect(value.handoffStatus, HandoffStatus.handoffRequested);
      value.markBackgrounded();
      value.resume();
      expect(value.handoffStatus, HandoffStatus.returned);
    },
  );

  test('unavailable or failed launches never become returned', () async {
    for (final status in [
      HandoffStatus.unavailable,
      HandoffStatus.launchFailed,
    ]) {
      final value = model(gateway: MapsGateway(result: status));
      await value.launch(NavigationApp.appleMaps);
      value.markBackgrounded();
      value.resume();
      expect(value.handoffStatus, status);
    }
  });

  test(
    'scope switch after availability starts prevents any platform launch',
    () async {
      var current = true;
      final availability = Completer<bool>();
      var launches = 0;
      final gateway = UrlNavigationGateway(
        platform: TargetPlatform.iOS,
        supportsMode: (_) async => true,
        canLaunch: (_) => availability.future,
        launchUrl: (_, _) async {
          launches++;
          return true;
        },
      );
      final value = model(gateway: gateway, isCurrent: () => current);
      final pending = value.launch(NavigationApp.googleMaps);
      await Future<void>.delayed(Duration.zero);
      current = false;
      availability.complete(true);
      await pending;
      expect(launches, 0);
      expect(value.handoffStatus, HandoffStatus.invalidated);
    },
  );

  test('origin changed during availability prevents a stale launch', () async {
    final availability = Completer<bool>();
    var launches = 0;
    final gateway = UrlNavigationGateway(
      platform: TargetPlatform.iOS,
      supportsMode: (_) async => true,
      canLaunch: (_) => availability.future,
      launchUrl: (_, _) async {
        launches++;
        return true;
      },
    );
    final value = model(gateway: gateway);
    final pending = value.launch(NavigationApp.googleMaps);
    await Future<void>.delayed(Duration.zero);
    await value.confirmManualStart(fixtures.originCoordinate);
    availability.complete(true);
    await pending;
    expect(launches, 0);
    expect(value.handoffStatus, HandoffStatus.idle);
    expect(value.origin!.coordinate, fixtures.originCoordinate);
  });

  test(
    'origin becomes stale during availability and is never dispatched',
    () async {
      var time = fixtures.now;
      final availability = Completer<bool>();
      var launches = 0;
      final gateway = UrlNavigationGateway(
        platform: TargetPlatform.iOS,
        supportsMode: (_) async => true,
        canLaunch: (_) => availability.future,
        launchUrl: (_, _) async {
          launches++;
          return true;
        },
      );
      final value = model(
        gateway: gateway,
        clock: () => time,
        location: FixGateway(
          () async => LocationResult.ready(
            RouteOrigin(
              coordinate: fixtures.originCoordinate,
              observedAt: fixtures.now,
              accuracyMeters: 10,
              source: OriginSource.device,
            ),
          ),
        ),
      );
      await value.useMyLocation();
      final pending = value.launch(NavigationApp.googleMaps);
      await Future<void>.delayed(Duration.zero);
      time = fixtures.now.add(const Duration(minutes: 2, milliseconds: 1));
      availability.complete(true);
      await pending;
      expect(launches, 0);
      expect(value.locationStatus, LocationStatus.stale);
      expect(value.origin, isNull);
      expect(value.handoffStatus, HandoffStatus.launchFailed);
      expect(value.isBusy, isFalse);
    },
  );

  test(
    'timed out availability cannot dispatch after timeout and releases checking',
    () async {
      final availability = Completer<bool>();
      var launches = 0;
      final gateway = UrlNavigationGateway(
        platform: TargetPlatform.iOS,
        supportsMode: (_) async => true,
        canLaunch: (_) => availability.future,
        launchUrl: (_, _) async {
          launches++;
          return true;
        },
      );
      final value = model(
        gateway: gateway,
        operationTimeout: const Duration(milliseconds: 1),
      );
      await value.launch(NavigationApp.appleMaps);
      expect(value.handoffStatus, HandoffStatus.launchFailed);
      expect(value.isBusy, isFalse);
      availability.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(launches, 0);
      expect(value.handoffStatus, HandoffStatus.launchFailed);
    },
  );

  test(
    'late launch success after invalidate never marks handoff or return',
    () async {
      final launched = Completer<bool>();
      final gateway = UrlNavigationGateway(
        platform: TargetPlatform.iOS,
        supportsMode: (_) async => true,
        canLaunch: (_) async => true,
        launchUrl: (_, _) => launched.future,
      );
      final value = model(gateway: gateway);
      final pending = value.launch(NavigationApp.appleMaps);
      await Future<void>.delayed(Duration.zero);
      value.markBackgrounded();
      value.resume();
      value.invalidate();
      launched.complete(true);
      await pending;
      expect(value.handoffStatus, HandoffStatus.invalidated);
    },
  );

  test(
    'background and resume before receipt becomes returned only on success',
    () async {
      final launched = Completer<bool>();
      final gateway = UrlNavigationGateway(
        platform: TargetPlatform.iOS,
        supportsMode: (_) async => true,
        canLaunch: (_) async => true,
        launchUrl: (_, _) => launched.future,
      );
      final value = model(gateway: gateway);
      final pending = value.launch(NavigationApp.appleMaps);
      await Future<void>.delayed(Duration.zero);
      value.markBackgrounded();
      value.resume();
      expect(value.handoffStatus, HandoffStatus.checking);
      launched.complete(true);
      await pending;
      expect(value.handoffStatus, HandoffStatus.returned);
    },
  );

  test(
    'native app absent is unavailable and launch refusal is failed',
    () async {
      for (final available in [false, true]) {
        var launches = 0;
        final gateway = UrlNavigationGateway(
          platform: TargetPlatform.iOS,
          supportsMode: (_) async => true,
          canLaunch: (_) async => available,
          launchUrl: (_, _) async {
            launches++;
            return false;
          },
        );
        final result = await gateway.launch(
          NavigationApp.googleMaps,
          destination: fixtures.destinationCoordinate,
          isCurrent: () => true,
        );
        expect(
          result,
          available ? HandoffStatus.launchFailed : HandoffStatus.unavailable,
        );
        expect(launches, available ? 1 : 0);
      }
    },
  );

  test(
    'URI allowlist carries coordinates and mode without local identity',
    () async {
      for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
        final gateway = UrlNavigationGateway(platform: platform);
        for (final app in NavigationApp.values) {
          final uri = gateway.uriFor(
            app,
            destination: fixtures.destinationCoordinate,
            origin: fixtures.originCoordinate,
          );
          if (uri == null) continue;
          expect(uri.userInfo, isEmpty);
          expect(uri.fragment, isEmpty);
          expect(uri.toString(), isNot(contains(fixtures.target.stopId)));
          expect(uri.toString(), isNot(contains(fixtures.scope.principalId)));
          expect(uri.toString(), isNot(contains(fixtures.target.address)));
          expect(
            uri.queryParameters.values,
            contains(fixtures.destinationCoordinate.uriValue),
          );
          expect(
            uri.queryParameters.values,
            contains(fixtures.originCoordinate.uriValue),
          );
          expect(
            uri.queryParameters.keys.toSet().difference({
              'daddr',
              'saddr',
              'dirflg',
              'directionsmode',
              'api',
              'origin',
              'destination',
              'travelmode',
            }),
            isEmpty,
          );
        }
      }
    },
  );

  test('Android native navigation uses the documented opaque URI', () {
    final uri = UrlNavigationGateway(platform: TargetPlatform.android).uriFor(
      NavigationApp.googleMaps,
      destination: fixtures.destinationCoordinate,
    );
    expect(uri!.scheme, 'google.navigation');
    expect(uri.query, isEmpty);
    expect(
      Uri.decodeComponent(uri.path),
      'q=${fixtures.destinationCoordinate.uriValue}&mode=d',
    );
  });

  test(
    'browser alternative uses an explicit supported browser surface',
    () async {
      LaunchMode? launchedMode;
      Uri? opened;
      final gateway = UrlNavigationGateway(
        platform: TargetPlatform.iOS,
        canLaunch: (_) async =>
            throw StateError('native availability is irrelevant'),
        supportsMode: (mode) async => mode == LaunchMode.inAppBrowserView,
        launchUrl: (uri, mode) async {
          opened = uri;
          launchedMode = mode;
          return true;
        },
      );
      expect(
        await gateway.launch(
          NavigationApp.browserMap,
          destination: fixtures.destinationCoordinate,
          isCurrent: () => true,
        ),
        HandoffStatus.handoffRequested,
      );
      expect(launchedMode, LaunchMode.inAppBrowserView);
      expect(opened!.host, 'www.google.com');
      expect(opened!.queryParameters['origin'], isNull);
      expect(opened!.queryParameters['api'], '1');
    },
  );

  test(
    'unsupported mode never silently falls back to another application',
    () async {
      var launches = 0;
      final gateway = UrlNavigationGateway(
        platform: TargetPlatform.android,
        supportsMode: (_) async => false,
        launchUrl: (_, _) async {
          launches++;
          return true;
        },
      );
      expect(
        await gateway.launch(
          NavigationApp.browserMap,
          destination: fixtures.destinationCoordinate,
          isCurrent: () => true,
        ),
        HandoffStatus.unavailable,
      );
      expect(launches, 0);
    },
  );

  test(
    'navigation leaves persisted delivery and confirmation queue unchanged',
    () async {
      final fixture = await RepositoryFixture.create();
      addTearDown(fixture.dispose);
      await fixture.repository.initialize();
      final stops = await fixture.repository.loadStops();
      await fixture.repository.submit(stops.first.id, DeliveryStatus.completed);
      final queuedBefore = (await fixture.repository.pendingUpdates())
          .map(updateIdentity)
          .toList();
      final database = await fixture.admin;
      final rowsBefore = await database.query('stops', orderBy: 'id');
      final value = model();
      await value.requestPreview();
      await value.useMyLocation();
      await value.launch(NavigationApp.appleMaps);
      value.markBackgrounded();
      value.resume();
      expect(value.handoffStatus, HandoffStatus.returned);
      expect(
        (await fixture.repository.pendingUpdates())
            .map(updateIdentity)
            .toList(),
        queuedBefore,
      );
      expect(await database.query('stops', orderBy: 'id'), rowsBefore);
    },
  );
}
