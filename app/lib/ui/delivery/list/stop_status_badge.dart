import 'package:flutter/material.dart';

import '../../../models/delivery.dart';
import '../../core/brand_theme.dart';

String deliveryStatusLabel(DeliveryStatus status) => switch (status) {
  DeliveryStatus.pending => 'Pending',
  DeliveryStatus.completed => 'Completed',
  DeliveryStatus.failed => 'Failed',
};

Color deliveryStatusColor(DeliveryStatus status) => switch (status) {
  DeliveryStatus.pending => OceanColors.orange,
  DeliveryStatus.completed => OceanColors.green,
  DeliveryStatus.failed => OceanColors.red,
};

IconData deliveryStatusIcon(DeliveryStatus status) => switch (status) {
  DeliveryStatus.pending => Icons.circle_outlined,
  DeliveryStatus.completed => Icons.check_circle_outline,
  DeliveryStatus.failed => Icons.warning_amber_rounded,
};

/// Shared symbol, colour and text for status affordances across the workbench.
class StopStatusBadge extends StatelessWidget {
  const StopStatusBadge({super.key, required this.status});

  final DeliveryStatus status;

  @override
  Widget build(BuildContext context) {
    final color = deliveryStatusColor(status);
    return Semantics(
      label: 'Status: ${deliveryStatusLabel(status)}',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(deliveryStatusIcon(status), size: 16, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                deliveryStatusLabel(status),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: status == DeliveryStatus.pending
                      ? OceanColors.ink
                      : color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
