import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:ocean_delivery/models/workbench.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery/map/map_viewport.dart';

MapViewport viewport({
  String datasetId = 'test',
  double latitude = -33.9,
  double longitude = 151.1,
  double zoom = 11,
}) => MapViewport(
  datasetId: datasetId,
  latitude: latitude,
  longitude: longitude,
  zoom: zoom,
);

void main() {
  test(
    'viewport restore accepts same dataset finite ranges including boundary zoom',
    () {
      for (final zoom in [0.0, 11.2, 22.0]) {
        final saved = viewport(zoom: zoom);
        expect(validMapViewport(saved, 'test'), same(saved));
      }
      expect(
        validMapViewport(viewport(latitude: -90, longitude: -180), 'test'),
        isNotNull,
      );
      expect(
        validMapViewport(viewport(latitude: 90, longitude: 180), 'test'),
        isNotNull,
      );
    },
  );

  test(
    'viewport restore rejects missing, foreign, out of range and nonfinite fields',
    () {
      expect(validMapViewport(null, 'test'), isNull);
      final invalid = [
        viewport(datasetId: 'other'),
        viewport(latitude: -90.001),
        viewport(latitude: 90.001),
        viewport(longitude: -180.001),
        viewport(longitude: 180.001),
        viewport(zoom: -0.01),
        viewport(zoom: 22.01),
        for (final number in [
          double.nan,
          double.infinity,
          double.negativeInfinity,
        ]) ...[
          viewport(latitude: number),
          viewport(longitude: number),
          viewport(zoom: number),
        ],
      ];
      for (final saved in invalid) {
        expect(validMapViewport(saved, 'test'), isNull);
      }
    },
  );

  test(
    'real built-in cache clear removes fm_cache and preserves sibling business file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ocean-e06-cache-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final business = File('${directory.path}/delivery.sqlite');
      await business.writeAsString('business fixture untouched');
      final cache = BuiltInMapCachingProvider.getOrCreateInstance(
        cacheDirectory: directory.path,
        maxCacheSize: null,
      );
      // Waiting for its real read ensures the asynchronous cache directory exists.
      expect(await cache.getTile('http://127.0.0.1/fixture/0/0/0.png'), isNull);
      final cachedFile = File('${directory.path}/fm_cache/controlled-tile');
      await cachedFile.writeAsString('tile fixture');
      expect(await cachedFile.exists(), isTrue);
      await clearBuiltInTileCache();
      expect(await Directory('${directory.path}/fm_cache').exists(), isFalse);
      expect(await business.readAsString(), 'business fixture untouched');
    },
  );
}
