import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/routes/route_repository.dart';
import '../../models/route.dart';
import '../../platform/location/location_gateway.dart';
import '../../platform/navigation/navigation_gateway.dart';

enum RoutePreviewStatus {
  idle,
  loading,
  ready,
  needsOrigin,
  unavailable,
  failed,
  invalidated,
}

/// An ephemeral preview for one immutable target/session. It has no delivery
/// repository or outbox port; neither a handoff nor a return records delivery.
class NavigationViewModel extends ChangeNotifier {
  NavigationViewModel({
    required this.scope,
    required this.target,
    required this.isCurrent,
    required this.location,
    required this.routes,
    required this.gateway,
    this.clock = DateTime.now,
    this.operationTimeout = const Duration(seconds: 8),
  });

  final NavigationScope scope;
  final NavigationTarget target;
  final bool Function() isCurrent;
  final LocationGateway location;
  final RouteRepository routes;
  final NavigationGateway gateway;
  final DateTime Function() clock;
  final Duration operationTimeout;

  RouteOrigin? _origin;
  RouteResult? _route;
  RouteFailure? _routeFailure;
  RoutePreviewStatus _routeStatus = RoutePreviewStatus.idle;
  LocationStatus _locationStatus = LocationStatus.idle;
  HandoffStatus _handoffStatus = HandoffStatus.idle;
  int _inputRevision = 0;
  int _routeSequence = 0;
  int _launchSequence = 0;
  bool _invalidated = false;
  bool _disposed = false;
  bool _backgroundObserved = false;
  bool _resumeObserved = false;
  Timer? _expiryTimer;

  bool get _originIsStale => _origin != null && !_origin!.isUsableAt(clock());
  RouteOrigin? get origin => isValid && !_originIsStale ? _origin : null;
  RouteResult? get route =>
      isValid &&
          !_originIsStale &&
          _route != null &&
          _route!.expiresAt.isAfter(clock())
      ? _route
      : null;
  RouteFailure? get routeFailure => !isValid
      ? null
      : _originIsStale
      ? RouteFailure.staleOrigin
      : _route != null && route == null
      ? RouteFailure.expiredResult
      : _routeFailure;
  RoutePreviewStatus get routeStatus => !isValid
      ? RoutePreviewStatus.invalidated
      : _route != null && route == null
      ? RoutePreviewStatus.failed
      : _routeStatus;
  LocationStatus get locationStatus => !isValid
      ? LocationStatus.invalidated
      : _originIsStale
      ? LocationStatus.stale
      : _locationStatus;
  HandoffStatus get handoffStatus =>
      isValid ? _handoffStatus : HandoffStatus.invalidated;
  int get inputRevision => _inputRevision;
  bool get isValid =>
      !_disposed &&
      !_invalidated &&
      scope.isValid &&
      target.isValid &&
      isCurrent();
  bool get isBusy =>
      isValid &&
      (_locationStatus == LocationStatus.loading ||
          _routeStatus == RoutePreviewStatus.loading ||
          _handoffStatus == HandoffStatus.checking);

