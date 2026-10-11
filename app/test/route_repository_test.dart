import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/routes/route_repository.dart';
import 'package:ocean_delivery/data/routes/third_party_route_port.dart';
import 'package:ocean_delivery/models/route.dart';

const originCoordinate = RouteCoordinate(-33.86, 151.20);
const destinationCoordinate = RouteCoordinate(-33.87, 151.21);
const scope = NavigationScope(
  workspaceId: 'local:workspace',
  principalId: 'local:driver',
  sessionGeneration: 0,
  datasetId: 'dataset',
);
const target = NavigationTarget(
  stopId: 'private-stop-id',
  coordinate: destinationCoordinate,
  label: 'Private customer',
  address: 'Private address, including notes that must stay local',
);
final now = DateTime.utc(2026, 10, 12, 9);

RouteRequest request({RouteOrigin? origin, DateTime? departure}) =>
    RouteRequest(
      scope: scope,
      target: target,
      inputRevision: 1,
      requestId: 'private-request-id',
      origin:
          origin ??
          RouteOrigin(
            coordinate: originCoordinate,
            observedAt: now,
            accuracyMeters: 10,
            source: OriginSource.device,
          ),
      departureAt: departure ?? now,
    );

RouteResult road({
  String provider = 'licensed-test-supplier',
  String revision = 'verified-config-1',
  DateTime? computedAt,
  DateTime? expiresAt,
  DateTime? departureAt,
  DateTime? arrivalAt,
  double distance = 1800,
  Duration duration = const Duration(minutes: 5),
  RouteCoordinate destination = destinationCoordinate,
  List<RouteCoordinate>? geometry,
}) => RouteResult(
  origin: originCoordinate,
  destination: destination,
  provider: provider,
  configRevision: revision,
  computedAt: computedAt ?? now,
  expiresAt: expiresAt ?? now.add(const Duration(minutes: 5)),
  departureAt: departureAt ?? now,
  arrivalAt: arrivalAt ?? (departureAt ?? now).add(duration),
  distanceMeters: distance,
  duration: duration,
  geometry: geometry ?? [originCoordinate, destination],
  durationBasis: RouteDurationBasis.staticRoad,
);

class RoadPort implements ThirdPartyRoutePort {
  RoadPort(this.handler);
  final Future<ThirdPartyRouteResponse> Function(ThirdPartyRouteRequest)
  handler;
  final requests = <ThirdPartyRouteRequest>[];
  @override
  bool isConfigured = true;
  @override
  String provider = 'licensed-test-supplier';
  @override
  String configRevision = 'verified-config-1';

  @override
  Future<ThirdPartyRouteResponse> compute(ThirdPartyRouteRequest value) {
    requests.add(value);
    return handler(value);
  }
}

