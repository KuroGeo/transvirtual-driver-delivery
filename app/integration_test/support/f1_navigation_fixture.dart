import 'package:ocean_delivery/models/route.dart';
import 'package:ocean_delivery/platform/location/location_gateway.dart';
import 'package:ocean_delivery/platform/navigation/navigation_gateway.dart';

/// Private native UI fixture. No OS Maps, GPS, route or arrival claim.
class ControlledNavigationGateway implements NavigationGateway {
  const ControlledNavigationGateway();

  @override
  Future<HandoffStatus> launch(
    NavigationApp app, {
    required RouteCoordinate destination,
    RouteCoordinate? origin,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return HandoffStatus.invalidated;
    return switch (app) {
      NavigationApp.appleMaps => HandoffStatus.unavailable,
      NavigationApp.googleMaps => HandoffStatus.launchFailed,
      NavigationApp.browserMap => HandoffStatus.handoffRequested,
    };
  }
}

class ControlledLocationGateway implements LocationGateway {
  const ControlledLocationGateway();

  @override
  Future<LocationResult> currentLocation() async =>
      const LocationResult.failure(LocationStatus.permissionDenied);
}
