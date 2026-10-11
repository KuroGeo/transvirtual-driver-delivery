import 'package:flutter/material.dart';

import '../../../models/delivery.dart';
import '../../core/brand_icon.dart';
import '../../core/brand_theme.dart';
import '../../delivery_view_model.dart';
import 'stop_status_badge.dart';

/// A reusable list panel with no Navigator or app-level controller ownership.
/// [onOpenStop] should call `openDetail(stop.id, origin: DetailOrigin.list)`;
/// [onClose] should call `closeList()`. Search and list session are owned by VM.
class StopListWorkspace extends StatefulWidget {
  const StopListWorkspace({
    super.key,
    required this.viewModel,
    required this.onOpenStop,
    required this.onClose,
    this.onSync,
  });

  final DeliveryViewModel viewModel;
  final ValueChanged<Stop> onOpenStop;
  final VoidCallback onClose;

  /// Joins the host's direct sync action, including while a run is active.
  final VoidCallback? onSync;

  @override
  State<StopListWorkspace> createState() => _StopListWorkspaceState();
}

class _StopListWorkspaceState extends State<StopListWorkspace> {
  late final ScrollController _scroll;
  late final TextEditingController _search;
  bool _queryExpanded = false;
  final _closeFocus = FocusNode(debugLabel: 'Close stop list');
  final _rowFocus = <String, FocusNode>{};
  late WorkbenchPanel _lastPanel;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController(
      initialScrollOffset: widget.viewModel.listSession.scrollOffset,
      keepScrollOffset: false,
    )..addListener(_rememberScroll);
    _search = TextEditingController(text: widget.viewModel.query.search);
    _lastPanel = widget.viewModel.panel;
    widget.viewModel.addListener(_modelChanged);
    // A cold session has no reference and must not grab input focus.
    if (widget.viewModel.listSession.focusedReference != null) _restoreLater();
  }

  @override
  void didUpdateWidget(covariant StopListWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewModel == widget.viewModel) return;
    oldWidget.viewModel.removeListener(_modelChanged);
    widget.viewModel.addListener(_modelChanged);
    _lastPanel = widget.viewModel.panel;
    _search.text = widget.viewModel.query.search;
    _queryExpanded = false;
    _restoreLater();
  }

  void _toggleQueryTools() {
    setState(() {
      _queryExpanded = !_queryExpanded;
    });
  }

  void _modelChanged() {
    if (!mounted) return;
    final model = widget.viewModel;
    if (_search.text != model.query.search) {
      _search.value = TextEditingValue(
        text: model.query.search,
        selection: TextSelection.collapsed(offset: model.query.search.length),
      );
    }
    final returningToList =
        _lastPanel != WorkbenchPanel.list && model.panel == WorkbenchPanel.list;
    _lastPanel = model.panel;
    setState(() {});
    if (returningToList) _restoreLater();
  }

  void _restoreLater() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final session = widget.viewModel.listSession;
      _scroll.jumpTo(
        session.scrollOffset.clamp(0.0, _scroll.position.maxScrollExtent),
      );
      // Wait for the lazy list to lay out at the restored offset before
      // requesting its row's real FocusNode. Cold sessions never grab focus.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || session.focusedReference == null) return;
        final stillMatches = widget.viewModel.result.stops.any(
          (stop) => stop.reference == session.focusedReference,
        );
        if (!stillMatches) {
          _closeFocus.requestFocus();
        } else {
          final row = _rowFocus[session.focusedReference];
          if (row?.context != null) row!.requestFocus();
        }
      });
    });
  }

  void _rememberScroll() {
    widget.viewModel.rememberListSession(scrollOffset: _scroll.offset);
  }

  FocusNode _focusFor(Stop stop) => _rowFocus.putIfAbsent(stop.reference, () {
    final node = FocusNode(debugLabel: 'Stop ${stop.reference}');
    node.addListener(() {
      if (node.hasFocus && _scroll.hasClients) {
        widget.viewModel.rememberListSession(
          scrollOffset: _scroll.offset,
          focusedReference: stop.reference,
        );
      }
    });
    return node;
  });

  void _open(Stop stop) {
    widget.viewModel.rememberListSession(
      scrollOffset: _scroll.offset,
      focusedReference: stop.reference,
    );
    widget.onOpenStop(stop);
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_modelChanged);
    if (_scroll.hasClients) _rememberScroll();
    _scroll.dispose();
    _search.dispose();
    _closeFocus.dispose();
    for (final node in _rowFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.viewModel;
    final result = model.result;
    return Material(
      key: const ValueKey('list-workspace'),
      color: _StopListStyle.paper,
      elevation: 8,
      shadowColor: const Color(0x26563817),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(23)),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxHeight < 400 ||
              MediaQuery.textScalerOf(context).scale(14) > 22;
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 10, bottom: 8),
                child: SizedBox(
                  key: ValueKey('list-grip'),
                  width: 32,
                  height: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xFFD9C3A3),
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: compact
                    ? const EdgeInsets.fromLTRB(20, 0, 12, 6)
                    : const EdgeInsets.fromLTRB(20, 9, 12, 18),
                child: Row(
                  children: [
                    if (compact) const Spacer() else Expanded(child: _title()),
                    SizedBox.square(
                      dimension: 44,
                      child: IconButton(
                        key: const ValueKey('list-query-controls'),
                        tooltip: 'Search and filters',
                        isSelected: _queryExpanded,
                        onPressed: _toggleQueryTools,
                        icon: const BrandIcon(
                          'search',
                          color: _StopListStyle.ink,
                        ),
                      ),
                    ),
                    if (widget.onSync != null)
                      SizedBox.square(
                        dimension: 44,
                        child: IconButton(
                          key: const ValueKey('list-sync'),
                          tooltip: model.isSyncing
                              ? 'Syncing saved updates'
                              : 'Sync saved updates',
                          onPressed: widget.onSync,
                          icon: SyncActionIcon(syncing: model.isSyncing),
                        ),
                      ),
                    SizedBox.square(
                      dimension: 44,
                      child: IconButton(
                        key: const ValueKey('close-list'),
                        focusNode: _closeFocus,
                        tooltip: 'Close stop list',
                        onPressed: widget.onClose,
                        icon: const BrandIcon(
                          'close',
                          color: _StopListStyle.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CustomScrollView(
                  key: const ValueKey('stop-list-scroll'),
                  controller: _scroll,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    // Keep the complete OS-scaled heading with the searchable
                    // content. Only the return/sync actions need a fixed budget.
                    if (compact)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                          child: _title(),
                        ),
                      ),
                    if (_queryExpanded)
                      SliverToBoxAdapter(child: _queryControls(context, model)),
                    if (model.isLoading && model.stops.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (model.loadError != null)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _empty(
                          context,
                          title: 'Stops could not be loaded',
                          message: 'Your saved deliveries stay on this device.',
                          action: 'Retry',
                          onPressed: model.load,
                        ),
                      )
                    else if (result.stops.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _empty(
                          context,
                          title: 'No matching stops',
                          message: 'Try another status or search term.',
                          action: 'Clear search and filters',
                          onPressed: model.resetQuery,
                        ),
                      )
                    else
                      SliverList.builder(
                        itemCount: result.stops.length,
                        itemBuilder: (context, index) {
                          final stop = result.stops[index];
                          return _StopRow(
                            key: ValueKey('stop-${stop.reference}'),
                            stop: stop,
                            distance: result.distanceMeters(stop)!,
                            waiting: result.awaitsService(stop),
                            focusNode: _focusFor(stop),
                            onPressed: () => _open(stop),
                          );
                        },
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _title() => Semantics(
    header: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Stops on the map',
          key: ValueKey('list-title'),
          style: TextStyle(
            fontSize: 22,
            height: 1.3,
            fontWeight: FontWeight.w500,
            letterSpacing: -0.7,
            color: _StopListStyle.ink,
          ),
        ),
        const SizedBox(height: 5),
        Semantics(
          liveRegion: true,
          child: Text(
            '${widget.viewModel.result.matchedCount} '
            '${widget.viewModel.result.matchedCount == 1 ? 'stop' : 'stops'} '
            '· Nearest first',
            key: const ValueKey('list-matching-count'),
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              color: Color(0xFF7C6349),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _queryControls(BuildContext context, DeliveryViewModel model) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('stop-search'),
            controller: _search,
            onChanged: model.setSearch,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: 'Search stops',
              hintText: 'Reference, customer or address',
              fillColor: _StopListStyle.row,
              prefixIcon: const BrandIcon('search'),
              suffixIcon: model.query.search.isEmpty
                  ? null
                  : IconButton(
                      key: const ValueKey('clear-search'),
                      tooltip: 'Clear search',
                      onPressed: () => model.setSearch(''),
                      icon: const BrandIcon('close', size: 18),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final status in [null, ...DeliveryStatus.values])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: ValueKey('filter-${status?.name ?? 'all'}'),
                      selected: model.query.status == status,
                      showCheckmark: false,
                      avatar: status == null
                          ? null
                          : Icon(deliveryStatusIcon(status), size: 16),
                      label: Text(
                        status == null ? 'All' : deliveryStatusLabel(status),
                      ),
                      onSelected: (_) => model.setStatus(status),
                      selectedColor: OceanColors.orange.withValues(alpha: 0.13),
                      side: BorderSide(
                        color: model.query.status == status
                            ? OceanColors.orange
                            : OceanColors.border,
                      ),
                      labelStyle: const TextStyle(color: OceanColors.ink),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              key: const ValueKey('waiting-only'),
              selected: model.query.waitingOnly,
              avatar: const Icon(Icons.cloud_upload_outlined, size: 16),
              label: const Text('Waiting only'),
              onSelected: model.setWaitingOnly,
              selectedColor: OceanColors.orange.withValues(alpha: 0.13),
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              '${model.result.matchedCount} matching stops · '
              '${model.result.totalQueueCount} waiting in total',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: OceanColors.muted),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Nearest first · straight-line from ${TestReference.label.toLowerCase()}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: OceanColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _empty(
    BuildContext context, {
    required String title,
    required String message,
    required String action,
    required VoidCallback onPressed,
  }) => Padding(
    padding: const EdgeInsets.all(28),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.search_off_rounded,
          size: 34,
          color: OceanColors.muted,
        ),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: OceanColors.muted),
        ),
        const SizedBox(height: 14),
        TextButton(onPressed: onPressed, child: Text(action)),
      ],
    ),
  );
}

