import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery/failure/delivery_failure_sheet.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/repository_fixture.dart';
import '../map/map_fixture.dart';
import 'detail_test_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  testWidgets('reason choice and trimmed Other explanation are required', (
    tester,
  ) async {
    final repository = DetailRepositoryFixture();
    final model = await loadedDetail(repository);
    await tester.pumpWidget(detailHost(model));
    await tapVisible(tester, 'detail-fail');
    await tapVisible(tester, 'failure-save');
    expect(find.text('Choose a reason to continue.'), findsOneWidget);
    expect(repository.submitCalls, 0);
    await tapVisible(tester, 'failure-reason-other');
    final note = find.byKey(const ValueKey('failure-note'));
    await tester.ensureVisible(note);
    await tester.enterText(note, ' \n\t ');
    await tapVisible(tester, 'failure-save');
    expect(find.text('Enter a reason to continue.'), findsOneWidget);
    expect(repository.submitCalls, 0);
    await tester.ensureVisible(note);
    await tester.enterText(note, '  Access gate is locked  \n');
    await tapVisible(tester, 'failure-save');
    expect(find.byType(DeliveryFailureSheet), findsNothing);
    expect(model.panel, WorkbenchPanel.detail);
    expect(model.selectedStop!.status, DeliveryStatus.failed);
    expect(repository.stop.reason, 'Access gate is locked');
    expect(repository.stop.note, isNull);
    expect(repository.queue.single.reason, 'Access gate is locked');
    expect(repository.queue.single.note, isNull);
    expect(find.text('Delivery failed'), findsOneWidget);
    expect(find.text('Saved locally. Waiting to sync.'), findsOneWidget);
    await unmountDetail(tester, model);
  });

  for (final (label, slug) in [
    ('Recipient unavailable', 'recipient-unavailable'),
    ('Business closed', 'business-closed'),
    ('Address not found', 'address-not-found'),
  ]) {
    testWidgets(
      '$label saves preset with optional trimmed note and keeps terminal detail',
      (tester) async {
        final repository = DetailRepositoryFixture();
        final model = await loadedDetail(repository, origin: DetailOrigin.list);
        await tester.pumpWidget(detailHost(model));
        await tapVisible(tester, 'detail-fail');
        await tapVisible(tester, 'failure-reason-$slug');
        final note = find.byKey(const ValueKey('failure-note'));
        await tester.ensureVisible(note);
        await tester.enterText(note, '  Called reception twice  \n');
        await tapVisible(tester, 'failure-save');
        expect(repository.stop.reason, label);
        expect(repository.stop.note, 'Called reception twice');
        expect(repository.queue.single.note, 'Called reception twice');
        expect(model.panel, WorkbenchPanel.detail);
        expect(find.byType(DeliveryFailureSheet), findsNothing);
        expect(find.text('Delivery failed'), findsOneWidget);
        expect(find.text('Back to stops'), findsOneWidget);
        expect(find.byKey(const ValueKey('detail-complete')), findsNothing);
        expect(find.byKey(const ValueKey('detail-fail')), findsNothing);
        await unmountDetail(tester, model);
      },
    );
  }

  testWidgets(
    'real outbox failure keeps selection and draft, retry commits only one result',
    (tester) async {
      final value = (await tester.runAsync(RepositoryFixture.create))!;
      late final DeliveryViewModel model;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await completeFixtureIO(tester, () async {
          await model.close();
          await value.dispose();
        }, description: 'actual detail model and SQLite fixture must close');
      });
      await completeFixtureIO(tester, () async {
        model = DeliveryViewModel(
          repository: value.repository,
          syncCoordinator: SyncCoordinator(repository: value.repository),
        );
        await model.load();
      }, description: 'actual detail VM creation and file load must finish');
      final stop = model.stops.first;
      model.openDetail(stop.id, origin: DetailOrigin.list);
      await tester.runAsync(() async {
        await (await value.admin).execute('''
        CREATE TRIGGER reject_detail_result BEFORE INSERT ON outbox
        BEGIN SELECT RAISE(ABORT, 'controlled detail outbox failure'); END
      ''');
      });
      await tester.pumpWidget(detailHost(model));
      await tapVisible(tester, 'detail-fail');
      await tapVisible(tester, 'failure-reason-business-closed');
      final note = find.byKey(const ValueKey('failure-note'));
      await tester.ensureVisible(note);
      await tester.enterText(note, '  Shutters closed  \n');
      await _tapAndWaitForSave(tester, model);
      expect(find.byType(DeliveryFailureSheet), findsOneWidget);
      expect(
        find.text('Could not save. Your choices and note are kept. Try again.'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(note).controller!.text,
        '  Shutters closed  \n',
      );
      final chosen = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byKey(const ValueKey('failure-reason-business-closed')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(chosen.properties.checked, isTrue);
      final failedSnapshot = (await tester.runAsync(
        value.repository.loadStops,
      ))!;
      expect(failedSnapshot.first.status, DeliveryStatus.pending);
      expect(failedSnapshot.first.recordedAt, isNull);
      expect(
        (await tester.runAsync(value.repository.pendingUpdates))!,
        isEmpty,
      );
      expect(model.panel, WorkbenchPanel.detail);

      await tester.runAsync(() async {
        await (await value.admin).execute('DROP TRIGGER reject_detail_result');
      });
      await _tapAndWaitForSave(tester, model);
      expect(find.byType(DeliveryFailureSheet), findsNothing);
      expect(model.selectedStop!.status, DeliveryStatus.failed);
      expect(model.selectedStop!.reason, 'Business closed');
      expect(model.selectedStop!.note, 'Shutters closed');
      final queue = (await tester.runAsync(value.repository.pendingUpdates))!;
      expect(queue, hasLength(1));
      expect(queue.single.stopId, stop.id);
      expect(queue.single.recordedAt, model.selectedStop!.recordedAt);
      expect(model.panel, WorkbenchPanel.detail);
      expect(find.byKey(const ValueKey('detail-fail')), findsNothing);
    },
  );

  testWidgets(
    'in-flight save blocks duplicate, close and system back without discarding draft',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gate = Completer<void>();
      final repository = DetailRepositoryFixture()..saveGate = gate;
      final model = await loadedDetail(
        repository,
        origin: DetailOrigin.nearest,
      );
      await tester.pumpWidget(detailHost(model));
      await tapVisible(tester, 'detail-fail');
      await tapVisible(tester, 'failure-reason-recipient-unavailable');
      final note = find.byKey(const ValueKey('failure-note'));
      await tester.ensureVisible(note);
      await tester.enterText(note, '  Preserve this draft  ');
      final save = find.byKey(const ValueKey('failure-save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.tap(save);
      await tester.pump();
      expect(repository.submitCalls, 1);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('failure-close')))
            .onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(DeliveryFailureSheet), findsOneWidget);
      expect(model.panel, WorkbenchPanel.detail);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('failure-sheet'))).dy,
        greaterThan(8),
      );
      await tester.tapAt(const Offset(195, 8));
      await tester.pumpAndSettle();
      expect(find.byType(DeliveryFailureSheet), findsOneWidget);
      expect(
        tester.widget<TextField>(note).controller!.text,
        '  Preserve this draft  ',
      );
      expect(repository.submitCalls, 1);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(DeliveryFailureSheet), findsNothing);
      expect(repository.queue, hasLength(1));
      expect(repository.queue.single.note, 'Preserve this draft');
      expect(find.text('Back to map'), findsOneWidget);
      expect(model.detailContext!.origin, DetailOrigin.nearest);
      await unmountDetail(tester, model);
    },
  );

  testWidgets(
    'idle scrim click closes only the failure form and keeps detail',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = DetailRepositoryFixture();
      final model = await loadedDetail(repository, origin: DetailOrigin.list);
      await tester.pumpWidget(detailHost(model));
      await tapVisible(tester, 'detail-fail');
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('failure-sheet'))).dy,
        greaterThan(8),
      );
      await tester.tapAt(const Offset(195, 8));
      await tester.pumpAndSettle();
      expect(find.byType(DeliveryFailureSheet), findsNothing);
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.detailContext!.origin, DetailOrigin.list);
      expect(model.selectedStop!.status, DeliveryStatus.pending);
      expect(repository.submitCalls, 0);
      expect(repository.closeCalls, 0);
      await unmountDetail(tester, model);
    },
  );

  testWidgets(
    'explicit cancellation returns only to detail without changing stop',
    (tester) async {
      final repository = DetailRepositoryFixture();
      final model = await loadedDetail(repository);
      await tester.pumpWidget(detailHost(model));
      await tapVisible(tester, 'detail-fail');
      await tapVisible(tester, 'failure-reason-other');
      await tapVisible(tester, 'failure-close');
      expect(find.byType(DeliveryFailureSheet), findsNothing);
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.selectedStop!.status, DeliveryStatus.pending);
      expect(repository.submitCalls, 0);
      expect(repository.queue, isEmpty);
      await unmountDetail(tester, model);
    },
  );

  testWidgets(
    '390px and 2x text keep failure controls above keyboard without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = DetailRepositoryFixture();
      final model = await loadedDetail(repository);
      await tester.pumpWidget(
        detailHost(model, textScale: 2, keyboardInset: 320),
      );
      await tapVisible(tester, 'detail-fail');
      await tapVisible(tester, 'failure-reason-other');
      final note = find.byKey(const ValueKey('failure-note'));
      await tester.ensureVisible(note);
      await tester.enterText(
        note,
        '  The access gate is locked and the recipient could not be reached.  ',
      );
      // Finish the enlarged field's layout/caret reveal before scrolling to
      // another control. A real drag ends editing focus and moves the form.
      await tester.pumpAndSettle();
      final scroll = find.byKey(const ValueKey('failure-scroll'));
      final initialViewport = tester.getRect(scroll);
      // Use the form's padding so the gesture reaches its scrollable instead
      // of the multiline field's nested scrollable.
      await tester.dragFrom(
        Offset(initialViewport.left + 8, initialViewport.center.dy),
        const Offset(0, -220),
      );
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('failure-save'));
      await Scrollable.ensureVisible(tester.element(save), alignment: 1);
      await tester.pumpAndSettle();
      expect(save.hitTestable(), findsOneWidget);
      final bounds = tester.getRect(save);
      final sheetBounds = tester.getRect(
        find.byKey(const ValueKey('failure-sheet')),
      );
      final viewportBounds = tester.getRect(scroll);
      final geometry =
          'sheet=$sheetBounds viewport=$viewportBounds save=$bounds keyboardTop=524';
      expect(
        sheetBounds.bottom,
        lessThanOrEqualTo(844 - 320),
        reason: geometry,
      );
      expect(
        viewportBounds.bottom,
        lessThanOrEqualTo(844 - 320),
        reason: geometry,
      );
      expect(bounds.top, greaterThanOrEqualTo(0), reason: geometry);
      expect(
        bounds.top,
        greaterThanOrEqualTo(viewportBounds.top),
        reason: geometry,
      );
      expect(
        bounds.bottom,
        lessThanOrEqualTo(viewportBounds.bottom),
        reason: geometry,
      );
      expect(bounds.bottom, lessThanOrEqualTo(844 - 320), reason: geometry);
      expect(tester.takeException(), isNull);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(model.selectedStop!.status, DeliveryStatus.failed);
      expect(find.byType(DeliveryFailureSheet), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('detail-return')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('detail-return')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await unmountDetail(tester, model);
    },
  );
}

Future<void> _tapAndWaitForSave(
  WidgetTester tester,
  DeliveryViewModel model,
) async {
  final target = find.byKey(const ValueKey('failure-save'));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  final completed = await tester.runAsync(() async {
    // This Future must be born in the same real zone as the SQLite work. A
    // fake-zone Completer awaited here queues its completion in the unpumped
    // fake zone and deadlocks runAsync.
    final settled = Completer<void>();
    var started = false;
    void observe() {
      started |= model.isSaving;
      if (started && !model.isSaving && !settled.isCompleted) {
        settled.complete();
      }
    }

    model.addListener(observe);
    try {
      await (() async {
        await tester.tap(target);
        await settled.future;
      })().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(
          'The UI-triggered SQLite save did not settle within five seconds.',
        ),
      );
      return true;
    } finally {
      model.removeListener(observe);
    }
  });
  expect(
    completed,
    isTrue,
    reason: 'The actual UI save must settle, not be skipped.',
  );
  // Render route dismissal/error feedback only after the real I/O has settled.
  await tester.pumpAndSettle();
}
