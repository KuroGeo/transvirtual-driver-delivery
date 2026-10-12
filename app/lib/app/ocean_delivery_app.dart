import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../ui/delivery/map/delivery_map_workspace.dart';
import '../data/routes/route_repository.dart';
import '../platform/location/location_gateway.dart';
import '../platform/navigation/navigation_gateway.dart';
import '../ui/navigation/navigation_view_model.dart';

import '../ui/delivery_screen.dart';
import '../ui/delivery_view_model.dart';
import '../ui/core/brand_theme.dart';

class OceanDeliveryApp extends StatefulWidget {
  const OceanDeliveryApp({
    super.key,
    required this.createViewModel,
    this.demo = false,
    this.tileProvider,
    this.mapController,
    this.routeRepository,
    this.locationGateway,
    this.navigationGateway,
    this.onNavigationChanged,
    this.tileUrlTemplate = const String.fromEnvironment(
      'OCEAN_TILE_URL',
      defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    ),
  });

  final Future<DeliveryViewModel> Function() createViewModel;
  final bool demo;
  final TileProvider? tileProvider;
  final DeliveryMapController? mapController;
  final RouteRepository? routeRepository;
  final LocationGateway? locationGateway;
  final NavigationGateway? navigationGateway;
  final ValueChanged<NavigationViewModel?>? onNavigationChanged;
  final String tileUrlTemplate;

  @override
  State<OceanDeliveryApp> createState() => _OceanDeliveryAppState();
}

class _OceanDeliveryAppState extends State<OceanDeliveryApp> {
  DeliveryViewModel? _viewModel;
  bool _booting = true;
  String? _bootstrapError;
  Future<void>? _opening;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() {
    final opening = _opening;
    if (opening != null) return opening;
    final future = Future<void>.microtask(
      _open,
    ).whenComplete(() => _opening = null);
    _opening = future;
    return future;
  }

  Future<void> _open() async {
    if (!mounted) return;
    setState(() {
      _booting = true;
      _bootstrapError = null;
    });
    try {
      final model = await widget.createViewModel();
      if (!mounted) {
        await model.close();
        return;
      }
      setState(() {
        _viewModel = model;
        _booting = false;
      });
      await model.load();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _bootstrapError = 'Could not open the local database. Try again.';
        _booting = false;
      });
    }
  }

  @override
  void dispose() {
    final model = _viewModel;
    if (model != null) {
      unawaited(
        model.close().catchError((Object error, StackTrace stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stackTrace),
          );
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ocean Delivery',
      debugShowCheckedModeBanner: false,
      theme: oceanTheme(),
      home: _booting
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _bootstrapError != null
          ? Scaffold(
              appBar: AppBar(title: const Text('Ocean Delivery')),
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_bootstrapError!),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _start,
                        key: const ValueKey('retry-bootstrap'),
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : DeliveryScreen(
              viewModel: _viewModel!,
              demo: widget.demo,
              tileProvider: widget.tileProvider,
              tileUrlTemplate: widget.tileUrlTemplate,
              mapController: widget.mapController,
              routeRepository: widget.routeRepository,
              locationGateway: widget.locationGateway,
              navigationGateway: widget.navigationGateway,
              onNavigationChanged: widget.onNavigationChanged,
            ),
    );
  }
}
