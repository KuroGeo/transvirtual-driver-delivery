import 'dart:math' as math;

import '../../../models/delivery.dart';

/// The authorised fixed prototype location, not a device location or route ETA.
abstract final class TestReference {
  static const latitude = -33.9004;
  static const longitude = 151.139;
  static const headingDegrees = 35.0;
  static const label = 'Test reference';
}

/// One session query shared by the map, list and nearest-stop affordance.
/// A null status means All; waiting means an unacknowledged outbox update.
class WorkbenchQuery {
  const WorkbenchQuery({
    this.search = '',
    this.status,
    this.waitingOnly = false,
  });

  final String search;
  final DeliveryStatus? status;
  final bool waitingOnly;

  WorkbenchResult evaluate({
    required Iterable<Stop> stops,
    required Iterable<PendingUpdate> queue,
  }) {
    final updates = queue.toList(growable: false);
    final waitingIds = updates.map((update) => update.stopId).toSet();
    final needle = search.trim().toLowerCase();
    final matched = stops.where((stop) {
      if (status != null && stop.status != status) return false;
      if (waitingOnly && !waitingIds.contains(stop.id)) return false;
      return needle.isEmpty ||
          [
            stop.reference,
            stop.customerName,
            stop.address,
          ].any((value) => value.toLowerCase().contains(needle));
    }).toList();
    final distances = {
      for (final stop in matched)
        stop.id: distanceFromTestReferenceMeters(stop),
    };
    matched.sort((a, b) {
      final distance = distances[a.id]!.compareTo(distances[b.id]!);
      return distance != 0 ? distance : a.reference.compareTo(b.reference);
    });
    return WorkbenchResult._(
      stops: matched,
      totalQueueCount: updates.length,
      distanceMetersByStopId: distances,
      waitingStopIds: waitingIds,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WorkbenchQuery &&
      other.search == search &&
      other.status == status &&
      other.waitingOnly == waitingOnly;

  @override
  int get hashCode => Object.hash(search, status, waitingOnly);
}

/// An immutable, already sorted snapshot. Consumers never filter by viewport.
class WorkbenchResult {
  WorkbenchResult._({
    required List<Stop> stops,
    required this.totalQueueCount,
    required Map<String, double> distanceMetersByStopId,
    required Set<String> waitingStopIds,
  }) : stops = List.unmodifiable(stops),
       distanceMetersByStopId = Map.unmodifiable(distanceMetersByStopId),
       waitingStopIds = Set.unmodifiable(waitingStopIds);

  final List<Stop> stops;
  final int totalQueueCount;
  final Map<String, double> distanceMetersByStopId;
  final Set<String> waitingStopIds;

  Stop? get nearest => stops.isEmpty ? null : stops.first;
  int get matchedCount => stops.length;
  double? distanceMeters(Stop stop) => distanceMetersByStopId[stop.id];
  bool awaitsService(Stop stop) => waitingStopIds.contains(stop.id);
}

/// Haversine great-circle distance, using the mean Earth radius in metres.
double distanceFromTestReferenceMeters(Stop stop) {
  const radians = math.pi / 180;
  final deltaLatitude = (stop.latitude - TestReference.latitude) * radians;
  final deltaLongitude = (stop.longitude - TestReference.longitude) * radians;
  final a =
      math.pow(math.sin(deltaLatitude / 2), 2) +
      math.cos(TestReference.latitude * radians) *
          math.cos(stop.latitude * radians) *
          math.pow(math.sin(deltaLongitude / 2), 2);
  // Clamp the rounding error at antipodal/identical coordinates.
  final angle = 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
  return 6371000 * angle;
}

String straightLineDistanceLabel(double metres) => metres < 1000
    ? '${metres.round()} m'
    : '${(metres / 1000).toStringAsFixed(1)} km';
