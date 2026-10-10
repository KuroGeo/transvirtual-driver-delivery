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
    _restoreLater();
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
      color: OceanColors.cream,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Stop list',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.6,
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
                IconButton(
                  key: const ValueKey('close-list'),
                  focusNode: _closeFocus,
                  tooltip: 'Back to map',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close, size: 21),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: CustomScrollView(
              key: const ValueKey('stop-list-scroll'),
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
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
                      message: 'Try another search or clear your filters.',
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
                const SliverToBoxAdapter(child: SizedBox(height: 20)),
              ],
            ),
          ),
        ],
      ),
    );
  }

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
              prefixIcon: const Icon(Icons.search, size: 21),
              suffixIcon: model.query.search.isEmpty
                  ? null
                  : IconButton(
                      key: const ValueKey('clear-search'),
                      tooltip: 'Clear search',
                      onPressed: () => model.setSearch(''),
                      icon: const Icon(Icons.close, size: 18),
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
    final color = deliveryStatusColor(stop.status);
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: OceanColors.border)),
      ),
      child: InkWell(
        focusNode: focusNode,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(
                      stop.status == DeliveryStatus.failed ? 8 : 15,
                    ),
                  ),
                  child: Icon(
                    deliveryStatusIcon(stop.status),
                    size: 18,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stop.reference,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: OceanColors.muted,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      stop.customerName,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      stop.address,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: OceanColors.muted,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 12,
                      runSpacing: 7,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        StopStatusBadge(status: stop.status),
                        Text(
                          straightLineDistanceLabel(distance),
                          semanticsLabel:
                              '${straightLineDistanceLabel(distance)}, straight-line from test reference',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        if (stop.timeWindow?.isNotEmpty ?? false)
                          Text(
                            stop.timeWindow!.replaceAll('-', '–'),
                            semanticsLabel:
                                'Delivery window ${stop.timeWindow}',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(color: OceanColors.muted),
                          ),
                        if (waiting)
                          Text(
                            'Waiting to sync',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(color: OceanColors.muted),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const ExcludeSemantics(
                child: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: OceanColors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
