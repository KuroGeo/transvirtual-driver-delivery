import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';

import '../../../models/delivery.dart';
import '../../../models/workbench.dart';
import '../../core/brand_icon.dart';
import '../../core/brand_theme.dart';
import '../list/stop_status_badge.dart';
import '../query/workbench_query.dart';
import '../query/workbench_session.dart';
import 'map_viewport.dart';

enum MapTileStatus { loading, ready, error }

/// Clears flutter_map's native HTTP tile cache, not delivery data or settings.
/// Server freshness remains in force; this is not an offline map download.
Future<void> clearBuiltInTileCache() =>
    BuiltInMapCachingProvider.getOrCreateInstance().destroy(deleteCache: true);

/// Cached images may finish synchronously. Load/prune after the inherited
/// camera rebuild so flutter_map cannot prune new tiles using the old camera.
TileUpdateTransformer _frameAlignedTileUpdates() =>
    TileUpdateTransformer.fromBind((events) {
      StreamSubscription<TileUpdateEvent>? upstream;
      TileUpdateEvent? pending;
      var active = true;
      var frameQueued = false;
      var upstreamDone = false;
      late final StreamController<TileUpdateEvent> output;

      void scheduleFlush() {
        if (!active || frameQueued || output.isPaused) return;
        frameQueued = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          frameQueued = false;
          if (!active || output.isPaused) return;
          final event = pending;
          pending = null;
          if (event != null) output.add(event);
          if (active && upstreamDone) unawaited(output.close());
        });
        WidgetsBinding.instance.scheduleFrame();
      }

      output = StreamController<TileUpdateEvent>(
        sync: true,
        onListen: () {
          upstream = events.listen(
            (event) {
              if (event.wasTriggeredByTap()) return;
              pending = event;
              scheduleFlush();
            },
            onError: output.addError,
            onDone: () {
              upstreamDone = true;
              if (pending == null) {
                unawaited(output.close());
              } else {
                scheduleFlush();
              }
            },
          );
        },
        onPause: () => upstream?.pause(),
        onResume: () {
          upstream?.resume();
          if (pending != null) scheduleFlush();
        },
        onCancel: () async {
          active = false;
          pending = null;
          await upstream?.cancel();
        },
      );
      return output.stream;
    });

/// Keep this controller and the workspace mounted across Toast/card updates.
/// A provided controller is disposed by its caller after removing the widget.
class DeliveryMapController {
  final MapController mapController = MapController();
  final ValueNotifier<MapTileStatus> tileStatus = ValueNotifier(
    MapTileStatus.loading,
  );
  _DeliveryMapWorkspaceState? _workspace;

  bool get isReady => _workspace?._ready ?? false;
  void zoomIn() => _workspace?._zoomBy(1);
  void zoomOut() => _workspace?._zoomBy(-1);
  void fitMatches() => _workspace?._fitMatches();

  /// Explicit selection action; call after updating the host's detail padding.
  void focusStop(Stop stop) => _workspace?._focusStop(stop);
  void locateTestReference() => _workspace?._locate();
  void retryTiles() => _workspace?._retryTiles();
  Future<void> clearTileCache() =>
      _workspace?._clearTileCache() ?? Future<void>.value();

  void dispose() {
    assert(
      _workspace == null,
      'Remove the map before disposing its controller.',
    );
    mapController.dispose();
    tileStatus.dispose();
  }
}

/// Map-only workspace; the host overlays search, overview and detail panels.
/// The shared [result] is never restricted by the current map viewport.
class DeliveryMapWorkspace extends StatefulWidget {
  const DeliveryMapWorkspace({
    super.key,
    required this.result,
    required this.datasetId,
    required this.onOpenStop,
    this.initialViewport,
    this.controller,
    this.tileUrlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    this.tileProvider,
    this.fitPadding = const EdgeInsets.fromLTRB(38, 205, 38, 220),
    this.fitPaddingBuilder,
    this.toolbarTop = 220,
    this.showTools = true,
    this.showTileError = true,
    this.overlayBuilder,
    this.selectedStopId,
    this.onViewportChanged,
    this.onSync,
    this.syncing = false,
    this.onAttributionTap,
    this.tileCacheClearer = clearBuiltInTileCache,
  });

