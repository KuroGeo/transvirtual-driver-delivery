import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery/failure/delivery_failure_sheet.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';

import 'detail_test_fixture.dart';

void main() {
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  testWidgets(
    'card shows full stop identity, street, locality and real window',
    (tester) async {
      final repository = DetailRepositoryFixture();
      final model = await loadedDetail(repository);
      model.setSearch('does not match');
      expect(model.result.stops, isEmpty);
      await tester.pumpWidget(detailHost(model));
      expect(find.text('Silverline Supplies'), findsOneWidget);
      expect(find.text('TV-300002'), findsOneWidget);
      expect(find.text('215 Pitt St'), findsOneWidget);
      expect(find.text('Newtown NSW'), findsOneWidget);
      expect(find.text('08:00–10:00'), findsOneWidget);
      expect(find.text('No pending update'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-recorded-time')), findsNothing);
      expect(find.byKey(const ValueKey('detail-complete')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmountDetail(tester, model);
    },
  );

  for (final origin in DetailOrigin.values) {
    testWidgets(
      '${origin.name} close and terminal return preserve typed source',
      (tester) async {
        final repository = DetailRepositoryFixture(
          stop: detailStop(status: DeliveryStatus.completed),
        );
        final model = repository.createModel();
        await model.load();
        model.openList();
        model.setSearch('Silverline');
        model.setStatus(DeliveryStatus.completed);
        model.rememberListSession(
          scrollOffset: 137,
          focusedReference: repository.stop.reference,
        );
        model.openDetail(repository.stop.id, origin: origin);
        await tester.pumpWidget(detailHost(model));
        final fromList = origin == DetailOrigin.list;
        final close = tester.widget<IconButton>(
          find.byKey(const ValueKey('detail-close')),
        );
        expect(
          (close.icon as Icon).icon,
          fromList ? Icons.arrow_back : Icons.close,
        );
        expect(
          find.text(fromList ? 'Back to stops' : 'Back to map'),
          findsOneWidget,
        );
        await tapVisible(tester, 'detail-return');
        expect(
          model.panel,
          fromList ? WorkbenchPanel.list : WorkbenchPanel.map,
        );
        expect(model.query.search, 'Silverline');
        expect(model.query.status, DeliveryStatus.completed);
        expect(model.listSession.scrollOffset, 137);
        expect(model.listSession.focusedReference, repository.stop.reference);
        expect(repository.closeCalls, 0);
        model.openDetail(repository.stop.id, origin: origin);
        await tester.pump();
        await tapVisible(tester, 'detail-close');
        expect(
          model.panel,
          fromList ? WorkbenchPanel.list : WorkbenchPanel.map,
        );
        expect(repository.closeCalls, 0);
        await unmountDetail(tester, model);
      },
    );
  }

  testWidgets(
    'imported failure stays read-only and does not invent reason or time',
    (tester) async {
      final repository = DetailRepositoryFixture(
        stop: detailStop(status: DeliveryStatus.failed, timeWindow: null),
      );
      final model = await loadedDetail(repository);
      await tester.pumpWidget(detailHost(model));
      expect(find.text('Delivery failed'), findsOneWidget);
      expect(
        find.text('No reason provided in the source record.'),
        findsOneWidget,
      );
      expect(find.text('Time window not provided'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-recorded-time')), findsNothing);
      expect(
        find.byKey(const ValueKey('detail-acknowledged-time')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('detail-complete')), findsNothing);
      expect(find.byKey(const ValueKey('detail-fail')), findsNothing);
      expect(repository.submitCalls, 0);
      await unmountDetail(tester, model);
    },
  );

  testWidgets('actual result and acknowledgement times are projected', (
    tester,
  ) async {
    final repository = DetailRepositoryFixture(
      stop: detailStop(
        status: DeliveryStatus.failed,
        reason: 'Business closed',
        note: 'No lights on',
        recordedAt: DateTime.utc(2026, 10, 10, 7),
        acknowledgedAt: DateTime.utc(2026, 10, 10, 8),
      ),
    );
    final model = await loadedDetail(repository);
    await tester.pumpWidget(detailHost(model));
    expect(find.text('Business closed'), findsOneWidget);
    expect(find.text('No lights on'), findsOneWidget);
    expect(find.text('Acknowledged'), findsOneWidget);
    expect(find.byKey(const ValueKey('detail-recorded-time')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('detail-acknowledged-time')),
      findsOneWidget,
    );
    await unmountDetail(tester, model);
  });

  testWidgets(
    'complete commits once, remains terminal detail and disables in-flight close',
    (tester) async {
      final gate = Completer<void>();
      final repository = DetailRepositoryFixture()..saveGate = gate;
      final model = await loadedDetail(repository, origin: DetailOrigin.list);
      await tester.pumpWidget(detailHost(model));
      final complete = find.byKey(const ValueKey('detail-complete'));
      await tester.tap(complete);
      await tester.tap(complete);
      await tester.pump();
      expect(repository.submitCalls, 1);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('detail-close')))
            .onPressed,
        isNull,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.selectedStop!.status, DeliveryStatus.completed);
      expect(repository.queue, hasLength(1));
      expect(find.text('Delivery completed'), findsOneWidget);
      expect(find.text('Saved locally. Waiting to sync.'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-complete')), findsNothing);
      expect(find.byKey(const ValueKey('detail-fail')), findsNothing);
      expect(find.text('Back to stops'), findsOneWidget);
      await unmountDetail(tester, model);
    },
  );

  testWidgets(
    'postcommit snapshot failure remains truthful read-only until reload',
    (tester) async {
      final repository = DetailRepositoryFixture()..failRefreshAfterSave = true;
      final model = await loadedDetail(repository);
      await tester.pumpWidget(detailHost(model));
      await tapVisible(tester, 'detail-complete');
      expect(repository.stop.status, DeliveryStatus.completed);
      expect(model.selectedStop!.status, DeliveryStatus.pending);
      expect(find.text('Delivery completed'), findsOneWidget);
      expect(find.text('Imported delivery record'), findsNothing);
      expect(find.byKey(const ValueKey('detail-recorded-time')), findsNothing);
      expect(find.byKey(const ValueKey('detail-complete')), findsNothing);
      expect(find.byKey(const ValueKey('detail-fail')), findsNothing);
      expect(find.text('Reload details'), findsOneWidget);
      repository.failRefreshAfterSave = false;
      await tester.ensureVisible(find.text('Reload details'));
      await tester.tap(find.text('Reload details'));
      await tester.pumpAndSettle();
      expect(model.selectedStop!.status, DeliveryStatus.completed);
      expect(
        find.byKey(const ValueKey('detail-recorded-time')),
        findsOneWidget,
      );
      expect(repository.submitCalls, 1);
      await unmountDetail(tester, model);
    },
  );

  testWidgets(
    'form system back returns to detail, then detail back restores list',
    (tester) async {
      final repository = DetailRepositoryFixture();
      final model = await loadedDetail(repository, origin: DetailOrigin.list);
      await tester.pumpWidget(detailHost(model));
      await tapVisible(tester, 'detail-fail');
      expect(find.byType(DeliveryFailureSheet), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(DeliveryFailureSheet), findsNothing);
      expect(model.panel, WorkbenchPanel.detail);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(model.panel, WorkbenchPanel.list);
      expect(repository.closeCalls, 0);
      await unmountDetail(tester, model);
    },
  );
}
