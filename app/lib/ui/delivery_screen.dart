import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/delivery.dart';
import 'core/brand_icon.dart';
import 'core/brand_theme.dart';
import 'delivery/detail/delivery_detail_card.dart';
import 'delivery/feedback/workbench_notice.dart';
import 'delivery/list/stop_list_workspace.dart';
import 'delivery/map/delivery_map_workspace.dart';
import 'delivery_view_model.dart';

class _DismissWorkbenchIntent extends Intent {
  const _DismissWorkbenchIntent();
}

class DeliveryScreen extends StatefulWidget {
  const DeliveryScreen({
    super.key,
    required this.viewModel,
    this.demo = false,
    this.tileProvider,
    this.mapController,
    this.tileUrlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  });
  final DeliveryViewModel viewModel;
  final bool demo;
  final TileProvider? tileProvider;
  final DeliveryMapController? mapController;
  final String tileUrlTemplate;

  @override
  State<DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends State<DeliveryScreen> {
  late final DeliveryMapController _map;
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'Map search');
  bool _searchOpen = false;
  bool _listMounted = false;
  bool _summaryOpen = false;
  final _summaryEntryFocus = FocusNode(debugLabel: 'Delivery summary');
  final _summaryCloseFocus = FocusNode(debugLabel: 'Summary close');
  late final Listenable _workbenchChanges;
  DeliveryViewModel get model => widget.viewModel;

  @override
  void initState() {
    super.initState();
    _map = widget.mapController ?? DeliveryMapController();
    model.addListener(_modelChanged);
    _workbenchChanges = Listenable.merge([model, model.notice]);
  }

  void _modelChanged() {
    if (model.panel != WorkbenchPanel.map) _summaryOpen = false;
    if (_search.text != model.query.search) {
      _search.value = TextEditingValue(
        text: model.query.search,
        selection: TextSelection.collapsed(offset: model.query.search.length),
      );
    }
  }

  @override
  void dispose() {
    model.removeListener(_modelChanged);
    _search.dispose();
    _searchFocus.dispose();
    _summaryEntryFocus.dispose();
    _summaryCloseFocus.dispose();
    if (widget.mapController == null) _map.dispose();
    super.dispose();
  }