// Resolved map.css values for the Browse stops drawer. Presentation stays local
// so the shared map/detail status helpers keep their existing contract.
abstract final class _StopListStyle {
  static const paper = Color(0xFFFFF9EE);
  static const row = Color(0xFFFFFAF3);
  static const ink = Color(0xFF30271F);
  static const divider = Color(0xFFEBDDC8);
  static const metadata = Color(0xFF805B3B);

  static Color outcome(DeliveryStatus status) => switch (status) {
    DeliveryStatus.pending => const Color(0xFF746656),
    DeliveryStatus.completed => const Color(0xFF245D43),
    DeliveryStatus.failed => const Color(0xFF8F2F2B),
  };
}

class _StopRow extends StatelessWidget {
  const _StopRow({
    super.key,
    required this.stop,
    required this.distance,
    required this.waiting,
    required this.focusNode,
    required this.onPressed,
  });

  final Stop stop;
  final double distance;
  final bool waiting;
  final FocusNode focusNode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final symbolColor = switch (stop.status) {
      DeliveryStatus.pending => const Color(0xFF924A23),
      DeliveryStatus.completed => const Color(0xFF245D43),
      DeliveryStatus.failed => const Color(0xFF8F2F2B),
    };
    final symbolBackground = switch (stop.status) {
      DeliveryStatus.pending => const Color(0xFFFFE3C8),
      DeliveryStatus.completed => const Color(0xFFE5EDDE),
      DeliveryStatus.failed => const Color(0xFFF5E4DC),
    };
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: _StopListStyle.row,
        border: Border(top: BorderSide(color: _StopListStyle.divider)),
      ),
      child: InkWell(
        focusNode: focusNode,
        onTap: onPressed,
        hoverColor: const Color(0xFFFFF1DF),
        child: Semantics(
          label: stop.reference,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 112),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Container(
                        key: ValueKey('list-status-symbol-${stop.reference}'),
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: symbolBackground,
                          borderRadius: BorderRadius.circular(
                            stop.status == DeliveryStatus.failed ? 8 : 15,
                          ),
                        ),
                        child: stop.status == DeliveryStatus.pending
                            ? Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: symbolColor,
                                    width: 2,
                                  ),
                                ),
                              )
                            : BrandIcon(
                                stop.status == DeliveryStatus.completed
                                    ? 'check'
                                    : 'warning',
                                size: 17,
                                color: symbolColor,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          stop.customerName,
                          style: const TextStyle(
                            fontSize: 16,
                            height: 1.5,
                            fontWeight: FontWeight.w500,
                            fontVariations: [FontVariation('wght', 550)],
                            letterSpacing: -0.3,
                            color: _StopListStyle.ink,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          stop.address,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: Color(0xFF7D6145),
                          ),
                        ),
                        const SizedBox(height: 9),
                        DefaultTextStyle.merge(
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: _StopListStyle.metadata,
                          ),
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 5,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                straightLineDistanceLabel(distance),
                                semanticsLabel:
                                    '${straightLineDistanceLabel(distance)}, straight-line from test reference',
                                style: const TextStyle(
                                  color: Color(0xFF6B4C31),
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                              if (stop.timeWindow?.isNotEmpty ?? false)
                                Text(
                                  stop.timeWindow!.replaceAll('-', '–'),
                                  semanticsLabel:
                                      'Delivery window ${stop.timeWindow}',
                                ),
                              StopStatusBadge(
                                status: stop.status,
                                showSymbol: false,
                                textStyle: TextStyle(
                                  fontSize: 13,
                                  height: 1.5,
                                  fontWeight: FontWeight.w400,
                                  fontVariations: const [
                                    FontVariation('wght', 450),
                                  ],
                                  color: _StopListStyle.outcome(stop.status),
                                ),
                              ),
                              if (waiting)
                                const Text(
                                  'Waiting to sync',
                                  style: TextStyle(color: Color(0xFF964B28)),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  const ExcludeSemantics(
                    child: Padding(
                      padding: EdgeInsets.only(top: 7),
                      child: BrandIcon(
                        'arrow',
                        size: 14,
                        color: Color(0xFF96744F),
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
