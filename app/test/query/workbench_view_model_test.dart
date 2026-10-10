import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';

import 'query_repository_fixture.dart';

void main() {
  test(
    'cold session opens map and caches result across panel/context changes',
    () async {
      final repository = QueryRepositoryFixture();
      final model = repository.createModel();
      await model.load();
      expect(model.panel, WorkbenchPanel.map);
      expect(model.query, const WorkbenchQuery());
      expect(model.listSession.scrollOffset, 0);
      expect(model.listSession.focusedReference, isNull);
      final result = model.result;
      model.openList();
      model.rememberListSession(scrollOffset: 140, focusedReference: 'REF-01');
      model.openDetail('id-REF-01', origin: DetailOrigin.list);
      model.closeDetail();
      expect(model.result, same(result));
      expect(model.panel, WorkbenchPanel.list);
      model.closeList();
      expect(model.panel, WorkbenchPanel.map);
      expect(model.result, same(result));
      await model.close();
    },
  );

  test('setters combine conditions and equal query is a no-op', () async {
    final repository = QueryRepositoryFixture(
      stops: [
        queryStop('A'),
        queryStop('B', status: DeliveryStatus.completed),
      ],
      queue: [queryUpdate('B')],
    );
    final model = repository.createModel();
    await model.load();
    model.setSearch('B');
    model.setStatus(DeliveryStatus.completed);
    model.setWaitingOnly(true);
    expect(model.result.stops.single.reference, 'B');
    expect(model.result.matchedCount, 1);
    expect(model.queueCount, 1);
    expect(
      model.pendingCount,
      1,
      reason: 'global pending count is not filtered',
    );
    final result = model.result;
    var notifications = 0;
    model.addListener(() => notifications++);
    model.setSearch('B');
    model.setStatus(DeliveryStatus.completed);
    model.setWaitingOnly(true);
    expect(model.result, same(result));
    expect(notifications, 0);
    model.resetQuery();
    expect(model.result.matchedCount, 2);
    await model.close();
  });

  test(
    'list detail survives terminal save while Pending filter removes its row',
    () async {
      final repository = QueryRepositoryFixture();
      final model = repository.createModel();
      await model.load();
      model.setSearch('REF-01');
      model.setStatus(DeliveryStatus.pending);
      model.openList();
      model.rememberListSession(scrollOffset: 350, focusedReference: 'REF-01');
      model.openDetail('id-REF-01', origin: DetailOrigin.list);
      expect(
        await model.submit(
          'id-REF-01',
          DeliveryStatus.failed,
          reason: 'Business closed',
          note: 'Shutter down',
        ),
        isTrue,
      );
      expect(model.result.nearest, isNull);
      expect(model.result.matchedCount, 0);
      expect(model.result.totalQueueCount, 1);
      expect(model.selectedStop?.status, DeliveryStatus.failed);
      expect(model.selectedStop?.note, 'Shutter down');
      expect(model.panel, WorkbenchPanel.detail);
      model.closeDetail();
      expect(model.panel, WorkbenchPanel.list);
      expect(model.query.search, 'REF-01');
      expect(model.query.status, DeliveryStatus.pending);
      expect(model.listSession.scrollOffset, 350);
      expect(model.listSession.focusedReference, 'REF-01');
      await model.close();
    },
  );

  test(
    'explicit map and nearest origins return to map even from an open list',
    () async {
      final repository = QueryRepositoryFixture();
      final model = repository.createModel();
      await model.load();
      for (final origin in [DetailOrigin.map, DetailOrigin.nearest]) {
        model.openList();
        model.openDetail('id-REF-01', origin: origin);
        expect(model.detailContext?.origin, origin);
        expect(model.detailContext?.listSession, isNull);
        model.closeDetail();
        expect(model.panel, WorkbenchPanel.map);
      }
      model.openDetail('missing', origin: DetailOrigin.list);
      expect(model.panel, WorkbenchPanel.map);
      expect(model.selectedStop, isNull);
      await model.close();
    },
  );

  test('failed submit retains selection, matching data and session', () async {
    final repository = QueryRepositoryFixture()..failSubmit = true;
    final model = repository.createModel();
    await model.load();
    model.setStatus(DeliveryStatus.pending);
    model.openList();
    model.rememberListSession(scrollOffset: 90, focusedReference: 'REF-01');
    model.openDetail('id-REF-01', origin: DetailOrigin.list);
    final result = model.result;
    expect(await model.submit('id-REF-01', DeliveryStatus.completed), isFalse);
    expect(model.result, same(result));
    expect(model.selectedStop?.status, DeliveryStatus.pending);
    expect(model.panel, WorkbenchPanel.detail);
    expect(model.saveError, isNotNull);
    model.closeDetail();
    expect(model.listSession.scrollOffset, 90);
    expect(model.saveError, isNull);
    await model.close();
  });

  test(
    'new model cold starts with default query after a previous session',
    () async {
      final model = QueryRepositoryFixture().createModel();
      await model.load();
      model.setSearch('foo');
      model.setWaitingOnly(true);
      model.setStatus(DeliveryStatus.failed);
      model.openList();
      await model.close();
      final fresh = QueryRepositoryFixture().createModel();
      await fresh.load();
      expect(fresh.panel, WorkbenchPanel.map);
      expect(fresh.query, const WorkbenchQuery());
      expect(fresh.listSession.focusedReference, isNull);
      expect(fresh.listSession.scrollOffset, 0);
      await fresh.close();
    },
  );
}