  final WorkbenchResult result;
  final String datasetId;
  final void Function(Stop stop, DetailOrigin origin) onOpenStop;
  final MapViewport? initialViewport;
  final DeliveryMapController? controller;
  final String tileUrlTemplate;

  /// Fixed for this workspace lifetime and transferred for disposal.
  /// Tests must inject a fixture; a URL may change without replacing the map.
  final TileProvider? tileProvider;
  final EdgeInsets fitPadding;

  /// Evaluated only on explicit fit/focus with the actual area excluding footer.
  final EdgeInsets Function(BoxConstraints constraints)? fitPaddingBuilder;
  final double toolbarTop;
  final bool showTools;
  final bool showTileError;

  /// Host overlays share only the map area; attribution remains outside it.
  final Widget Function(BuildContext context, BoxConstraints constraints)?
  overlayBuilder;
  final String? selectedStopId;
  final ValueChanged<MapViewport>? onViewportChanged;
  final VoidCallback? onSync;
  final bool syncing;
  final VoidCallback? onAttributionTap;

  /// Controlled cache fixture hook; defaults to the real built-in cache API.
  final Future<void> Function() tileCacheClearer;

  @override
  State<DeliveryMapWorkspace> createState() => _DeliveryMapWorkspaceState();
}

class _DeliveryMapWorkspaceState extends State<DeliveryMapWorkspace> {
  static const _defaultCenter = LatLng(-33.884, 151.117);
  static const _reference = LatLng(
    TestReference.latitude,
    TestReference.longitude,
  );
  static const _userAgent =
      'OceanDelivery/0.1 (+https://github.com/KuroGeo/transvirtual-driver-delivery)';