void main() {
  test(
    'default has no road supplier and creates no ETA even without origin',
    () async {
      final value = await const RouteRepository().preview(
        RouteRequest(
          scope: scope,
          target: target,
          inputRevision: 0,
          requestId: 'request',
          origin: null,
          departureAt: now,
        ),
      );
      expect(value.failure, RouteFailure.unavailable);
      expect(value.route, isNull);
    },
  );

  test('supplier sees only coordinates, departure and driving mode', () async {
    final source = road();
    final port = RoadPort(
      (value) async => ThirdPartyRouteResponse.success(source),
    );
    final result = await RouteRepository(
      port: port,
      clock: () => now,
    ).preview(request());
    expect(result.route, same(source));
    expect(port.requests.single.origin, originCoordinate);
    expect(port.requests.single.destination, destinationCoordinate);
    expect(port.requests.single.departureAt, now);
    expect(port.requests.single.mode, RouteTravelMode.driving);
    expect(result.route!.trafficAware, isFalse);
    expect(result.route!.licenseAllowsMapOverlay, isFalse);
    expect(() => result.route!.geometry.clear(), throwsUnsupportedError);
  });

  test('missing origin never calls a configured supplier', () async {
    final port = RoadPort((_) async => ThirdPartyRouteResponse.success(road()));
    final result = await RouteRepository(port: port, clock: () => now).preview(
      RouteRequest(
        scope: scope,
        target: target,
        inputRevision: 0,
        requestId: 'request',
        origin: null,
        departureAt: now,
      ),
    );
    expect(result.failure, RouteFailure.locationRequired);
    expect(port.requests, isEmpty);
  });

  for (final fix in [
    RouteOrigin(
      coordinate: originCoordinate,
      observedAt: now.subtract(const Duration(minutes: 2, milliseconds: 1)),
      accuracyMeters: 10,
      source: OriginSource.device,
    ),
    RouteOrigin(
      coordinate: originCoordinate,
      observedAt: now.add(const Duration(seconds: 6)),
      accuracyMeters: 10,
      source: OriginSource.device,
    ),
    RouteOrigin(
      coordinate: originCoordinate,
      observedAt: now,
      accuracyMeters: 100.1,
      source: OriginSource.device,
    ),
    RouteOrigin(
      coordinate: const RouteCoordinate(double.nan, 151),
      observedAt: now,
      accuracyMeters: 10,
      source: OriginSource.device,
    ),
  ]) {
    test(
      'untrusted device origin ${fix.observedAt}/${fix.accuracyMeters} is rejected',
      () async {
        final port = RoadPort(
          (_) async => ThirdPartyRouteResponse.success(road()),
        );
        final result = await RouteRepository(
          port: port,
          clock: () => now,
        ).preview(request(origin: fix));
        expect(result.failure, RouteFailure.staleOrigin);
        expect(port.requests, isEmpty);
      },
    );
  }

  test(
    'origin valid at send but stale at response never produces ETA',
    () async {
      var time = now;
      final answer = Completer<ThirdPartyRouteResponse>();
      final port = RoadPort((_) => answer.future);
      final pending = RouteRepository(
        port: port,
        clock: () => time,
      ).preview(request());
      time = now.add(const Duration(minutes: 2, milliseconds: 1));
      answer.complete(ThirdPartyRouteResponse.success(road(computedAt: time)));
      final result = await pending;
      expect(result.failure, RouteFailure.staleOrigin);
      expect(result.route, isNull);
    },
  );

  test(
    'freshness accuracy and future tolerances accept the exact boundary',
    () async {
      final port = RoadPort(
        (_) async => ThirdPartyRouteResponse.success(road()),
      );
      final repo = RouteRepository(port: port, clock: () => now);
      for (final observedAt in [
        now.subtract(const Duration(minutes: 2)),
        now.add(const Duration(seconds: 5)),
      ]) {
        final result = await repo.preview(
          request(
            origin: RouteOrigin(
              coordinate: originCoordinate,
              observedAt: observedAt,
              accuracyMeters: 100,
              source: OriginSource.device,
            ),
          ),
        );
        expect(result.failure, isNull);
      }
    },
  );

  test(
    'timeout releases caller and a late supplier result cannot replace failure',
    () async {
      final answer = Completer<ThirdPartyRouteResponse>();
      final port = RoadPort((_) => answer.future);
      final result = await RouteRepository(
        port: port,
        clock: () => now,
        timeout: const Duration(milliseconds: 1),
      ).preview(request());
      expect(result.failure, RouteFailure.timedOut);
      answer.complete(ThirdPartyRouteResponse.success(road()));
      await Future<void>.delayed(Duration.zero);
      expect(result.route, isNull);
      expect(port.requests, hasLength(1));
    },
  );

  test(
    'explicit no route and supplier exceptions have bounded failures',
    () async {
      for (final failure in [
        RouteFailure.noRoute,
        RouteFailure.providerFailure,
      ]) {
        final port = RoadPort((_) async {
          if (failure == RouteFailure.providerFailure)
            throw StateError('private credentials');
          return ThirdPartyRouteResponse.failure(failure);
        });
        final result = await RouteRepository(
          port: port,
          clock: () => now,
        ).preview(request());
        expect(result.failure, failure);
        expect(result.route, isNull);
        expect(port.requests, hasLength(1));
      }
    },
  );

  test('provider or configuration mismatch is rejected', () async {
    for (final source in [road(provider: 'other'), road(revision: 'old')]) {
      final port = RoadPort(
        (_) async => ThirdPartyRouteResponse.success(source),
      );
      final result = await RouteRepository(
        port: port,
        clock: () => now,
      ).preview(request());
      expect(result.failure, RouteFailure.configMismatch);
    }
  });

  test(
    'configuration changed while in flight invalidates the response',
    () async {
      final answer = Completer<ThirdPartyRouteResponse>();
      final port = RoadPort((_) => answer.future);
      final pending = RouteRepository(
        port: port,
        clock: () => now,
      ).preview(request());
      port.configRevision = 'new-configuration';
      answer.complete(ThirdPartyRouteResponse.success(road()));
      expect((await pending).failure, RouteFailure.configMismatch);
    },
  );

  test('expired road result is rejected before display', () async {
    final port = RoadPort(
      (_) async => ThirdPartyRouteResponse.success(road(expiresAt: now)),
    );
    expect(
      (await RouteRepository(
        port: port,
        clock: () => now,
      ).preview(request())).failure,
      RouteFailure.expiredResult,
    );
  });

  for (final entry in <String, RouteResult>{
    'cached before attempt': road(
      computedAt: now.subtract(const Duration(minutes: 1)),
    ),
    'future source timestamp': road(
      computedAt: now.add(const Duration(seconds: 6)),
    ),
    'wrong destination': road(destination: const RouteCoordinate(-34, 152)),
    'wrong departure': road(departureAt: now.add(const Duration(minutes: 1))),
    'wrong arrival duration': road(
      arrivalAt: now.add(const Duration(minutes: 6)),
    ),
    'nonfinite distance': road(distance: double.infinity),
    'negative duration': road(duration: const Duration(seconds: -1)),
    'missing geometry': road(geometry: []),
    'invalid geometry': road(
      geometry: [
        originCoordinate,
        const RouteCoordinate(91, 181),
        destinationCoordinate,
      ],
    ),
    'geometry does not connect': road(
      geometry: [const RouteCoordinate(0, 0), destinationCoordinate],
    ),
  }.entries) {
    test('invalid road metadata: ${entry.key}', () async {
      final port = RoadPort(
        (_) async => ThirdPartyRouteResponse.success(entry.value),
      );
      final result = await RouteRepository(
        port: port,
        clock: () => now,
      ).preview(request());
      expect(result.failure, RouteFailure.invalidResponse);
      expect(result.route, isNull);
    });
  }

  test(
    'explicit retry recomputes and does not reuse a cached result',
    () async {
      final port = RoadPort(
        (_) async => ThirdPartyRouteResponse.success(road()),
      );
      final repo = RouteRepository(port: port, clock: () => now);
      await repo.preview(request());
      await repo.preview(request());
      expect(port.requests, hasLength(2));
    },
  );
}
