import 'dart:async';
import 'dart:math' as math;

import '../../models/route.dart';
import 'third_party_route_port.dart';

/// Validates each fresh supplier response. No route is persisted or cached.
class RouteRepository {
  const RouteRepository({
    this.port = const UnavailableThirdPartyRoutePort(),
    this.clock = DateTime.now,
    this.timeout = const Duration(seconds: 8),
  });

  final ThirdPartyRoutePort port;
  final DateTime Function() clock;
  final Duration timeout;

  Future<RouteOutcome> preview(RouteRequest request) async {
    final startedAt = clock();
    if (!request.scope.isValid ||
        !request.target.isValid ||
        request.requestId.isEmpty ||
        request.inputRevision < 0 ||
        timeout <= Duration.zero) {
      return const RouteOutcome.failure(RouteFailure.invalidInput);
    }
    if (!port.isConfigured) {
      return const RouteOutcome.failure(RouteFailure.unavailable);
    }
    if (port.provider.isEmpty || port.configRevision.isEmpty) {
      return const RouteOutcome.failure(RouteFailure.configMismatch);
    }
    final origin = request.origin;
    if (origin == null) {
      return const RouteOutcome.failure(RouteFailure.locationRequired);
    }
    if (!origin.isUsableAt(startedAt)) {
      return const RouteOutcome.failure(RouteFailure.staleOrigin);
    }
    // Supplier configuration is also bound to the attempt, not read only when
    // its asynchronous response arrives.
    final provider = port.provider;
    final configRevision = port.configRevision;
    try {
      final response = await port
          .compute(
            ThirdPartyRouteRequest(
              origin: origin.coordinate,
              destination: request.target.coordinate,
              departureAt: request.departureAt.toUtc(),
            ),
          )
          .timeout(timeout);
      final now = clock();
      if (!origin.isUsableAt(now)) {
        return const RouteOutcome.failure(RouteFailure.staleOrigin);
      }
      if (!port.isConfigured ||
          port.provider != provider ||
          port.configRevision != configRevision) {
        return const RouteOutcome.failure(RouteFailure.configMismatch);
      }
      final result = response.route;
      if (result == null) {
        return RouteOutcome.failure(
          response.failure ?? RouteFailure.invalidResponse,
        );
      }
      if (result.provider != provider ||
          result.configRevision != configRevision) {
        return const RouteOutcome.failure(RouteFailure.configMismatch);
      }
      if (!result.expiresAt.isAfter(now)) {
        return const RouteOutcome.failure(RouteFailure.expiredResult);
      }
      if (!_validResult(result, request, startedAt, now)) {
        return const RouteOutcome.failure(RouteFailure.invalidResponse);
      }
      return RouteOutcome.success(result);
    } on TimeoutException {
      return const RouteOutcome.failure(RouteFailure.timedOut);
    } catch (_) {
      return const RouteOutcome.failure(RouteFailure.providerFailure);
    }
  }

  bool _validResult(
    RouteResult result,
    RouteRequest request,
    DateTime startedAt,
    DateTime now,
  ) =>
      result.origin == request.origin!.coordinate &&
      result.destination == request.target.coordinate &&
      result.departureAt.isAtSameMomentAs(request.departureAt) &&
      result.arrivalAt.isAtSameMomentAs(
        result.departureAt.add(result.duration),
      ) &&
      !result.computedAt.isBefore(
        startedAt.subtract(const Duration(seconds: 5)),
      ) &&
      !result.computedAt.isAfter(now.add(const Duration(seconds: 5))) &&
      result.expiresAt.isAfter(result.computedAt) &&
      result.distanceMeters.isFinite &&
      result.distanceMeters >= 0 &&
      result.duration >= Duration.zero &&
      (result.origin == result.destination ||
          (result.distanceMeters > 0 && result.duration > Duration.zero)) &&
      result.geometry.length >= 2 &&
      result.geometry.length <= 50000 &&
      result.geometry.every((point) => point.isValid) &&
      _distance(result.geometry.first, result.origin) <= 150 &&
      _distance(result.geometry.last, result.destination) <= 150;

  double _distance(RouteCoordinate a, RouteCoordinate b) {
    final latitudeA = a.latitude * math.pi / 180;
    final latitudeB = b.latitude * math.pi / 180;
    final deltaLatitude = latitudeB - latitudeA;
    final deltaLongitude = (b.longitude - a.longitude) * math.pi / 180;
    final haversine =
        math.pow(math.sin(deltaLatitude / 2), 2) +
        math.cos(latitudeA) *
            math.cos(latitudeB) *
            math.pow(math.sin(deltaLongitude / 2), 2);
    return 6371000 * 2 * math.asin(math.sqrt(haversine.clamp(0, 1)));
  }
}
