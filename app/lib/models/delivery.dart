enum DeliveryStatus { pending, completed, failed }

class Stop {
  const Stop({
    required this.id,
    required this.reference,
    required this.customerName,
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.status,
    this.reason,
    this.operationId,
    this.timeWindow,
    this.note,
    this.recordedAt,
    this.acknowledgedAt,
  });

  final String id;
  final String reference;
  final String customerName;
  final String address;
  final double latitude;
  final double longitude;
  final DeliveryStatus status;
  final String? reason;
  final String? operationId;
  final String? timeWindow;
  final String? note;
  final DateTime? recordedAt;
  final DateTime? acknowledgedAt;
}

class PendingUpdate {
  const PendingUpdate({
    required this.seq,
    required this.operationId,
    required this.datasetId,
    required this.stopId,
    required this.status,
    this.reason,
    this.note,
    this.recordedAt,
  });

  final int seq;
  final String operationId;
  final String datasetId;
  final String stopId;
  final DeliveryStatus status;
  final String? reason;
  final String? note;
  final DateTime? recordedAt;
}

class Ack {
  const Ack({
    required this.operationId,
    required this.datasetId,
    required this.stopId,
  });

  final String operationId;
  final String datasetId;
  final String stopId;
}
