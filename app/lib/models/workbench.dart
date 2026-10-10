enum ClientMode { demo, localClient }

class MapViewport {
  const MapViewport({
    required this.datasetId,
    required this.latitude,
    required this.longitude,
    required this.zoom,
  });

  final String datasetId;
  final double latitude;
  final double longitude;
  final double zoom;
}

class DeliverySettings {
  const DeliverySettings({
    required this.datasetId,
    this.online = true,
    this.viewport,
  });

  final String datasetId;
  final bool online;
  final MapViewport? viewport;
}
