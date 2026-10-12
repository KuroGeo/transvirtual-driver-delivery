/// Local isolation identity. The current client uses a local namespace; future
/// account assembly supplies authenticated ownership and advances generation.
class NavigationScope {
  const NavigationScope({
    required this.workspaceId,
    required this.principalId,
    required this.sessionGeneration,
    required this.datasetId,
  });

  final String workspaceId;
  final String principalId;
  final int sessionGeneration;
  final String datasetId;

  bool get isValid =>
      workspaceId.isNotEmpty &&
      principalId.isNotEmpty &&
      sessionGeneration >= 0 &&
      datasetId.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is NavigationScope &&
      workspaceId == other.workspaceId &&
      principalId == other.principalId &&
      sessionGeneration == other.sessionGeneration &&
      datasetId == other.datasetId;

  @override
  int get hashCode =>
      Object.hash(workspaceId, principalId, sessionGeneration, datasetId);
}

class RouteCoordinate {
  const RouteCoordinate(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  bool get isValid =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;

  String get uriValue => '$latitude,$longitude';

  @override
  bool operator ==(Object other) =>
      other is RouteCoordinate &&
      latitude == other.latitude &&
      longitude == other.longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);
}

class NavigationTarget {
  const NavigationTarget({
    required this.stopId,
    required this.coordinate,
    required this.label,
    required this.address,
  });

  final String stopId;
  final RouteCoordinate coordinate;
  final String label;
  final String address;

  bool get isValid => stopId.isNotEmpty && coordinate.isValid;
}

enum OriginSource { device, manual }

class RouteOrigin {
  const RouteOrigin({
    required this.coordinate,
    required this.observedAt,
    required this.accuracyMeters,
    required this.source,
  });

  final RouteCoordinate coordinate;
  final DateTime observedAt;
  final double accuracyMeters;
  final OriginSource source;

  /// A manual start is a user-confirmed place, not a claim of current location.
  bool isUsableAt(DateTime now) =>
      coordinate.isValid &&
      accuracyMeters.isFinite &&
      accuracyMeters >= 0 &&
      !observedAt.isAfter(now.add(const Duration(seconds: 5))) &&
      (source == OriginSource.manual ||
          (accuracyMeters <= 100 &&
              now.difference(observedAt) <= const Duration(minutes: 2)));
}

class RouteRequest {
  const RouteRequest({
    required this.scope,
    required this.target,
    required this.inputRevision,
    required this.requestId,
    required this.origin,
    required this.departureAt,
  });

  final NavigationScope scope;
  final NavigationTarget target;
  final int inputRevision;
  final String requestId;
  final RouteOrigin? origin;
  final DateTime departureAt;
}

enum RouteDurationBasis { staticRoad, trafficAware }

class RouteResult {
  RouteResult({
    required this.origin,
    required this.destination,
    required this.provider,
    required this.configRevision,
    required this.computedAt,
    required this.expiresAt,
    required this.departureAt,
    required this.arrivalAt,
    required this.distanceMeters,
    required this.duration,
    required List<RouteCoordinate> geometry,
    required this.durationBasis,
    this.licenseAllowsMapOverlay = false,
  }) : geometry = List.unmodifiable(geometry);

  final RouteCoordinate origin;
  final RouteCoordinate destination;
  final String provider;
  final String configRevision;
  final DateTime computedAt;
  final DateTime expiresAt;
  final DateTime departureAt;
  final DateTime arrivalAt;
  final double distanceMeters;
  final Duration duration;
  final List<RouteCoordinate> geometry;
  final RouteDurationBasis durationBasis;
  final bool licenseAllowsMapOverlay;

  bool get trafficAware => durationBasis == RouteDurationBasis.trafficAware;
}

enum RouteFailure {
  unavailable,
  locationRequired,
  staleOrigin,
  invalidInput,
  timedOut,
  providerFailure,
  noRoute,
  invalidResponse,
  configMismatch,
  expiredResult,
}

class RouteOutcome {
  const RouteOutcome.success(RouteResult result)
    : route = result,
      failure = null;
  const RouteOutcome.failure(RouteFailure reason)
    : route = null,
      failure = reason;

  final RouteResult? route;
  final RouteFailure? failure;
}
