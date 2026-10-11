import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../../models/route.dart';
import 'navigation_gateway.dart';

typedef NavigationUrlLauncher =
    Future<bool> Function(Uri uri, launcher.LaunchMode mode);

Future<bool> _launch(Uri uri, launcher.LaunchMode mode) =>
    launcher.launchUrl(uri, mode: mode);

/// Constructs only coordinate-based, allowlisted map URLs. Native availability
/// and launch failure are separate outcomes; a browser is an explicit choice.
class UrlNavigationGateway implements NavigationGateway {
  UrlNavigationGateway({
    TargetPlatform? platform,
    Future<bool> Function(Uri)? canLaunch,
    NavigationUrlLauncher? launchUrl,
    Future<bool> Function(launcher.LaunchMode)? supportsMode,
  }) : platform = platform ?? defaultTargetPlatform,
       _canLaunch = canLaunch ?? launcher.canLaunchUrl,
       _launchUrl = launchUrl ?? _launch,
       _supportsMode = supportsMode ?? launcher.supportsLaunchMode;

  final TargetPlatform platform;
  final Future<bool> Function(Uri) _canLaunch;
  final NavigationUrlLauncher _launchUrl;
  final Future<bool> Function(launcher.LaunchMode) _supportsMode;

  @override
  Future<HandoffStatus> launch(
    NavigationApp app, {
    required RouteCoordinate destination,
    RouteCoordinate? origin,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return HandoffStatus.invalidated;
    if (!destination.isValid || (origin != null && !origin.isValid)) {
      return HandoffStatus.launchFailed;
    }
    final uri = uriFor(app, destination: destination, origin: origin);
    if (uri == null) return HandoffStatus.unavailable;
    final mode = switch (app) {
      NavigationApp.browserMap => launcher.LaunchMode.inAppBrowserView,
      NavigationApp.googleMaps
          when platform == TargetPlatform.android && origin != null =>
        launcher.LaunchMode.externalNonBrowserApplication,
      _ => launcher.LaunchMode.externalApplication,
    };
    try {
      if (!await _supportsMode(mode)) {
        return isCurrent()
            ? HandoffStatus.unavailable
            : HandoffStatus.invalidated;
      }
      if (!isCurrent()) return HandoffStatus.invalidated;
      if (app != NavigationApp.browserMap && !await _canLaunch(uri)) {
        return isCurrent()
            ? HandoffStatus.unavailable
            : HandoffStatus.invalidated;
      }
      if (!isCurrent()) return HandoffStatus.invalidated;
      final success = await _launchUrl(uri, mode);
      if (!isCurrent()) return HandoffStatus.invalidated;
      return success
          ? HandoffStatus.handoffRequested
          : HandoffStatus.launchFailed;
    } catch (_) {
      return isCurrent()
          ? HandoffStatus.launchFailed
          : HandoffStatus.invalidated;
    }
  }

  Uri? uriFor(
    NavigationApp app, {
    required RouteCoordinate destination,
    RouteCoordinate? origin,
  }) {
    if (!destination.isValid || (origin != null && !origin.isValid)) {
      return null;
    }
    switch (app) {
      case NavigationApp.appleMaps:
        if (platform != TargetPlatform.iOS) return null;
        return Uri(
          scheme: 'maps',
          host: '',
          queryParameters: {
            'daddr': destination.uriValue,
            'dirflg': 'd',
            if (origin != null) 'saddr': origin.uriValue,
          },
        );
      case NavigationApp.googleMaps:
        if (platform == TargetPlatform.iOS) {
          return Uri(
            scheme: 'comgooglemaps',
            host: '',
            queryParameters: {
              'daddr': destination.uriValue,
              'directionsmode': 'driving',
              if (origin != null) 'saddr': origin.uriValue,
            },
          );
        }
        if (platform != TargetPlatform.android) return null;
        if (origin != null) return _googleDirections(destination, origin);
        // Android's documented navigation URI is opaque (q follows the colon,
        // without '?'), unlike the hierarchical iOS and universal URLs.
        return Uri.parse(
          'google.navigation:q=${Uri.encodeComponent(destination.uriValue)}&mode=d',
        );
      case NavigationApp.browserMap:
        return _googleDirections(destination, origin);
    }
  }

  Uri _googleDirections(RouteCoordinate destination, RouteCoordinate? origin) =>
      Uri.https('www.google.com', '/maps/dir/', {
        'api': '1',
        'destination': destination.uriValue,
        'travelmode': 'driving',
        if (origin != null) 'origin': origin.uriValue,
      });
}
