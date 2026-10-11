import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/delivery.dart';
import '../../core/brand_theme.dart';
import '../../delivery_view_model.dart';
import '../failure/delivery_failure_sheet.dart';
import '../list/stop_status_badge.dart';

/// A bottom detail card. The owner places it over map/list and routes onClose
/// through the ViewModel's typed origin; this widget never owns that model.
class DeliveryDetailCard extends StatefulWidget {
  const DeliveryDetailCard({
    super.key,
    required this.viewModel,
    required this.onClose,
    this.feedback,
  });

  final DeliveryViewModel viewModel;
  final VoidCallback onClose;
  final Widget? feedback;

  @override
  State<DeliveryDetailCard> createState() => _DeliveryDetailCardState();
}

class _DeliveryDetailCardState extends State<DeliveryDetailCard> {
  bool _completing = false;
  bool _failureOpen = false;
  _AcceptedResult? _accepted;

  bool get _busy => _completing || _failureOpen || widget.viewModel.isSaving;

  Future<void> _complete(Stop stop) async {
    if (_busy ||
        !widget.viewModel.canRecord ||
        stop.status != DeliveryStatus.pending) {
      return;
    }
    setState(() => _completing = true);
    final saved = await widget.viewModel.submit(
      stop.id,
      DeliveryStatus.completed,
    );
    if (!mounted) return;
    setState(() {
      _completing = false;
      if (saved) {
        _accepted = _AcceptedResult(stop.id, DeliveryStatus.completed);
      }
    });
  }

  Future<void> _fail(Stop stop) async {
    if (_busy ||
        !widget.viewModel.canRecord ||
        stop.status != DeliveryStatus.pending) {
      return;
    }
    setState(() => _failureOpen = true);
    final result = await showDeliveryFailureSheet(
      context,
      stop: stop,
      onSubmit: ({required reason, note}) => widget.viewModel.submit(
        stop.id,
        DeliveryStatus.failed,
        reason: reason,
        note: note,
      ),
    );
    if (!mounted) return;
    setState(() {
      _failureOpen = false;
      if (result != null) {
        _accepted = _AcceptedResult(
          stop.id,
          DeliveryStatus.failed,
          reason: result.reason,
          note: result.note,
        );
      }
    });
  }

