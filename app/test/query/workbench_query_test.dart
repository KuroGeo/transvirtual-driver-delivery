import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery/query/workbench_query.dart';

import 'query_repository_fixture.dart';

void main() {
  final stops = [
    queryStop('TV-100', customer: 'Harbour Foods', address: '25 Pitt St'),
    queryStop(
      'TV-200',
      status: DeliveryStatus.completed,
      customer: 'Harbour Shop',
      address: '20 King St',
    ),
    queryStop(
      'TV-300',
      status: DeliveryStatus.failed,
      customer: 'Ocean Hardware',
      address: '10 King St',
    ),
  ];
  final queue = [queryUpdate('TV-200'), queryUpdate('TV-300', seq: 2)];

  test('cold query is All, empty search and Waiting off', () {
    const query = WorkbenchQuery();
    expect(query.search, '');
    expect(query.status, isNull);
    expect(query.waitingOnly, isFalse);
    expect(query.evaluate(stops: stops, queue: queue).matchedCount, 3);
  });

  test('search is case insensitive across reference, customer and address', () {
    for (final search in [' tv-100 ', 'hArBoUr FoOdS', 'PITT st']) {
      final result = WorkbenchQuery(
        search: search,
      ).evaluate(stops: stops, queue: queue);
      expect(result.stops.map((stop) => stop.reference), ['TV-100']);
    }
  });

  test(
    'search, status and Waiting intersect without changing global queue',
    () {
      final result = const WorkbenchQuery(
        search: 'harbour',
        status: DeliveryStatus.completed,
        waitingOnly: true,
      ).evaluate(stops: stops, queue: queue);
      expect(result.stops.map((stop) => stop.reference), ['TV-200']);
      expect(result.matchedCount, 1);
      expect(result.totalQueueCount, 2);
      expect(result.nearest, same(stops[1]));
      expect(result.awaitsService(stops[1]), isTrue);

      final empty = const WorkbenchQuery(
        search: 'harbour',
        status: DeliveryStatus.pending,
        waitingOnly: true,
      ).evaluate(stops: stops, queue: queue);
      expect(empty.matchedCount, 0);
      expect(empty.nearest, isNull);
      expect(empty.totalQueueCount, 2);
    },
  );

  test('Waiting is outbox membership, including terminal status', () {
    final result = const WorkbenchQuery(
      waitingOnly: true,
    ).evaluate(stops: stops, queue: queue);
    expect(result.stops.map((stop) => stop.status), [
      DeliveryStatus.completed,
      DeliveryStatus.failed,
    ]);
    final acknowledged = const WorkbenchQuery(
      waitingOnly: true,
    ).evaluate(stops: stops, queue: [queue[1]]);
    expect(acknowledged.stops.map((stop) => stop.reference), ['TV-300']);
  });

  test(
    'known Haversine distances use fixed reference without mutating stops',
    () {
      final colocated = queryStop('AT');
      final oneDegreeNorth = queryStop(
        'NORTH',
        latitude: TestReference.latitude + 1,
      );
      final antipode = queryStop(
        'OPPOSITE',
        latitude: -TestReference.latitude,
        longitude: TestReference.longitude - 180,
      );
      expect(distanceFromTestReferenceMeters(colocated), 0);
      expect(
        distanceFromTestReferenceMeters(oneDegreeNorth),
        closeTo(111194.9266, 0.01),
      );
      expect(
        distanceFromTestReferenceMeters(antipode),
        closeTo(20015086.796, 1),
      );
      expect(TestReference.latitude, -33.9004);
      expect(TestReference.longitude, 151.139);
      expect(TestReference.headingDegrees, 35);
      expect(TestReference.label, 'Test reference');
      expect(oneDegreeNorth.latitude, TestReference.latitude + 1);
    },
  );

  test(
    'all matches sort by distance then reference, independent of input order',
    () {
      final a = queryStop('A');
      final b = queryStop('B');
      final far = queryStop('FAR', latitude: -34.1);
      for (final input in [
        [far, b, a],
        [a, far, b],
      ]) {
        final result = const WorkbenchQuery().evaluate(
          stops: input,
          queue: const [],
        );
        expect(result.stops, [a, b, far]);
        expect(result.nearest, same(a));
        expect(
          result.distanceMetersByStopId.keys,
          containsAll([a.id, b.id, far.id]),
        );
        expect(result.distanceMeters(far), greaterThan(20000));
        expect(() => result.stops.add(far), throwsUnsupportedError);
        expect(
          () => result.distanceMetersByStopId[a.id] = 1,
          throwsUnsupportedError,
        );
        expect(() => result.waitingStopIds.add(a.id), throwsUnsupportedError);
      }
    },
  );

  test(
    'nearest follows every matching status and distant matches remain included',
    () {
      final far = queryStop(
        'DISTANT',
        status: DeliveryStatus.failed,
        latitude: -36,
      );
      final near = queryStop('NEAR', status: DeliveryStatus.completed);
      final result = const WorkbenchQuery(
        status: DeliveryStatus.failed,
      ).evaluate(stops: [near, far], queue: const []);
      expect(result.stops, [far]);
      expect(result.nearest, same(far));
      expect(result.distanceMeters(far), greaterThan(200000));
    },
  );
}
