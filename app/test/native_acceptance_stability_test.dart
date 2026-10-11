import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/native_acceptance_support.dart';

void main() {
  Map<String, dynamic> observation({double cameraLatitude = -33.9}) => {
    'outbox': [
      {'seq': 7, 'operationId': 'actual-operation'},
    ],
    'persistedStops': [
      {'status': 'completed'},
    ],
    'persistedSettings': <String, dynamic>{
      'online': false,
      'viewport': {'latitude': -33.9, 'longitude': 151.1, 'zoom': 15.0},
    },
    'camera': {
      'latitude': cameraLatitude,
      'longitude': 151.1,
      'zoom': 15.0,
      'rotation': 0.0,
    },
  };

  test('capture rejects a camera move before its viewport commit', () {
    expect(
      acceptanceCaptureReady(observation(cameraLatitude: -33.91)),
      isFalse,
    );
    expect(acceptanceCaptureReady(observation()), isTrue);
  });
  test('capture rejects nonfinite persisted coordinates', () {
    final value = observation();
    (value['persistedSettings']['viewport'] as Map)['latitude'] = double.nan;
    expect(acceptanceCaptureReady(value), isFalse);
  });
  test('invalid cold viewport remains null without forcing a write', () {
    final value = observation();
    value['persistedSettings']['viewport'] = null;
    expect(acceptanceCaptureReady(value), isTrue);
    expect(value['persistedSettings']['viewport'], isNull);
  });
  test(
    'failed bootstrap observation remains available before migration retry',
    () {
      expect(
        acceptanceCaptureReady({'persistedSettings': null, 'camera': null}),
        isTrue,
      );
    },
  );
  test(
    'stability detects later durable changes while retaining error samples',
    () {
      final before = observation();
      final after = observation();
      after['model'] = {'settingsError': 'intentional Online rollback'};
      after['observedAt'] = 'a later observation';
      expect(
        acceptanceEqual(
          acceptanceCaptureState(before),
          acceptanceCaptureState(after),
        ),
        isTrue,
      );
      after['outbox'] = [];
      expect(
        acceptanceEqual(
          acceptanceCaptureState(before),
          acceptanceCaptureState(after),
        ),
        isFalse,
      );
      expect(after['model']['settingsError'], isNotNull);
    },
  );
}
