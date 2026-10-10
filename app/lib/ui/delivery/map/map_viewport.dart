import '../../../models/workbench.dart';

/// Accept only a finite viewport for this dataset. Session cards are not saved.
MapViewport? validMapViewport(MapViewport? viewport, String datasetId) {
  if (viewport == null || viewport.datasetId != datasetId) return null;
  if (!viewport.latitude.isFinite ||
      !viewport.longitude.isFinite ||
      !viewport.zoom.isFinite ||
      viewport.latitude < -90 ||
      viewport.latitude > 90 ||
      viewport.longitude < -180 ||
      viewport.longitude > 180 ||
      viewport.zoom < 0 ||
      viewport.zoom > 22) {
    return null;
  }
  return viewport;
}
