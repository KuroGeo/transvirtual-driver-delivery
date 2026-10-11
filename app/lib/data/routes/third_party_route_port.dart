import '../../models/route.dart';

enum RouteTravelMode { driving }

/// The entire supplier boundary: no scope, stop ID, notes or app credentials.
class ThirdPartyRouteRequest {
  const ThirdPartyRouteRequest({
    required this.origin,
    required this.destination,
    required this.departureAt,
    this.mode = RouteTravelMode.driving,
  });

  final RouteCoordinate origin;
  final RouteCoordinate destination;
  final DateTime departureAt;
  final RouteTravelMode mode;
}

class ThirdPartyRouteResponse {
  const ThirdPartyRouteResponse.success(RouteResult result)
    : route = result,
      failure = null;
  const ThirdPartyRouteResponse.failure(RouteFailure reason)
    : route = null,
      failure = reason;

  final RouteResult? route;
  final RouteFailure? failure;
}

abstract interface class ThirdPartyRoutePort {
  bool get isConfigured;
  String get provider;
  String get configRevision;
  Future<ThirdPartyRouteResponse> compute(ThirdPartyRouteRequest request);
}

/// There is no licensed road supplier configured in this release. Maps handoff
/// remains available. Production never selects a route fixture automatically.
class UnavailableThirdPartyRoutePort implements ThirdPartyRoutePort {
  const UnavailableThirdPartyRoutePort();

  @override
  bool get isConfigured => false;
  @override
  String get provider => 'unconfigured';
  @override
  String get configRevision => 'none';
  @override
  Future<ThirdPartyRouteResponse> compute(
    ThirdPartyRouteRequest request,
  ) async => const ThirdPartyRouteResponse.failure(RouteFailure.unavailable);
}
