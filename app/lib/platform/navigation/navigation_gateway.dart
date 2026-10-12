import '../../models/route.dart';

enum NavigationApp { appleMaps, googleMaps, browserMap }

enum HandoffStatus {
  idle,
  checking,
  unavailable,
  launchFailed,
  handoffRequested,
  returned,
  invalidated,
}

abstract interface class NavigationGateway {
  Future<HandoffStatus> launch(
    NavigationApp app, {
    required RouteCoordinate destination,
    RouteCoordinate? origin,
    required bool Function() isCurrent,
  });
}