  void _open(Stop stop, DetailOrigin origin) {
    FocusScope.of(context).unfocus();
    _summaryOpen = false;
    model.openDetail(stop.id, origin: origin);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && model.selectedStop?.id == stop.id) _map.focusStop(stop);
    });
  }

  void _selectStatus(DeliveryStatus? status) {
    if (model.panel == WorkbenchPanel.detail) {
      model.closeDetail();
      if (model.panel == WorkbenchPanel.list) model.closeList();
    }
    model.setStatus(status);
    // Fit only for this explicit action, after markers and overlay padding
    // reflect the new selection. Storage/sync notifications keep the camera.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || model.query.status != status) return;
      if (model.result.stops.isEmpty) {
        _map.locateTestReference();
      } else {
        _map.fitMatches();
      }
    });
  }

  void _back() {
    if (model.isSaving || ModalRoute.of(context)?.isCurrent != true) return;
    if (_summaryOpen) {
      _closeSummary();
    } else if (model.panel == WorkbenchPanel.detail) {
      model.closeDetail();
    } else if (model.panel == WorkbenchPanel.list) {
      model.closeList();
    } else if (_searchOpen) {
      FocusScope.of(context).unfocus();
      setState(() => _searchOpen = false);
    }
  }

  Future<void> _mapInformation() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Map information',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              const Text(
                'Map data © OpenStreetMap contributors. The arrow is a fixed test reference; distances are straight-line distances, not navigation estimates.',
              ),
              const SizedBox(height: 12),
              const Text(
                'Map tiles use the provider’s normal cache policy. Clearing this cache keeps your deliveries and saved updates.',
              ),
              const SizedBox(height: 12),
              TextButton(
                key: const ValueKey('attribution-link'),
                onPressed: () async {
                  final opened = await launchUrl(
                    Uri.parse('https://www.openstreetmap.org/copyright'),
                    mode: LaunchMode.externalApplication,
                  );
                  if (!opened) {
                    model.showNotice(
                      'Could not open map attribution.',
                      kind: NoticeKind.error,
                    );
                  }
                },
                child: const Text('Open OpenStreetMap attribution'),
              ),
              OutlinedButton(
                key: const ValueKey('clear-map-cache'),
                onPressed: () async {
                  Navigator.of(sheetContext).pop();
                  try {
                    await _map.clearTileCache();
                    model.showNotice(
                      'Map cache cleared. Your deliveries are safe.',
                      kind: NoticeKind.information,
                    );
                  } catch (_) {
                    model.showNotice(
                      'Could not clear the map cache. Try again.',
                      kind: NoticeKind.error,
                    );
                  }
                },
                child: const Text('Clear map cache'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _workbenchChanges,
    builder: (context, _) {
      final detail = model.panel == WorkbenchPanel.detail;
      final list = model.panel == WorkbenchPanel.list;
      if (list) _listMounted = true;
      return PopScope(
        canPop: !detail && !list && !_searchOpen && !_summaryOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.escape):
                _DismissWorkbenchIntent(),
          },
          child: Actions(
            actions: {
              _DismissWorkbenchIntent: CallbackAction<_DismissWorkbenchIntent>(
                onInvoke: (_) {
                  _back();
                  return null;
                },
              ),
            },
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              body: SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final largeText =
                        MediaQuery.textScalerOf(context).scale(14) > 22;
                    final task = largeText && (list || detail || _summaryOpen);
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Offstage(
                          offstage: task,
                          child: ExcludeFocus(
                            excluding: task,
                            child: Column(
                              children: [
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    // Large business text also expands the footer and
                                    // Browse. Keep room for both by scrolling the header
                                    // sooner; its complete content keeps the OS scaler.
                                    maxHeight:
                                        constraints.maxHeight *
                                        (MediaQuery.textScalerOf(
                                                  context,
                                                ).scale(14) >
                                                22
                                            ? .32
                                            : .43),
                                  ),
                                  child: SingleChildScrollView(
                                    child: _header(context),
                                  ),
                                ),
                                const Divider(height: 1),
                                Expanded(
                                  child: model.stops.isEmpty
                                      ? _empty(context)
                                      : LayoutBuilder(
                                          builder: (context, _) {
                                            return DeliveryMapWorkspace(
                                              key: const ValueKey('formal-map'),
                                              result: model.result,
                                              datasetId:
                                                  model.settings!.datasetId,
                                              initialViewport:
                                                  model.settings?.viewport,
                                              controller: _map,
                                              tileProvider: widget.tileProvider,
                                              tileUrlTemplate:
                                                  widget.tileUrlTemplate,
                                              selectedStopId:
                                                  model.selectedStop?.id,
                                              onOpenStop: _open,
                                              toolbarTop: 12,
                                              showTools: !list,
                                              showTileError: false,
                                              fitPaddingBuilder: (area) {
                                                if (!detail) {
                                                  if (_compact(context, area)) {
                                                    // Fit beside the single tool column
                                                    // and the compact card/feedback.
                                                    return _compactFitPadding(
                                                      area,
                                                    );
                                                  }
                                                  return const EdgeInsets.fromLTRB(
                                                    35,
                                                    35,
                                                    35,
                                                    260,
                                                  );
                                                }
                                                final compact = _compact(
                                                  context,
                                                  area,
                                                );
                                                final height = _cardHeight(
                                                  area.maxHeight,
                                                  _compact(context, area),
                                                );
                                                if (compact) {
                                                  return _compactFitPadding(
                                                    area,
                                                  );
                                                }
                                                if (_map.tileStatus.value ==
                                                    MapTileStatus.error) {
                                                  return EdgeInsets.fromLTRB(
                                                    80,
                                                    172,
                                                    math.max(
                                                      0,
                                                      area.maxWidth - 91,
                                                    ),
                                                    height + 36,
                                                  );
                                                }
                                                return EdgeInsets.fromLTRB(
                                                  35,
                                                  156,
                                                  35,
                                                  height + 36,
                                                );
                                              },
                                              onViewportChanged: (viewport) =>
                                                  unawaited(
                                                    model.saveViewport(
                                                      viewport,
                                                    ),
                                                  ),
                                              onSync: () =>
                                                  unawaited(model.sync()),
                                              syncing: model.isSyncing,
                                              onAttributionTap: _mapInformation,
                                              overlayBuilder: (context, area) => Stack(
                                                children: [
                                                  if (_listMounted &&
                                                      !largeText)
                                                    Positioned(
                                                      // The prototype drawer joins the
                                                      // bottom edge. Reserve a separate
                                                      // notice lane only while needed.
                                                      bottom: 0,
                                                      left: 0,
                                                      right: 0,
                                                      height: math.min(
                                                        530,
                                                        math.max(
                                                          0,
                                                          area.maxHeight -
                                                              (!_compact(
                                                                        context,
                                                                        area,
                                                                      ) &&
                                                                      (model.notice.value !=
                                                                              null ||
                                                                          model.loadError !=
                                                                              null)
                                                                  ? 112
                                                                  : 12),
                                                        ),
                                                      ),
                                                      child: Offstage(
                                                        offstage: !list,
                                                        child: ExcludeFocus(
                                                          excluding: !list,
                                                          child: Column(
                                                            children: [
                                                              if (_compact(
                                                                context,
                                                                area,
                                                              ))
                                                                ClipRect(
                                                                  key: const ValueKey(
                                                                    'list-feedback-viewport',
                                                                  ),
                                                                  child: list
                                                                      ? _feedback(
                                                                          true,
                                                                          area.maxHeight *
                                                                              .18,
                                                                        )
                                                                      : const SizedBox.shrink(),
                                                                ),
                                                              Expanded(
                                                                child: StopListWorkspace(
                                                                  viewModel:
                                                                      model,
                                                                  onClose: model
                                                                      .closeList,
                                                                  onOpenStop:
                                                                      (
                                                                        stop,
                                                                      ) => _open(
                                                                        stop,
                                                                        DetailOrigin
                                                                            .list,
                                                                      ),
                                                                  onSync: () =>
                                                                      unawaited(
                                                                        model
                                                                            .sync(),
                                                                      ),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  if (!list && !detail)
                                                    Positioned(
                                                      left:
                                                          _compact(
                                                            context,
                                                            area,
                                                          )
                                                          ? 114
                                                          : 12,
                                                      right: 12,
                                                      bottom: 12,
                                                      child: ConstrainedBox(
                                                        constraints: BoxConstraints(
                                                          maxHeight: math.max(
                                                            0,
                                                            area.maxHeight -
                                                                (_compact(
                                                                      context,
                                                                      area,
                                                                    )
                                                                    ? 24
                                                                    : 225),
                                                          ),
                                                        ),
                                                        child: largeText
                                                            ? _largeMapActions()
                                                            : _compact(
                                                                context,
                                                                area,
                                                              )
                                                            ? _overview(
                                                                context,
                                                                compact: true,
                                                              )
                                                            : SingleChildScrollView(
                                                                child:
                                                                    _overview(
                                                                      context,
                                                                    ),
                                                              ),
                                                      ),
                                                    ),
                                                  if (detail && !largeText)
                                                    Positioned(
                                                      left:
                                                          _compact(
                                                            context,
                                                            area,
                                                          )
                                                          ? 114
                                                          : 12,
                                                      right: 12,
                                                      bottom: 12,
                                                      height: _cardHeight(
                                                        area.maxHeight,
                                                        _compact(context, area),
                                                      ),
                                                      child: DeliveryDetailCard(
                                                        key: ValueKey(
                                                          'detail-${model.selectedStop?.id}',
                                                        ),
                                                        viewModel: model,
                                                        onClose:
                                                            model.closeDetail,
                                                      ),
                                                    ),
                                                  if (!task &&
                                                      (detail ||
                                                          !_compact(
                                                            context,
                                                            area,
                                                          )))
                                                    Positioned(
                                                      top: 12,
                                                      left: list ? 20 : 114,
                                                      right: 12,
                                                      child: _feedback(
                                                        list,
                                                        detail
                                                            ? area.maxHeight -
                                                                  _cardHeight(
                                                                    area.maxHeight,
                                                                    _compact(
                                                                      context,
                                                                      area,
                                                                    ),
                                                                  ) -
                                                                  36
                                                            : area.maxHeight -
                                                                  24,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (largeText &&
                            (_listMounted || detail || _summaryOpen))
                          Positioned.fill(
                            child: Offstage(
                              offstage: !task,
                              child: Stack(
                                key: const ValueKey(
                                  'large-text-task-workspace',
                                ),
                                fit: StackFit.expand,
                                children: [
                                  if (_summaryOpen && !list && !detail)
                                    _largeSummary(),
                                  if (_listMounted)
                                    Offstage(
                                      offstage: !list,
                                      child: ExcludeFocus(
                                        excluding: !list,
                                        child: StopListWorkspace(
                                          viewModel: model,
                                          onClose: model.closeList,
                                          onOpenStop: (stop) =>
                                              _open(stop, DetailOrigin.list),
                                          onSync: () => unawaited(model.sync()),
                                          feedback: WorkbenchNoticeView(
                                            viewModel: model,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (detail)
                                    DeliveryDetailCard(
                                      key: ValueKey(
                                        'detail-${model.selectedStop?.id}',
                                      ),
                                      viewModel: model,
                                      onClose: model.closeDetail,
                                      feedback: WorkbenchNoticeView(
                                        viewModel: model,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  EdgeInsets _compactFitPadding(BoxConstraints area) {
    // Keep a complete marker lane even beneath the short landscape header.
    // On taller maps the existing card/tool clearance stays unchanged.
    final bottom = math.min(24.0, math.max(0.0, area.maxHeight - 44));
    final top = math.min(170.0, math.max(0.0, area.maxHeight - bottom - 44));
    return EdgeInsets.fromLTRB(
      80,
      top,
      math.max(0, area.maxWidth - 91),
      bottom,
    );
  }

  bool _compact(BuildContext context, BoxConstraints area) =>
      area.maxHeight < 500 || MediaQuery.textScalerOf(context).scale(14) > 22;

  double _cardHeight(double height, bool compact) {
    // Compact detail occupies the right lane beside the tools/selected marker.
    // Reserve 64px for scrollable feedback above it plus the surrounding gaps,
    // rather than reserving the left toolbar's whole height in this lane too.
    final preferred = compact ? math.max(144.0, height - 100) : height * .55;
    return math.min(preferred, math.max(0.0, height - 24));
  }

  Widget _feedback(bool list, double availableHeight) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: math.max(0, math.min(list ? 88.0 : 196.0, availableHeight)),
    ),
    child: SingleChildScrollView(child: _feedbackContent(list)),
  );

  Widget _feedbackContent(bool list) => ValueListenableBuilder<MapTileStatus>(
    valueListenable: _map.tileStatus,
    builder: (_, tileStatus, _) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (model.loadError != null)
          _reloadNotice()
        else
          WorkbenchNoticeView(viewModel: model),
        if (tileStatus == MapTileStatus.error && !list) ...[
          Material(
            key: const ValueKey('root-map-error'),
            color: OceanColors.cream,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: const Text(
                      'Map unavailable',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('retry-map'),
                    onPressed: _map.retryTiles,
                    child: const Text('Retry map'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    ),
  );

  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 14, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final largeText =
                MediaQuery.textScalerOf(context).scale(12) > 20 ||
                constraints.maxWidth < 300;
            final brand = Semantics(
              header: true,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                // The wordmark is decorative. Keep the complete heading in
                // semantics while business labels retain the OS text scaler.
                child: const Text(
                  'ocean delivery',
                  maxLines: 1,
                  softWrap: false,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                  ),
                ),
              ),
            );
            final subtitle = Text(
              'Sydney · ${model.stops.length} stops',
              style: const TextStyle(color: OceanColors.muted, fontSize: 12),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: largeText
                          ? brand
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                brand,
                                const SizedBox(height: 2),
                                subtitle,
                              ],
                            ),
                    ),
                    SizedBox.square(
                      dimension: 44,
                      child: IconButton(
                        key: const ValueKey('open-search'),
                        tooltip: 'Search stops',
                        onPressed: () {
                          setState(() => _searchOpen = !_searchOpen);
                          if (_searchOpen) _searchFocus.requestFocus();
                        },
                        icon: const BrandIcon('search'),
                      ),
                    ),
                    OutlinedButton(
                      key: const ValueKey('online-toggle'),
                      onPressed:
                          model.isLoading ||
                              model.isChangingOnline ||
                              model.settings == null
                          ? null
                          : () => unawaited(model.setOnline(!model.online)),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(76, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        side: BorderSide(
                          color: model.online
                              ? OceanColors.green.withValues(alpha: .3)
                              : OceanColors.border,
                        ),
                      ),
                      child: Text(
                        model.isChangingOnline
                            ? 'Saving…'
                            : model.online
                            ? 'Online'
                            : 'Offline',
                        style: TextStyle(
                          color: model.online
                              ? OceanColors.green
                              : OceanColors.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (largeText) ...[const SizedBox(height: 2), subtitle],
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          widget.demo
              ? 'Demo · simulated confirmations'
              : 'Local client · service unavailable',
          style: const TextStyle(fontSize: 11, color: OceanColors.muted),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _status('All', null),
            _status('Pending', DeliveryStatus.pending),
            _status('Completed', DeliveryStatus.completed),
            _status('Failed', DeliveryStatus.failed),
          ],
        ),
        if (_searchOpen) ...[
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('map-search'),
            controller: _search,
            focusNode: _searchFocus,
            onChanged: model.setSearch,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Customer, address or reference',
              prefixIcon: const Padding(
                padding: EdgeInsets.all(12),
                child: BrandIcon('search'),
              ),
              suffixIcon: IconButton(
                key: const ValueKey('map-clear-search'),
                tooltip: 'Clear search',
                onPressed: () => model.setSearch(''),
                icon: const Icon(Icons.close, size: 18),
              ),
            ),
          ),
        ],
        if (model.settingsError != null)
          TextButton(
            key: const ValueKey('retry-settings'),
            onPressed: model.isChangingOnline
                ? null
                : () => unawaited(model.retrySettings()),
            child: const Text('Setting not saved · Try again'),
          ),
      ],
    ),
  );

  Widget _status(String label, DeliveryStatus? status) {
    final count = status == null
        ? model.stops.length
        : model.stops.where((stop) => stop.status == status).length;
    final selected = model.query.status == status;
    return OutlinedButton(
      key: ValueKey('header-filter-${label.toLowerCase()}'),
      onPressed: () => _selectStatus(status),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        backgroundColor: selected ? OceanColors.orange : Colors.white,
        foregroundColor: OceanColors.ink,
        side: BorderSide(
          color: selected ? OceanColors.orange : OceanColors.border,
        ),
        textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
      child: Text('$label ${model.loadError == null ? count : '—'}'),
    );
  }

  Widget _empty(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: model.isLoading
          ? const CircularProgressIndicator()
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  model.loadError ?? 'No deliveries in this dataset.',
                  textAlign: TextAlign.center,
                ),
                if (model.loadError != null) ...[
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const ValueKey('reload-data'),
                    onPressed: () => unawaited(model.load()),
                    child: const Text('Reload'),
                  ),
                ],
              ],
            ),
    ),
  );

  Widget _reloadNotice() => Material(
    color: OceanColors.cream,
    borderRadius: BorderRadius.circular(14),
    elevation: 2,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(model.loadError!, style: const TextStyle(fontSize: 12)),
          ),
          TextButton(
            key: const ValueKey('reload-data'),
            onPressed: model.isLoading ? null : () => unawaited(model.load()),
            child: const Text('Reload'),
          ),
        ],
      ),
    ),
  );

  void _openSummary() {
    FocusScope.of(context).unfocus();
    setState(() => _summaryOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _summaryOpen && _summaryCloseFocus.context != null) {
        _summaryCloseFocus.requestFocus();
      }
    });
  }

  void _closeSummary() {
    FocusScope.of(context).unfocus();
    setState(() => _summaryOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !_summaryOpen &&
          model.panel == WorkbenchPanel.map &&
          _summaryEntryFocus.context != null) {
        _summaryEntryFocus.requestFocus();
      }
    });
  }

  String get _remainingLabel => model.loadError == null
      ? '${model.pendingCount} left to deliver'
      : 'Reload for current totals';

  Widget _largeMapActions() => Material(
    key: const ValueKey('delivery-overview'),
    color: OceanColors.cream,
    elevation: 3,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: const BorderSide(color: OceanColors.border),
    ),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  key: const ValueKey('browse-stops'),
                  onPressed: model.openList,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                  label: const Text(
                    'Browse stops',
                    textAlign: TextAlign.center,
                  ),
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  iconAlignment: IconAlignment.end,
                ),
              ),
              ValueListenableBuilder<MapTileStatus>(
                valueListenable: _map.tileStatus,
                builder: (context, status, _) => status != MapTileStatus.error
                    ? const SizedBox.shrink()
                    : SizedBox.square(
                        key: const ValueKey('root-map-error'),
                        dimension: 44,
                        child: IconButton(
                          key: const ValueKey('retry-map'),
                          tooltip: 'Map unavailable. Retry map',
                          onPressed: _map.retryTiles,
                          icon: const Icon(Icons.refresh),
                        ),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: TextButton(
                key: const ValueKey('map-summary-open'),
                focusNode: _summaryEntryFocus,
                onPressed: _openSummary,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  foregroundColor: OceanColors.ink,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _remainingLabel,
                        key: const ValueKey('map-summary-remaining'),
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.expand_more, size: 24),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _largeSummary() {
    final nearest = model.loadError == null ? model.result.nearest : null;
    final finished = model.stops.length - model.pendingCount;
    return Material(
      key: const ValueKey('large-summary-workspace'),
      color: OceanColors.cream,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Today',
                    key: ValueKey('summary-title'),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                SizedBox.square(
                  dimension: 44,
                  child: IconButton(
                    key: const ValueKey('summary-close'),
                    focusNode: _summaryCloseFocus,
                    tooltip: 'Return to map',
                    onPressed: _closeSummary,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('large-summary-scroll'),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _remainingLabel,
                    key: const ValueKey('summary-remaining'),
                    style: const TextStyle(
                      fontSize: 18,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    model.loadError == null
                        ? '$finished of ${model.stops.length} finished'
                        : 'Saved state needs reload',
                    style: const TextStyle(
                      fontSize: 12,
                      color: OceanColors.muted,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('map-waiting-only'),
                    onPressed: () =>
                        model.setWaitingOnly(!model.query.waitingOnly),
                    style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                    child: Text(
                      '${model.query.waitingOnly ? '✓ ' : ''}${model.loadError == null ? model.queueCount : '—'} waiting to sync',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const Divider(height: 24),
                  InkWell(
                    key: const ValueKey('nearest-stop'),
                    onTap: nearest == null
                        ? null
                        : () => _open(nearest, DetailOrigin.nearest),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'NEAREST MATCH',
                            style: TextStyle(
                              fontSize: 10,
                              color: OceanColors.muted,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            nearest?.customerName ??
                                (model.loadError == null
                                    ? 'No matching stops'
                                    : 'Reload to view stops'),
                            key: const ValueKey('summary-nearest-customer'),
                            style: const TextStyle(
                              fontSize: 16,
                              height: 1.25,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (nearest != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              nearest.reference,
                              key: const ValueKey('summary-nearest-reference'),
                              style: const TextStyle(fontSize: 12, height: 1.3),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${straightLineDistanceLabel(model.result.distanceMeters(nearest)!)} straight-line',
                              key: const ValueKey('summary-nearest-distance'),
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.3,
                                color: OceanColors.muted,
                              ),
                            ),
                            const Icon(Icons.arrow_forward, size: 24),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 24),
                  _feedbackContent(false),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const ValueKey('summary-browse-stops'),
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      _summaryOpen = false;
                      model.openList();
                    },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Browse stops'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _overview(BuildContext context, {bool compact = false}) {
    final nearest = model.result.nearest;
    final finished = model.stops.length - model.pendingCount;
    final ratio = model.stops.isEmpty ? 0.0 : finished / model.stops.length;
    final browse = TextButton.icon(
      key: const ValueKey('browse-stops'),
      onPressed: model.openList,
      style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
      label: const Text('Browse stops', textAlign: TextAlign.center),
      icon: const Icon(Icons.arrow_forward, size: 18),
      iconAlignment: IconAlignment.end,
    );
    final completion = Text(
      model.loadError == null
          ? '$finished of ${model.stops.length} finished'
          : 'Saved state needs reload',
      style: const TextStyle(fontSize: 11, color: OceanColors.muted),
    );
    final waiting = TextButton(
      key: const ValueKey('map-waiting-only'),
      onPressed: () => model.setWaitingOnly(!model.query.waitingOnly),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      child: Text(
        '${model.query.waitingOnly ? '✓ ' : ''}${model.loadError == null ? model.queueCount : '—'} waiting to sync',
        style: const TextStyle(fontSize: 11),
        textAlign: TextAlign.center,
      ),
    );
    final summary = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'TODAY’S DELIVERIES',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: OceanColors.muted,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    model.loadError == null
                        ? '${model.pendingCount} left to deliver'
                        : 'Reload for current totals',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -.6,
                    ),
                  ),
                ],
              ),
            ),
            if (!compact) Flexible(child: browse),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: model.loadError == null ? ratio : 0,
            minHeight: 4,
            color: OceanColors.orange,
            backgroundColor: OceanColors.border,
          ),
        ),
        const SizedBox(height: 6),
        if (compact) ...[
          completion,
          waiting,
        ] else
          Row(
            children: [
              Expanded(child: completion),
              Flexible(child: waiting),
            ],
          ),
        const Divider(height: 16),
        InkWell(
          key: const ValueKey('nearest-stop'),
          borderRadius: BorderRadius.circular(10),
          onTap: nearest == null
              ? null
              : () => _open(nearest, DetailOrigin.nearest),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'NEAREST MATCH',
                        style: TextStyle(
                          fontSize: 10,
                          color: OceanColors.muted,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        nearest?.customerName ?? 'No matching stops',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (nearest != null)
                        Text(
                          '${nearest.reference} · ${straightLineDistanceLabel(model.result.distanceMeters(nearest)!)} straight-line',
                          style: const TextStyle(
                            fontSize: 11,
                            color: OceanColors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward, size: 20),
              ],
            ),
          ),
        ),
      ],
    );
    return Material(
      key: const ValueKey('delivery-overview'),
      color: OceanColors.cream,
      elevation: 3,
      shadowColor: OceanColors.ink.withValues(alpha: .08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: OceanColors.border),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: compact
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Keep the primary entry outside the summary's scroll clip.
                  // The right lane leaves map tools and the footer exposed.
                  browse,
                  const SizedBox(height: 8),
                  Flexible(
                    child: SingleChildScrollView(
                      key: const ValueKey('overview-summary'),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [_feedbackContent(false), summary],
                      ),
                    ),
                  ),
                ],
              )
            : summary,
      ),
    );
  }
}

/// Progress feedback owns only its timer and local listener, never focus/camera.
class WorkbenchNoticeView extends StatefulWidget {
  const WorkbenchNoticeView({super.key, required this.viewModel});
  final DeliveryViewModel viewModel;
  @override
  State<WorkbenchNoticeView> createState() => _WorkbenchNoticeViewState();
}

class _WorkbenchNoticeViewState extends State<WorkbenchNoticeView> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    widget.viewModel.notice.addListener(_changed);
    _changed();
  }

  void _changed() {
    _timer?.cancel();
    final notice = widget.viewModel.notice.value;
    if (notice != null && !notice.persistent) {
      _timer = Timer(
        const Duration(seconds: 8),
        () => widget.viewModel.clearNotice(notice.id),
      );
    }
  }

  @override
  void dispose() {
    widget.viewModel.notice.removeListener(_changed);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<WorkbenchNotice?>(
        valueListenable: widget.viewModel.notice,
        builder: (_, notice, _) {
          if (notice == null) return const SizedBox.shrink();
          final busy = notice.kind == NoticeKind.syncing;
          return Semantics(
            liveRegion: true,
            child: Material(
              key: const ValueKey('workbench-notice'),
              color: OceanColors.cream,
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: OceanColors.border),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (busy)
                      const SyncActionIcon(syncing: true, size: 18)
                    else
                      Icon(
                        notice.kind == NoticeKind.error
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        size: 18,
                        color: notice.kind == NoticeKind.error
                            ? OceanColors.red
                            : OceanColors.green,
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        notice.message,
                        key: const ValueKey('notice-message'),
                        style: const TextStyle(fontSize: 12, height: 1.45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
}
