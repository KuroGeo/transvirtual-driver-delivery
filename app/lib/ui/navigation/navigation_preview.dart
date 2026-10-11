import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../models/route.dart';
import '../../platform/location/location_gateway.dart';
import '../../platform/navigation/navigation_gateway.dart';
import '../core/brand_theme.dart';
import 'navigation_view_model.dart';

/// A route sheet over the retained workbench, with no delivery write capability.
class NavigationPreview extends StatefulWidget {
  const NavigationPreview({
    super.key,
    required this.viewModel,
    required this.onReturn,
    required this.tileUrlTemplate,
  });

  final NavigationViewModel viewModel;
  final VoidCallback onReturn;
  final String tileUrlTemplate;

  @override
  State<NavigationPreview> createState() => _NavigationPreviewState();
}

class _NavigationPreviewState extends State<NavigationPreview>
    with WidgetsBindingObserver {
  bool _choosingMap = false;
  bool _copied = false;
  NavigationViewModel get model => widget.viewModel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(model.requestPreview());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      model.resume();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      model.markBackgrounded();
    }
  }

  Future<void> _manualStart() async {
    final coordinate = await showDialog<RouteCoordinate>(
      context: context,
      builder: (_) => const _ManualStartDialog(),
    );
    if (mounted && coordinate != null && model.isValid) {
      await model.confirmManualStart(coordinate);
    }
  }

  Future<void> _copyAddress() async {
    if (!model.isValid) return;
    try {
      await Clipboard.setData(ClipboardData(text: model.target.address));
      if (mounted && model.isValid) setState(() => _copied = true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not copy the address.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: model,
    builder: (context, _) {
      final valid = model.isValid;
      return FractionallySizedBox(
        key: const ValueKey('navigation-preview'),
        heightFactor: MediaQuery.textScalerOf(context).scale(16) > 28
            ? .92
            : .72,
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _choosingMap ? 'Choose navigator' : 'Directions to',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('navigation-close'),
                      tooltip: 'Return to delivery',
                      onPressed: widget.onReturn,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  key: const ValueKey('navigation-scroll'),
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: valid
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              model.target.label,
                              key: const ValueKey('navigation-destination'),
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 8),
                            Text(model.target.address),
                            const SizedBox(height: 20),
                            if (_choosingMap)
                              ..._mapChoices()
                            else ...[
                              _route(context),
                              const SizedBox(height: 16),
                              _location(context),
                              const SizedBox(height: 12),
                              const Text(
                                'Your map app calculates its own route. Confirm arrival and delivery yourself when you return.',
                                style: TextStyle(color: OceanColors.muted),
                              ),
                            ],
                            if (model.handoffStatus != HandoffStatus.idle) ...[
                              const SizedBox(height: 16),
                              Semantics(
                                liveRegion: true,
                                child: Text(
                                  _handoffMessage(model.handoffStatus),
                                  key: const ValueKey(
                                    'navigation-handoff-state',
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            TextButton.icon(
                              key: const ValueKey('navigation-copy-address'),
                              onPressed: _copyAddress,
                              icon: const Icon(Icons.copy_outlined),
                              label: Text(
                                _copied ? 'Address copied' : 'Copy address',
                              ),
                            ),
                          ],
                        )
                      : const Text(
                          'This stop or session has changed. Close directions and select a current delivery.',
                          key: ValueKey('navigation-invalidated'),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (valid && !_choosingMap)
                      FilledButton.icon(
                        key: const ValueKey('navigation-choose-map'),
                        onPressed: model.handoffStatus == HandoffStatus.checking
                            ? null
                            : () => setState(() => _choosingMap = true),
                        icon: const Icon(Icons.north_east),
                        label: const Text('Open map navigation'),
                      ),
                    TextButton(
                      key: const ValueKey('navigation-return-detail'),
                      onPressed: widget.onReturn,
                      child: const Text('View delivery details'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  List<Widget> _mapChoices() => [
    const Text('Choose a map app, or open directions in a browser.'),
    const SizedBox(height: 12),
    for (final app in NavigationApp.values) ...[
      OutlinedButton.icon(
        key: ValueKey('navigation-app-${app.name}'),
        onPressed: model.handoffStatus == HandoffStatus.checking
            ? null
            : () async {
                await model.launch(app);
                if (mounted &&
                    model.isValid &&
                    model.handoffStatus == HandoffStatus.handoffRequested) {
                  setState(() => _choosingMap = false);
                }
              },
        icon: const Icon(Icons.map_outlined),
        label: Text(switch (app) {
          NavigationApp.appleMaps => 'Apple Maps',
          NavigationApp.googleMaps => 'Google Maps',
          NavigationApp.browserMap => 'Browser directions',
        }),
      ),
      const SizedBox(height: 8),
    ],
  ];

  Widget _route(BuildContext context) {
    final result = model.route;
    if (result == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              switch (model.routeStatus) {
                RoutePreviewStatus.loading => 'Looking up a road route…',
                RoutePreviewStatus.needsOrigin =>
                  'Choose a start to preview a route, or let your map app choose.',
                RoutePreviewStatus.failed =>
                  'Road preview could not be loaded. You can still open map navigation.',
                _ =>
                  'In-app road preview is unavailable. You can still open map navigation.',
              },
              key: const ValueKey('navigation-route-state'),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          if (model.routeStatus == RoutePreviewStatus.failed)
            TextButton(
              key: const ValueKey('navigation-retry-route'),
              onPressed: model.requestPreview,
              child: Text(
                model.routeFailure == RouteFailure.expiredResult
                    ? 'Route expired · refresh'
                    : 'Retry road preview',
              ),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 24,
          runSpacing: 12,
          children: [
            Text('${result.duration.inMinutes} min'),
            Text('${(result.distanceMeters / 1000).toStringAsFixed(1)} km'),
            Text('Arrival ${_time(result.arrivalAt)}'),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${result.provider} · ${result.trafficAware ? 'traffic-aware estimate' : 'static road estimate, no live traffic'}\nComputed ${_time(result.computedAt)} · valid until ${_time(result.expiresAt)}',
          key: const ValueKey('navigation-route-state'),
        ),
        if (result.licenseAllowsMapOverlay) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 180,
            child: FlutterMap(
              options: MapOptions(
                initialCameraFit: CameraFit.coordinates(
                  coordinates: [
                    for (final point in result.geometry)
                      LatLng(point.latitude, point.longitude),
                  ],
                  padding: const EdgeInsets.all(20),
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: widget.tileUrlTemplate,
                  userAgentPackageName: 'dev.oceandelivery.oceanDelivery',
                ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [
                        for (final point in result.geometry)
                          LatLng(point.latitude, point.longitude),
                      ],
                      color: OceanColors.orange,
                      strokeWidth: 5,
                    ),
                  ],
                ),
                const Align(
                  alignment: Alignment.bottomRight,
                  child: ColoredBox(
                    color: OceanColors.cream,
                    child: Text('© OpenStreetMap contributors'),
                  ),
                ),
              ],
            ),
          ),
        ],
        TextButton(
          onPressed: model.requestPreview,
          child: const Text('Refresh route'),
        ),
      ],
    );
  }

  Widget _location(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(switch (model.locationStatus) {
        LocationStatus.permissionDenied ||
        LocationStatus.permissionDeniedForever =>
          'Location permission was denied. Choose a start or use your map app.',
        LocationStatus.serviceDisabled =>
          'Location services are off. Your map app can choose the start.',
        LocationStatus.stale =>
          'This location is too old or imprecise. Choose a fresh start.',
        LocationStatus.timedOut || LocationStatus.unavailable =>
          'Location could not be obtained. You can still open a map.',
        LocationStatus.loading => 'Getting your location…',
        _ =>
          model.origin == null
              ? 'Start: chosen in your map app'
              : 'Start: ${model.origin!.source == OriginSource.manual ? 'confirmed coordinates' : 'device location'}',
      }, key: const ValueKey('navigation-location-state')),
      TextButton.icon(
        key: const ValueKey('navigation-use-location'),
        onPressed: model.locationStatus == LocationStatus.loading
            ? null
            : model.useMyLocation,
        icon: const Icon(Icons.my_location),
        label: const Text('Use my location'),
      ),
      TextButton(
        key: const ValueKey('navigation-manual-start'),
        onPressed: _manualStart,
        child: const Text('Choose starting coordinates'),
      ),
      if (model.origin != null)
        TextButton(
          key: const ValueKey('navigation-maps-start'),
          onPressed: model.useMapsStart,
          child: const Text('Let map app choose the start'),
        ),
    ],
  );

  String _time(DateTime time) {
    final local = time.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _handoffMessage(HandoffStatus status) => switch (status) {
    HandoffStatus.checking => 'Opening your chosen map…',
    HandoffStatus.unavailable =>
      'This map is unavailable. Choose another option or copy the address.',
    HandoffStatus.launchFailed =>
      'The map could not open. Try another option or copy the address.',
    HandoffStatus.handoffRequested =>
      'Directions handed to your map. Return here to record the delivery.',
    HandoffStatus.returned =>
      'Welcome back. Review the delivery and confirm the result yourself.',
    HandoffStatus.invalidated =>
      'The delivery or session changed. Select a current stop.',
    HandoffStatus.idle => '',
  };
}

class _ManualStartDialog extends StatefulWidget {
  const _ManualStartDialog();

  @override
  State<_ManualStartDialog> createState() => _ManualStartDialogState();
}

class _ManualStartDialogState extends State<_ManualStartDialog> {
  final latitude = TextEditingController();
  final longitude = TextEditingController();
  final form = GlobalKey<FormState>();

  @override
  void dispose() {
    latitude.dispose();
    longitude.dispose();
    super.dispose();
  }

  String? validate(String? text, double limit) {
    final number = double.tryParse(text?.trim() ?? '');
    return number == null || !number.isFinite || number.abs() > limit
        ? 'Enter a coordinate from -$limit to $limit.'
        : null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Choose a starting point'),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Confirm the coordinates of your starting point.'),
            const SizedBox(height: 16),
            TextFormField(
              key: const ValueKey('navigation-start-latitude'),
              controller: latitude,
              decoration: const InputDecoration(labelText: 'Latitude'),
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
              validator: (text) => validate(text, 90),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('navigation-start-longitude'),
              controller: longitude,
              decoration: const InputDecoration(labelText: 'Longitude'),
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
              validator: (text) => validate(text, 180),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('navigation-confirm-start'),
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.of(context).pop(
              RouteCoordinate(
                double.parse(latitude.text.trim()),
                double.parse(longitude.text.trim()),
              ),
            );
          }
        },
        child: const Text('Use this start'),
      ),
    ],
  );
}
