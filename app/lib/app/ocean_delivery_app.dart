import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/delivery_screen.dart';
import '../ui/delivery_view_model.dart';
import '../ui/core/brand_theme.dart';

class OceanDeliveryApp extends StatefulWidget {
  const OceanDeliveryApp({
    super.key,
    required this.createViewModel,
    this.demo = false,
  });

  final Future<DeliveryViewModel> Function() createViewModel;
  final bool demo;

  @override
  State<OceanDeliveryApp> createState() => _OceanDeliveryAppState();
}

class _OceanDeliveryAppState extends State<OceanDeliveryApp> {
  DeliveryViewModel? _viewModel;
  bool _booting = true;
  String? _bootstrapError;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
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
        _bootstrapError = '本地数据库无法打开，请重试。';
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
                        child: const Text('重试打开'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : DeliveryScreen(viewModel: _viewModel!, demo: widget.demo),
    );
  }
}