  late final DeliveryMapController _controller;
  late final bool _ownsController;
  BoxConstraints? _mapConstraints;
  late TileProvider _provider;
  late _TileProviderHandle _providerHandle;
  late MapViewport? _initialViewport;
  late List<Marker> _markers;
  Map<String, Stop> _stopsById = const {};
  final _tileReset = StreamController<void>.broadcast();
  late final _tileUpdates = _frameAlignedTileUpdates();
  final _tiles = <TileCoordinates, TileImage>{};
  final _tileImages = <ImageProvider>{};
  Timer? _viewportTimer;
  bool _ready = false;
  bool _tileStatusScheduled = false;
  bool _tilesPaused = false;
  int _tileGeneration = 0;
  Future<void>? _clearing;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? DeliveryMapController();
    assert(
      _controller._workspace == null,
      'A controller owns one map at a time.',
    );
    _controller._workspace = this;
    _initialViewport = validMapViewport(
      widget.initialViewport,
      widget.datasetId,
    );
    _provider = _createProvider();
    _providerHandle = _TileProviderHandle(_provider, _tileImages.add);
    _rebuildMarkers();
  }

  TileProvider _createProvider() =>
      widget.tileProvider ??
      NetworkTileProvider(
        headers: {'User-Agent': _userAgent},
        // The default native cache reads server HTTP freshness/conditional headers.
        // No overrideFreshAge, no prefetch, no no-cache request headers.
      );

  @override
  void didUpdateWidget(covariant DeliveryMapWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      oldWidget.controller == widget.controller,
      'Retain the map controller.',
    );
    assert(
      oldWidget.tileProvider == widget.tileProvider,
      'Retain the tile provider for this workspace lifetime.',
    );
    if (!identical(oldWidget.result, widget.result) ||
        oldWidget.selectedStopId != widget.selectedStopId) {
      _rebuildMarkers();
    }
    if (oldWidget.datasetId != widget.datasetId) {
      _viewportTimer?.cancel();
      _initialViewport = validMapViewport(
        widget.initialViewport,
        widget.datasetId,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_ready) return;
        final viewport = _initialViewport;
        _controller.mapController.move(
          viewport == null
              ? _defaultCenter
              : LatLng(viewport.latitude, viewport.longitude),
          viewport?.zoom ?? 11,
        );
      });
    }
  }

  void _rebuildMarkers() {
    _stopsById = {for (final stop in widget.result.stops) stop.id: stop};
    _markers = [
      for (final stop in widget.result.stops)
        Marker(
          key: ValueKey(stop.id),
          point: LatLng(stop.latitude, stop.longitude),
          width: 44,
          height: 44,
          child: _StopMarker(
            key: ValueKey('map-stop-${stop.reference}'),
            stop: stop,
            selected: stop.id == widget.selectedStopId,
            waiting: widget.result.awaitsService(stop),
            onTap: () => widget.onOpenStop(stop, DetailOrigin.map),
          ),
        ),
    ];
  }

  void _zoomBy(double delta) {
    if (!_ready) return;
    final camera = _controller.mapController.camera;
    _controller.mapController.move(
      camera.center,
      (camera.zoom + delta).clamp(0, 22),
    );
    _scheduleViewport();
  }

  void _fitMatches() {
    if (!_ready || widget.result.stops.isEmpty) return;
    _fitPoints(_markers.map((marker) => marker.point).toList());
  }

  void _focusStop(Stop stop) =>
      _fitPoints([LatLng(stop.latitude, stop.longitude)]);

  void _fitPoints(List<LatLng> points) {
    if (!_ready || points.isEmpty) return;
    final constraints = _mapConstraints;
    final padding = constraints == null
        ? widget.fitPadding
        : widget.fitPaddingBuilder?.call(constraints) ?? widget.fitPadding;
    _controller.mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: points,
        padding: padding,
        minZoom: 0,
        maxZoom: 15,
      ),
    );
    _scheduleViewport();
  }

  void _locate() {
    if (!_ready) return;
    final camera = _controller.mapController.camera;
    _controller.mapController.move(_reference, math.max(14, camera.zoom));
    _scheduleViewport();
  }

  void _mapEvent(MapEvent event) {
    // End events coalesce. A following fling cancels the earlier drag end.
    if (event is MapEventMoveStart ||
        event is MapEventFlingAnimationStart ||
        event is MapEventDoubleTapZoomStart) {
      _viewportTimer?.cancel();
    } else if (event is MapEventMoveEnd ||
        event is MapEventFlingAnimationEnd ||
        event is MapEventDoubleTapZoomEnd ||
        event is MapEventRotateEnd ||
        event.source == MapEventSource.scrollWheel ||
        event.source == MapEventSource.keyboard) {
      _scheduleViewport();
    }
  }

  void _scheduleViewport() {
    _viewportTimer?.cancel();
    _viewportTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || !_ready) return;
      final camera = _controller.mapController.camera;
      final viewport = validMapViewport(
        MapViewport(
          datasetId: widget.datasetId,
          latitude: camera.center.latitude,
          longitude: camera.center.longitude,
          zoom: camera.zoom,
        ),
        widget.datasetId,
      );
      if (viewport != null) widget.onViewportChanged?.call(viewport);
    });
  }

  void _observeTile(TileImage tile, {bool remove = false}) {
    if (remove) {
      if (identical(_tiles[tile.coordinates], tile)) {
        _tiles.remove(tile.coordinates);
      }
    } else {
      _tiles[tile.coordinates] = tile;
    }
    if (_tileStatusScheduled) return;
    _tileStatusScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tileStatusScheduled = false;
      if (!mounted || _tilesPaused) return;
      final status = _tiles.values.any((tile) => tile.loadError)
          ? MapTileStatus.error
          : _tiles.isNotEmpty &&
                _tiles.values.every((tile) => tile.loadFinishedAt != null)
          ? MapTileStatus.ready
          : MapTileStatus.loading;
      _controller.tileStatus.value = status;
    });
  }

  void _retryTiles() {
    if (!mounted || _tilesPaused) return;
    _tiles.clear();
    _controller.tileStatus.value = MapTileStatus.loading;
    _tileReset.add(null);
  }

  Future<void> _clearTileCache() {
    final clearing = _clearing;
    if (clearing != null) return clearing;
    final future = _performCacheClear().whenComplete(() => _clearing = null);
    _clearing = future;
    return future;
  }

  Future<void> _performCacheClear() async {
    setState(() => _tilesPaused = true);
    // Dispose visible tiles first, cancelling obsolete tile requests.
    await WidgetsBinding.instance.endOfFrame;
    try {
      await widget.tileCacheClearer();
      await Future.wait(_tileImages.map((image) => image.evict()));
      _tileImages.clear();
    } finally {
      if (mounted && widget.tileProvider == null) {
        _provider.dispose();
        _provider = _createProvider();
        _providerHandle = _TileProviderHandle(_provider, _tileImages.add);
      }
      _tiles.clear();
      if (mounted) {
        _controller.tileStatus.value = MapTileStatus.loading;
        setState(() {
          _tileGeneration++;
          _tilesPaused = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _viewportTimer?.cancel();
    _controller._workspace = null;
    _tileReset.close();
    _provider.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initial = _initialViewport;
    return Column(
      key: const ValueKey('map-workspace'),
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _mapConstraints = constraints;
              return Stack(
                fit: StackFit.expand,
                children: [
                  FlutterMap(
                    key: const ValueKey('delivery-map'),
                    mapController: _controller.mapController,
                    options: MapOptions(
                      initialCenter: initial == null
                          ? _defaultCenter
                          : LatLng(initial.latitude, initial.longitude),
                      initialZoom: initial?.zoom ?? 11,
                      minZoom: 0,
                      maxZoom: 22,
                      keepAlive: true,
                      backgroundColor: const Color(0xFFEEE8DC),
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                      ),
                      onMapReady: () {
                        if (mounted) setState(() => _ready = true);
                      },
                      onMapEvent: _mapEvent,
                    ),
                    children: [
                      if (!_tilesPaused)
                        TileLayer(
                          key: ValueKey('map-tiles-$_tileGeneration'),
                          urlTemplate: widget.tileUrlTemplate,
                          tileProvider: _providerHandle,
                          userAgentPackageName: 'com.oceandelivery.driver',
                          minZoom: 0,
                          maxZoom: 22,
                          maxNativeZoom: 19,
                          keepBuffer: 1,
                          panBuffer: 0,
                          tileDisplay: const TileDisplay.instantaneous(),
                          tileUpdateTransformer: _tileUpdates,
                          evictErrorTileStrategy:
                              EvictErrorTileStrategy.dispose,
                          reset: _tileReset.stream,
                          tileBuilder: (_, tileWidget, tile) =>
                              _TileObservation(
                                tile: tile,
                                onChanged: _observeTile,
                                child: tileWidget,
                              ),
                        ),
                      MarkerClusterLayerWidget(
                        options: MarkerClusterLayerOptions(
                          markers: _markers,
                          size: const Size(52, 52),
                          maxClusterRadius: 48,
                          disableClusteringAtZoom: 14,
                          markerChildBehavior: true,
                          centerMarkerOnClick: false,
                          zoomToBoundsOnClick: false,
                          spiderfyCluster: false,
                          showPolygon: false,
                          animationsOptions: const AnimationsOptions(
                            zoom: Duration.zero,
                            fitBound: Duration.zero,
                            centerMarker: Duration.zero,
                            spiderfy: Duration.zero,
                          ),
                          onClusterTap: (cluster) => _fitPoints(
                            cluster.mapMarkers
                                .map((marker) => marker.point)
                                .toList(),
                          ),
                          builder: (_, markers) {
                            final stops = markers
                                .map(
                                  (marker) =>
                                      _stopsById[(marker.key!
                                              as ValueKey<String>)
                                          .value]!,
                                )
                                .toList();
                            return _ClusterBadge(
                              stops: stops,
                              onTap: () => _fitPoints(
                                markers.map((marker) => marker.point).toList(),
                              ),
                            );
                          },
                        ),
                      ),
                      const MarkerLayer(
                        markers: [
                          Marker(
                            point: _reference,
                            width: 44,
                            height: 44,
                            child: _TestReferenceMarker(),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (widget.showTools)
                    Positioned(
                      left: 13,
                      top: widget.toolbarTop,
                      child: _toolbar(),
                    ),
                  if (widget.showTileError)
                    Positioned(
                      top: 12,
                      left: 13,
                      right: 13,
                      child: ValueListenableBuilder<MapTileStatus>(
                        valueListenable: _controller.tileStatus,
                        builder: (_, status, _) => status == MapTileStatus.error
                            ? _errorBanner()
                            : const SizedBox.shrink(),
                      ),
                    ),
                  if (widget.overlayBuilder != null)
                    widget.overlayBuilder!(context, constraints),
                ],
              );
            },
          ),
        ),
        Material(
          color: OceanColors.cream,
          child: InkWell(
            key: const ValueKey('map-attribution'),
            onTap: widget.onAttributionTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              child: Row(
                children: [
                  const Icon(
                    Icons.near_me_outlined,
                    size: 13,
                    color: Color(0xFF376BBA),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      TestReference.label,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  Flexible(
                    child: Text(
                      '© OpenStreetMap contributors',
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolbar() => Material(
    color: OceanColors.cream,
    elevation: 2,
    borderRadius: BorderRadius.circular(14),
    clipBehavior: Clip.antiAlias,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tool('zoom-in', 'Zoom in', Icons.add, _controller.zoomIn),
            _tool('zoom-out', 'Zoom out', Icons.remove, _controller.zoomOut),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tool(
              'fit-stops',
              'Fit matching stops',
              Icons.crop_free,
              widget.result.stops.isEmpty ? null : _controller.fitMatches,
            ),
            _tool(
              'locate-reference',
              'Locate test reference',
              Icons.near_me_outlined,
              _controller.locateTestReference,
            ),
          ],
        ),
        if (widget.onSync != null) ...[
          const SizedBox(width: 88, child: Divider(height: 1)),
          SizedBox(
            width: 88,
            height: 44,
            child: IconButton(
              key: const ValueKey('map-sync'),
              tooltip: widget.syncing
                  ? 'Syncing saved updates'
                  : 'Sync saved updates',
              icon: SyncActionIcon(syncing: widget.syncing),
              onPressed: _ready ? widget.onSync : null,
            ),
          ),
        ],
      ],
    ),
  );

  Widget _tool(String key, String label, IconData icon, VoidCallback? action) =>
      SizedBox(
        width: 44,
        height: 44,
        child: IconButton(
          key: ValueKey(key),
          tooltip: label,
          icon: Icon(icon, size: 20),
          onPressed: _ready ? action : null,
        ),
      );

  Widget _errorBanner() => Material(
    color: OceanColors.cream,
    elevation: 2,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          const Icon(Icons.map_outlined, size: 19, color: OceanColors.muted),
          const SizedBox(width: 8),
          const Expanded(child: Text('Map unavailable. Stops still work.')),
          TextButton(
            key: const ValueKey('retry-map'),
            onPressed: _controller.retryTiles,
            child: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}

// TileLayer normally disposes its provider on reset/removal. Ownership is at
// workspace level so cache clear can briefly remove tiles while retaining an
// injected fixture, and can replace the default provider after cache teardown.
class _TileProviderHandle extends TileProvider {
  _TileProviderHandle(this.delegate, this.onImage)
    : super(headers: delegate.headers);
  final TileProvider delegate;
  final void Function(ImageProvider) onImage;
  @override
  bool get supportsCancelLoading => delegate.supportsCancelLoading;
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final image = delegate.getImage(coordinates, options);
    onImage(image);
    return image;
  }

  @override
  ImageProvider getImageWithCancelLoadingSupport(
    TileCoordinates coordinates,
    TileLayer options,
    Future<void> cancelLoading,
  ) {
    final image = delegate.getImageWithCancelLoadingSupport(
      coordinates,
      options,
      cancelLoading,
    );
    onImage(image);
    return image;
  }

  @override
  void dispose() {}
}

class _TileObservation extends StatefulWidget {
  const _TileObservation({
    required this.tile,
    required this.onChanged,
    required this.child,
  });
  final TileImage tile;
  final void Function(TileImage tile, {bool remove}) onChanged;
  final Widget child;
  @override
  State<_TileObservation> createState() => _TileObservationState();
}

class _TileObservationState extends State<_TileObservation> {
  void _changed() => widget.onChanged(widget.tile);
  @override
  void initState() {
    super.initState();
    widget.tile.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(covariant _TileObservation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.tile, widget.tile)) return;
    oldWidget.tile.removeListener(_changed);
    oldWidget.onChanged(oldWidget.tile, remove: true);
    widget.tile.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    widget.tile.removeListener(_changed);
    widget.onChanged(widget.tile, remove: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _StopMarker extends StatelessWidget {
  const _StopMarker({
    super.key,
    required this.stop,
    required this.selected,
    required this.waiting,
    required this.onTap,
  });
  final Stop stop;
  final bool selected;
  final bool waiting;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final label =
        'Open ${stop.customerName}, ${stop.reference}, ${deliveryStatusLabel(stop.status)}${waiting ? ', Waiting to sync' : ''}';
    final color = deliveryStatusColor(stop.status);
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Tooltip(
          message: label,
          child: Material(
            color: color,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                stop.status == DeliveryStatus.failed ? 9 : 22,
              ),
              side: BorderSide(
                color: OceanColors.cream,
                width: selected ? 4 : 2,
              ),
            ),
            elevation: selected ? 5 : 2,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(22),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    deliveryStatusIcon(stop.status),
                    size: 23,
                    color: OceanColors.cream,
                  ),
                  if (waiting)
                    Positioned(
                      right: 2,
                      top: 2,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: OceanColors.cream,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ClusterBadge extends StatelessWidget {
  const _ClusterBadge({required this.stops, required this.onTap});
  final List<Stop> stops;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final counts = {
      for (final status in DeliveryStatus.values)
        status: stops.where((stop) => stop.status == status).length,
    };
    final present = DeliveryStatus.values
        .where((status) => counts[status]! > 0)
        .toList();
    final colors = <Color>[];
    final offsets = <double>[];
    var portion = 0.0;
    for (final status in present) {
      colors.addAll([deliveryStatusColor(status), deliveryStatusColor(status)]);
      offsets.add(math.min(1, portion));
      portion += counts[status]! / stops.length;
      offsets.add(math.min(1, portion));
    }
    final references = stops.map((stop) => stop.reference).toList()..sort();
    return Semantics(
      key: ValueKey('map-cluster-${references.join('-')}'),
      button: true,
      label:
          'Zoom to ${stops.length} stops: ${DeliveryStatus.values.map((status) => '${counts[status]} ${deliveryStatusLabel(status)}').join(', ')}',
      onTap: onTap,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(colors: colors, stops: offsets),
            border: Border.all(color: OceanColors.cream, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x403D281B),
                blurRadius: 7,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Container(
            decoration: const BoxDecoration(
              color: OceanColors.cream,
              shape: BoxShape.circle,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${stops.length}',
                  textScaler: const TextScaler.linear(1),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: OceanColors.ink,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final status in present)
                      Icon(
                        deliveryStatusIcon(status),
                        size: 9,
                        color: deliveryStatusColor(status),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TestReferenceMarker extends StatelessWidget {
  const _TestReferenceMarker();
  @override
  Widget build(BuildContext context) => Semantics(
    key: const ValueKey('test-reference-marker'),
    label:
        'Test reference, fixed heading ${TestReference.headingDegrees.toInt()} degrees',
    child: ExcludeSemantics(
      // Keep the geographic graphic bounded. Its scalable label lives in the
      // always-visible footer, where it can wrap without shifting this anchor.
      child: Center(
        child: Transform.rotate(
          angle: TestReference.headingDegrees * math.pi / 180,
          child: const Icon(
            Icons.navigation,
            size: 29,
            color: Color(0xFF376BBA),
          ),
        ),
      ),
    ),
  );
}
