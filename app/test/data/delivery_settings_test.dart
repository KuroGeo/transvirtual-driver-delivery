import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/delivery/sqlite_delivery_repository.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/models/workbench.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'repository_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<RepositoryFixture> fixture() async {
    final value = await RepositoryFixture.create();
    addTearDown(value.dispose);
    return value;
  }

  MapViewport viewport(String datasetId, {double zoom = 12}) => MapViewport(
    datasetId: datasetId,
    latitude: -33.87,
    longitude: 151.21,
    zoom: zoom,
  );

  test(
    'missing settings initialize current dataset with online and no viewport',
    () async {
      final value = await fixture();
      final settings = await value.repository.loadSettings();
      expect(settings.online, isTrue);
      expect(settings.viewport, isNull);
      expect(settings.datasetId, isNotEmpty);
      expect(
        (await (await value.admin).query('datasets')).single['id'],
        settings.datasetId,
      );
      expect(await value.rowCount('delivery_settings'), 0);
    },
  );

  test(
    'online and dataset viewport survive reopen without overwriting each other',
    () async {
      final value = await fixture();
      final initial = await value.repository.loadSettings();
      await value.repository.saveViewport(viewport(initial.datasetId));
      await value.repository.saveOnline(false);
      await value.repository.saveViewport(
        viewport(initial.datasetId, zoom: 14.5),
      );
      await value.reopen();
      final restored = await value.repository.loadSettings();
      expect(restored.datasetId, initial.datasetId);
      expect(restored.online, isFalse);
      expect(restored.viewport!.datasetId, initial.datasetId);
      expect(restored.viewport!.latitude, -33.87);
      expect(restored.viewport!.longitude, 151.21);
      expect(restored.viewport!.zoom, 14.5);
      await value.repository.saveOnline(true);
      expect((await value.repository.loadSettings()).viewport!.zoom, 14.5);
    },
  );

  test(
    'invalid and different dataset viewports reject before replacing settings',
    () async {
      final value = await fixture();
      final datasetId = (await value.repository.loadSettings()).datasetId;
      await value.repository.saveOnline(false);
      await value.repository.saveViewport(viewport(datasetId));
      for (final invalid in [
        const MapViewport(
          datasetId: 'wrong',
          latitude: 0,
          longitude: 0,
          zoom: 12,
        ),
        MapViewport(
          datasetId: datasetId,
          latitude: double.nan,
          longitude: 0,
          zoom: 12,
        ),
        MapViewport(datasetId: datasetId, latitude: 91, longitude: 0, zoom: 12),
        MapViewport(
          datasetId: datasetId,
          latitude: -91,
          longitude: 0,
          zoom: 12,
        ),
        MapViewport(
          datasetId: datasetId,
          latitude: 0,
          longitude: double.infinity,
          zoom: 12,
        ),
        MapViewport(
          datasetId: datasetId,
          latitude: 0,
          longitude: 181,
          zoom: 12,
        ),
        MapViewport(
          datasetId: datasetId,
          latitude: 0,
          longitude: -181,
          zoom: 12,
        ),
        MapViewport(
          datasetId: datasetId,
          latitude: 0,
          longitude: 0,
          zoom: double.infinity,
        ),
        MapViewport(
          datasetId: datasetId,
          latitude: 0,
          longitude: 0,
          zoom: -0.01,
        ),
        MapViewport(
          datasetId: datasetId,
          latitude: 0,
          longitude: 0,
          zoom: 22.01,
        ),
      ]) {
        await expectLater(
          value.repository.saveViewport(invalid),
          throwsArgumentError,
        );
        final saved = await value.repository.loadSettings();
        expect(saved.online, isFalse);
        expect(saved.viewport!.zoom, 12);
        expect(saved.viewport!.latitude, -33.87);
      }
    },
  );

  test(
    'corrupt, incomplete and another dataset viewport safely fall back',
    () async {
      final value = await fixture();
      final datasetId = (await value.repository.loadSettings()).datasetId;
      await value.repository.saveOnline(false);
      final admin = await value.admin;
      for (final invalid in [
        {'viewport_latitude': 91, 'viewport_longitude': 0, 'viewport_zoom': 12},
        {
          'viewport_latitude': 0,
          'viewport_longitude': -181,
          'viewport_zoom': 12,
        },
        {'viewport_latitude': 0, 'viewport_longitude': 0, 'viewport_zoom': 23},
        {
          'viewport_latitude': 'bad',
          'viewport_longitude': 0,
          'viewport_zoom': 12,
        },
        {
          'viewport_latitude': 0,
          'viewport_longitude': null,
          'viewport_zoom': 12,
        },
      ]) {
        await admin.update(
          'delivery_settings',
          invalid,
          where: 'dataset_id = ?',
          whereArgs: [datasetId],
        );
        final settings = await value.repository.loadSettings();
        expect(settings.viewport, isNull);
        expect(settings.online, isFalse);
      }
      await admin.delete(
        'delivery_settings',
        where: 'dataset_id = ?',
        whereArgs: [datasetId],
      );
      await admin.insert('datasets', {'id': 'other-batch'});
      await admin.insert('delivery_settings', {
        'dataset_id': 'other-batch',
        'online': 0,
        'viewport_latitude': -30,
        'viewport_longitude': 130,
        'viewport_zoom': 11,
      });
      await value.reopen();
      final restored = await value.repository.loadSettings();
      expect(restored.datasetId, datasetId);
      expect(restored.online, isTrue);
      expect(restored.viewport, isNull);
    },
  );

  test(
    'settings insert failure leaves default and does not block delivery save',
    () async {
      final value = await fixture();
      await value.repository.initialize();
      await (await value.admin).execute('''
      CREATE TRIGGER reject_settings BEFORE INSERT ON delivery_settings
      BEGIN SELECT RAISE(ABORT, 'controlled settings insert failure'); END
    ''');
      await expectLater(
        value.repository.saveOnline(false),
        throwsA(isA<DatabaseException>()),
      );
      expect((await value.repository.loadSettings()).online, isTrue);
      expect(await value.rowCount('delivery_settings'), 0);
      final stop = (await value.repository.loadStops()).first;
      await value.repository.submit(
        stop.id,
        DeliveryStatus.failed,
        reason: 'Recipient unavailable',
        note: 'Saved independently',
      );
      expect(
        (await value.repository.pendingUpdates()).single.note,
        'Saved independently',
      );
      await (await value.admin).execute('DROP TRIGGER reject_settings');
      await value.repository.saveOnline(false);
      await value.reopen();
      expect((await value.repository.loadSettings()).online, isFalse);
      expect((await value.repository.pendingUpdates()).single.stopId, stop.id);
    },
  );

  test(
    'settings update rollback preserves online and previous viewport',
    () async {
      final value = await fixture();
      final datasetId = (await value.repository.loadSettings()).datasetId;
      await value.repository.saveOnline(false);
      await value.repository.saveViewport(viewport(datasetId));
      await (await value.admin).execute('''
      CREATE TRIGGER reject_settings BEFORE UPDATE ON delivery_settings
      BEGIN SELECT RAISE(ABORT, 'controlled settings update failure'); END
    ''');
      await expectLater(
        value.repository.saveOnline(true),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(
        value.repository.saveViewport(viewport(datasetId, zoom: 15)),
        throwsA(isA<DatabaseException>()),
      );
      final stop = (await value.repository.loadStops()).first;
      await value.repository.submit(stop.id, DeliveryStatus.completed);
      final update = (await value.repository.pendingUpdates()).single;
      expect(await value.repository.acknowledge(matchingAck(update)), isTrue);
      await value.reopen();
      final settings = await value.repository.loadSettings();
      expect(settings.online, isFalse);
      expect(settings.viewport!.zoom, 12);
      expect(
        (await value.repository.loadStops()).first.acknowledgedAt,
        isNotNull,
      );
      await (await value.admin).execute('DROP TRIGGER reject_settings');
      await value.repository.saveViewport(viewport(datasetId, zoom: 15));
      expect((await value.repository.loadSettings()).viewport!.zoom, 15);
    },
  );

  test(
    'real database path failure retains source and permits initialization retry',
    () async {
      final value = await fixture();
      final parent = File('${value.directory.path}/blocked-parent');
      await parent.writeAsString('A file cannot hold a child database');
      value.repository = SqliteDeliveryRepository(
        databaseFactory: databaseFactoryFfi,
        path: '${parent.path}/delivery.db',
        loadCsv: () async => fixtureCsv,
      );
      await expectLater(
        value.repository.initialize(),
        throwsA(isA<Exception>()),
      );
      await parent.delete();
      await Directory(parent.path).create();
      await value.repository.initialize();
      expect(await value.repository.loadStops(), hasLength(4));
      expect(await value.repository.pendingUpdates(), isEmpty);
    },
  );
}