  Future<void> requestPreview() async {
    if (!_guard()) return;
    final revision = _inputRevision;
    final sequence = ++_routeSequence;
    final request = RouteRequest(
      scope: scope,
      target: target,
      inputRevision: revision,
      requestId: 'navigation-$sequence',
      origin: _origin,
      departureAt: clock(),
    );
    _clearRoute();
    _routeStatus = RoutePreviewStatus.loading;
    notifyListeners();
    // A synchronous listener may change origin/session while rendering loading.
    // Recheck before any supplier call, with the already captured input.
    if (!_guard() || revision != _inputRevision || sequence != _routeSequence) {
      return;
    }
    final outcome = await routes.preview(request);
    if (!_guard() || revision != _inputRevision || sequence != _routeSequence) {
      return;
    }
    _route = outcome.route;
    _routeFailure = outcome.failure;
    _routeStatus = switch (outcome.failure) {
      null => RoutePreviewStatus.ready,
      RouteFailure.unavailable => RoutePreviewStatus.unavailable,
      RouteFailure.locationRequired => RoutePreviewStatus.needsOrigin,
      _ => RoutePreviewStatus.failed,
    };
    if (_route != null) {
      var expiry = _route!.expiresAt;
      if (_origin?.source == OriginSource.device) {
        final originExpiry = _origin!.observedAt.add(
          const Duration(minutes: 2, milliseconds: 1),
        );
        if (originExpiry.isBefore(expiry)) expiry = originExpiry;
      }
      _expiryTimer = Timer(expiry.difference(clock()), () {
        if (!_guard() || sequence != _routeSequence) return;
        final staleOrigin = _originIsStale;
        _clearRoute();
        if (staleOrigin) {
          _origin = null;
          _locationStatus = LocationStatus.stale;
        }
        _routeFailure = staleOrigin
            ? RouteFailure.staleOrigin
            : RouteFailure.expiredResult;
        _routeStatus = RoutePreviewStatus.failed;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> useMyLocation() async {
    if (!_guard()) return;
    _changeOrigin(null);
    final revision = _inputRevision;
    _locationStatus = LocationStatus.loading;
    notifyListeners();
    if (!_guard() || revision != _inputRevision) return;
    LocationResult result;
    try {
      result = await location.currentLocation().timeout(operationTimeout);
    } on TimeoutException {
      result = const LocationResult.failure(LocationStatus.timedOut);
    } catch (_) {
      result = const LocationResult.failure(LocationStatus.unavailable);
    }
    if (!_guard() || revision != _inputRevision) return;
    final value = result.origin;
    if (value != null && value.source != OriginSource.device) {
      _locationStatus = LocationStatus.unavailable;
    } else if (value != null && !value.isUsableAt(clock())) {
      _locationStatus = LocationStatus.stale;
    } else {
      if (value != null) {
        // A fix arriving after the user selected a map is a changed start,
        // just like a manual selection. Revoke the older no-origin handoff.
        _changeOrigin(value);
      }
      _locationStatus = result.status;
    }
    notifyListeners();
    await requestPreview();
  }

  Future<void> confirmManualStart(RouteCoordinate coordinate) async {
    if (!_guard()) return;
    _changeOrigin(
      coordinate.isValid
          ? RouteOrigin(
              coordinate: coordinate,
              observedAt: clock(),
              accuracyMeters: 0,
              source: OriginSource.manual,
            )
          : null,
    );
    _locationStatus = coordinate.isValid
        ? LocationStatus.ready
        : LocationStatus.unavailable;
    notifyListeners();
    await requestPreview();
  }

  Future<void> useMapsStart() async {
    if (!_guard()) return;
    _changeOrigin(null);
    _locationStatus = LocationStatus.idle;
    notifyListeners();
    await requestPreview();
  }

  Future<void> launch(NavigationApp app) async {
    if (!_guard() || _handoffStatus == HandoffStatus.checking) return;
    if (_origin != null && !_origin!.isUsableAt(clock())) {
      _changeOrigin(null);
      _locationStatus = LocationStatus.stale;
    }
    final revision = _inputRevision;
    final sequence = ++_launchSequence;
    final attemptOrigin = _origin;
    _backgroundObserved = false;
    _resumeObserved = false;
    _handoffStatus = HandoffStatus.checking;
    notifyListeners();
    bool validAttempt() =>
        isValid &&
        revision == _inputRevision &&
        sequence == _launchSequence &&
        (attemptOrigin == null || attemptOrigin.isUsableAt(clock()));
    HandoffStatus result;
    try {
      result = await gateway
          .launch(
            app,
            destination: target.coordinate,
            origin: attemptOrigin?.coordinate,
            isCurrent: validAttempt,
          )
          .timeout(operationTimeout);
    } on TimeoutException {
      if (!_guard() ||
          revision != _inputRevision ||
          sequence != _launchSequence) {
        return;
      }
      // Revoking the token also prevents a late availability check from
      // dispatching an OS launch after the caller has timed out.
      _launchSequence++;
      _handoffStatus = HandoffStatus.launchFailed;
      notifyListeners();
      return;
    } catch (_) {
      result = HandoffStatus.launchFailed;
    }
    if (!_guard() ||
        revision != _inputRevision ||
        sequence != _launchSequence) {
      return;
    }
    if (attemptOrigin != null && !attemptOrigin.isUsableAt(clock())) {
      _changeOrigin(null);
      _locationStatus = LocationStatus.stale;
      _routeStatus = RoutePreviewStatus.failed;
      _routeFailure = RouteFailure.staleOrigin;
      _handoffStatus = HandoffStatus.launchFailed;
      notifyListeners();
      return;
    }
    // Only a successful platform receipt can combine with lifecycle return.
    _handoffStatus =
        result == HandoffStatus.handoffRequested &&
            _backgroundObserved &&
            _resumeObserved
        ? HandoffStatus.returned
        : result;
    notifyListeners();
  }

  void markBackgrounded() {
    if (!_guard()) return;
    if (_handoffStatus == HandoffStatus.checking ||
        _handoffStatus == HandoffStatus.handoffRequested) {
      _backgroundObserved = true;
      _resumeObserved = false;
    }
  }

  void resume() {
    if (!_guard()) return;
    if (!_backgroundObserved) return;
    _resumeObserved = true;
    if (_handoffStatus == HandoffStatus.handoffRequested) {
      _handoffStatus = HandoffStatus.returned;
      notifyListeners();
    }
  }

  void _changeOrigin(RouteOrigin? value) {
    _inputRevision++;
    _routeSequence++;
    _launchSequence++;
    _origin = value;
    _clearRoute();
    _routeStatus = RoutePreviewStatus.idle;
    _handoffStatus = HandoffStatus.idle;
    _backgroundObserved = false;
    _resumeObserved = false;
  }

  void _clearRoute() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _route = null;
    _routeFailure = null;
  }

  bool _guard() {
    if (isValid) return true;
    if (!_disposed && !_invalidated) invalidate();
    return false;
  }

  void invalidate() {
    if (_disposed || _invalidated) return;
    _invalidated = true;
    _inputRevision++;
    _routeSequence++;
    _launchSequence++;
    _origin = null;
    _clearRoute();
    _locationStatus = LocationStatus.invalidated;
    _routeStatus = RoutePreviewStatus.invalidated;
    _handoffStatus = HandoffStatus.invalidated;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    super.dispose();
  }
}
