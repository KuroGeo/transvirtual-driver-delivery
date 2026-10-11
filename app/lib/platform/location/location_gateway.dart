import '../../models/route.dart';

enum LocationStatus {
  idle,
  loading,
  ready,
  permissionDenied,
  permissionDeniedForever,
  serviceDisabled,
  timedOut,
  stale,
  unavailable,
  invalidated,
}

class LocationResult {
  const LocationResult.ready(RouteOrigin value)
    : origin = value,
      status = LocationStatus.ready;
  const LocationResult.failure(this.status) : origin = null;

  final RouteOrigin? origin;
  final LocationStatus status;
}

abstract interface class LocationGateway {
  Future<LocationResult> currentLocation();
}