  void _close() {
    if (!_busy) widget.onClose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, _) {
      final model = widget.viewModel;
      final stop = model.selectedStop;
      if (stop == null) return const SizedBox.shrink();
      final accepted = _accepted?.stopId == stop.id ? _accepted : null;
      // A successful submit means the transaction committed even when the
      // subsequent snapshot read failed. Keep that result read-only and never
      // infer its operation ID or timestamp from the widget clock.
      final localFallback =
          stop.status == DeliveryStatus.pending && accepted != null;
      final unrefreshedResult = model.hasUnrefreshedResult(stop.id);
      final staleSnapshot =
          model.loadError != null || unrefreshedResult || localFallback;
      final savedResult = accepted != null || unrefreshedResult;
      final status = localFallback ? accepted.status : stop.status;
      final reason = localFallback ? accepted.reason : stop.reason;
      final note = localFallback ? accepted.note : stop.note;
      // An unread snapshot cannot prove that an outbox event is still waiting
      // or has been acknowledged. The VM keeps committed facts across remounts.
      final waiting = !staleSnapshot && model.awaitsService(stop);
      final syncLabel = staleSnapshot
          ? savedResult
                ? 'Saved locally · reload required'
                : 'Reload required'
          : waiting
          ? 'Waiting to sync'
          : stop.acknowledgedAt != null
          ? 'Acknowledged'
          : 'No pending update';
      final fromList = model.detailContext?.origin == DetailOrigin.list;
      final returnLabel = fromList ? 'Back to stops' : 'Back to map';
      final address = stop.address.split(',');
      final street = address.first.trim();
      final locality = address.skip(1).join(',').trim();
      return Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                _close();
                return null;
              },
            ),
          },
          child: Material(
            key: const ValueKey('delivery-detail-card'),
            color: OceanColors.cream,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(24)),
              side: BorderSide(color: OceanColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              child: Stack(
                children: [
                  SingleChildScrollView(
                    key: const ValueKey('detail-scroll'),
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 32,
                            height: 4,
                            decoration: BoxDecoration(
                              color: OceanColors.border,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final largeText =
                                MediaQuery.textScalerOf(context).scale(12) > 20;
                            final reference = Text(
                              stop.reference,
                              key: const ValueKey('detail-reference'),
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(color: OceanColors.muted),
                            );
                            final badge = Padding(
                              padding: const EdgeInsets.only(right: 56),
                              child: StopStatusBadge(status: status),
                            );
                            if (largeText || constraints.maxWidth < 200) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  badge,
                                  const SizedBox(height: 6),
                                  reference,
                                ],
                              );
                            }
                            return Padding(
                              padding: const EdgeInsets.only(right: 56),
                              child: Wrap(
                                spacing: 14,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  StopStatusBadge(status: status),
                                  reference,
                                ],
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 10),
                        Text(
                          stop.customerName,
                          key: const ValueKey('detail-customer'),
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          street,
                          key: const ValueKey('detail-street'),
                          style:
                              (MediaQuery.textScalerOf(context).scale(14) > 22
                                      ? Theme.of(context).textTheme.titleLarge
                                            ?.copyWith(fontSize: 18)
                                      : Theme.of(
                                          context,
                                        ).textTheme.headlineLarge)
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: -1.1,
                                    height: 1.15,
                                  ),
                        ),
                        if (locality.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                            locality,
                            key: const ValueKey('detail-locality'),
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(color: OceanColors.muted),
                          ),
                        ],
                        const SizedBox(height: 20),
                        Wrap(
                          spacing: 18,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.access_time,
                                  size: 18,
                                  color: OceanColors.muted,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    stop.timeWindow?.replaceAll('-', '–') ??
                                        'Time window not provided',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              syncLabel,
                              key: const ValueKey('detail-sync-state'),
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: waiting
                                        ? OceanColors.muted
                                        : OceanColors.ink,
                                  ),
                            ),
                          ],
                        ),
                        if (status != DeliveryStatus.pending) ...[
                          const SizedBox(height: 20),
                          _TerminalResult(
                            status: status,
                            reason: reason,
                            note: note,
                            recordedAt: localFallback ? null : stop.recordedAt,
                            acknowledgedAt: localFallback
                                ? null
                                : stop.acknowledgedAt,
                            imported:
                                !unrefreshedResult &&
                                !localFallback &&
                                stop.operationId == null,
                          ),
                        ],
                        if (savedResult) ...[
                          const SizedBox(height: 14),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              staleSnapshot
                                  ? 'Saved locally. Reload required.'
                                  : waiting
                                  ? 'Saved locally. Waiting to sync.'
                                  : 'Saved locally.',
                              key: const ValueKey('detail-saved'),
                              style: const TextStyle(
                                color: OceanColors.green,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                        if (staleSnapshot) ...[
                          const SizedBox(height: 8),
                          Text(
                            savedResult
                                ? 'The result was saved, but details could not be refreshed. Reload to view the stored record.'
                                : 'Details could not be refreshed. Reload before recording a delivery.',
                            key: const ValueKey('detail-reload-warning'),
                          ),
                          TextButton(
                            key: const ValueKey('detail-reload'),
                            onPressed: _busy || model.isLoading
                                ? null
                                : model.load,
                            child: const Text('Reload details'),
                          ),
                        ],
                        if (model.saveError != null && !_failureOpen) ...[
                          const SizedBox(height: 14),
                          Semantics(
                            liveRegion: true,
                            child: const Text(
                              'Could not save. The stop has not changed. Please try again.',
                              style: TextStyle(color: OceanColors.red),
                            ),
                          ),
                        ],
                        if (widget.feedback != null) ...[
                          const SizedBox(height: 12),
                          widget.feedback!,
                        ],
                        const SizedBox(height: 22),
                        if (status == DeliveryStatus.pending) ...[
                          FilledButton.icon(
                            key: const ValueKey('detail-complete'),
                            onPressed: _busy || !model.canRecord
                                ? null
                                : () => _complete(stop),
                            style: _primaryStyle(),
                            icon: const Icon(Icons.check),
                            label: Text(
                              _completing || model.isSaving
                                  ? 'Saving…'
                                  : 'Complete delivery',
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            key: const ValueKey('detail-fail'),
                            onPressed: _busy || !model.canRecord
                                ? null
                                : () => _fail(stop),
                            style: TextButton.styleFrom(
                              foregroundColor: OceanColors.ink,
                              minimumSize: const Size.fromHeight(48),
                              padding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 8,
                              ),
                            ),
                            child: const Text(
                              'Report a failed delivery',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ] else
                          FilledButton.icon(
                            key: const ValueKey('detail-return'),
                            onPressed: _busy ? null : _close,
                            style: _primaryStyle(),
                            icon: Icon(
                              fromList ? Icons.arrow_back : Icons.arrow_forward,
                            ),
                            label: Text(
                              returnLabel,
                              textAlign: TextAlign.center,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 12,
                    child: SizedBox.square(
                      dimension: 48,
                      child: IconButton(
                        key: const ValueKey('detail-close'),
                        tooltip: returnLabel,
                        onPressed: _busy ? null : _close,
                        style: IconButton.styleFrom(
                          backgroundColor: OceanColors.cream,
                        ),
                        icon: Icon(fromList ? Icons.arrow_back : Icons.close),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  ButtonStyle _primaryStyle() => FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(56),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  );
}

class _AcceptedResult {
  const _AcceptedResult(this.stopId, this.status, {this.reason, this.note});

  final String stopId;
  final DeliveryStatus status;
  final String? reason;
  final String? note;
}

class _TerminalResult extends StatelessWidget {
  const _TerminalResult({
    required this.status,
    this.reason,
    this.note,
    this.recordedAt,
    this.acknowledgedAt,
    required this.imported,
  });

  final DeliveryStatus status;
  final String? reason;
  final String? note;
  final DateTime? recordedAt;
  final DateTime? acknowledgedAt;
  final bool imported;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: deliveryStatusColor(status).withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: OceanColors.border),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            deliveryStatusIcon(status),
            color: deliveryStatusColor(status),
            size: 26,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status == DeliveryStatus.completed
                      ? 'Delivery completed'
                      : 'Delivery failed',
                  key: const ValueKey('detail-terminal-result'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                if (status == DeliveryStatus.failed)
                  Text(
                    reason ?? 'No reason provided in the source record.',
                    key: const ValueKey('detail-terminal-reason'),
                  ),
                if (status == DeliveryStatus.failed && note != null) ...[
                  const SizedBox(height: 5),
                  Text(note!),
                ],
                if (recordedAt != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    'Recorded at ${_time(recordedAt!)}',
                    key: const ValueKey('detail-recorded-time'),
                  ),
                ] else if (status == DeliveryStatus.completed && imported)
                  const Text('Imported delivery record'),
                if (acknowledgedAt != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    'Acknowledged at ${_time(acknowledgedAt!)}',
                    key: const ValueKey('detail-acknowledged-time'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );

  static String _time(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
