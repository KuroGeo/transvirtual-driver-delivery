import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../models/route.dart';
import 'location_gateway.dart';

/// One foreground fix, called only after an explicit user action. No tracking
/// stream, last-known fallback, or background location permission is requested.
class GeolocatorLocationGateway implements LocationGateway {
  const GeolocatorLocationGateway({this.timeout = const Duration(seconds: 8)});

  final Duration timeout;

  @override
  Future<LocationResult> currentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationResult.failure(LocationStatus.serviceDisabled);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        return const LocationResult.failure(LocationStatus.permissionDenied);
      }
      if (permission == LocationPermission.deniedForever) {
        return const LocationResult.failure(
          LocationStatus.permissionDeniedForever,
        );
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        return const LocationResult.failure(LocationStatus.unavailable);
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: timeout,
        ),
      );
      return LocationResult.ready(
        RouteOrigin(
          coordinate: RouteCoordinate(position.latitude, position.longitude),
          observedAt: position.timestamp,
          accuracyMeters: position.accuracy,
          source: OriginSource.device,
        ),
      );
    } on TimeoutException {
      return const LocationResult.failure(LocationStatus.timedOut);
    } on LocationServiceDisabledException {
      return const LocationResult.failure(LocationStatus.serviceDisabled);
    } on PermissionDeniedException {
      return const LocationResult.failure(LocationStatus.permissionDenied);
    } catch (_) {
      return const LocationResult.failure(LocationStatus.unavailable);
    }
  }
}
