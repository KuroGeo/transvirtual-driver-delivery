import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery/feedback/workbench_notice.dart';
import 'package:ocean_delivery/ui/delivery/list/stop_status_badge.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../map/map_fixture.dart';
import '../support/delivery_risk_fixture.dart';
import '../support/formal_workbench_fixture.dart';

const _maximumScale = 53 / 17;
const _safeBounds = Rect.fromLTWH(0, 47, 390, 763);

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  testWidgets(
    'maximum OS text opens Browse with a readable first stop and uncut saved feedback',
    (tester) async {
      _maximumPhone(tester);
      final (_, model) = await _mount(tester);
      expect(model.stops, hasLength(30));
      final first = model.result.stops.first;

      // No ensureVisible, list drag, or programmatic scroll before this check.
      // Browse must make a delivery readable on its first displayed frame.
      await _tapActual(tester, 'browse-stops');
      expect(model.panel, WorkbenchPanel.list);
      _expectTaskArea(tester);
      final viewport = _byKey('stop-list-scroll');
      expect(_listPosition(tester).pixels, 0);
      _expectReadableStop(tester, model, first, viewport);
      _expectToolbar(tester);
      expect(_byKey('map-attribution').hitTestable(), findsNothing);
      expect(_byKey('online-toggle').hitTestable(), findsNothing);

      // A controlled notice exercises the real success-feedback presentation.
      // This is a geometry regression, not evidence that an update was saved.
      model.showNotice(
        'Saved locally · waiting to sync.',
        kind: NoticeKind.saved,
      );
      await pumpFormalFrames(tester);
      final message = _byKey('notice-message');
      expect(tester.widget<Text>(message).data, model.notice.value!.message);
      _expectFullyWithin(tester, message, viewport);
      _expectMaximumScale(tester, message);
      _expectReadableStop(tester, model, first, viewport);
      _expectToolbar(tester);

      await _tapActual(tester, 'stop-${first.reference}');
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.selectedStop!.reference, first.reference);
      expect(model.detailContext!.origin, DetailOrigin.list);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'maximum OS text folds query tools into readable stops and restores typed list return',
    (tester) async {
      _maximumPhone(tester);
      final (_, model) = await _mount(tester);
      await _tapActual(tester, 'browse-stops');
      _expectTaskArea(tester);
      _expectToolbar(tester);

      await _tapActual(tester, 'list-query-controls');
      final queryViewport = _byKey('list-query-scroll');
      expect(queryViewport, findsOneWidget);
      await _dragToExpose(tester, 'stop-search', queryViewport);
      final search = _byKey('stop-search');
      _expectFullyWithin(tester, search, queryViewport);
      _expectMaximumScale(tester, search);
      expect(
        tester.getSize(search).height,
        lessThan(tester.getSize(queryViewport).height),
        reason: 'The complete scaled field must fit the real tool viewport.',
      );
      await tester.enterText(search, 'Silverline');
      await pumpFormalFrames(tester);
      await _dragToExpose(tester, 'filter-pending', queryViewport);
      await _tapActual(tester, 'filter-pending');
      expect(model.query.search, 'Silverline');
      expect(model.query.status, DeliveryStatus.pending);

      // Closing the tool state must reveal a matching row immediately, rather
      // than leave oversized controls above it in the same short viewport.
      await _tapActual(tester, 'list-query-controls');
      expect(_byKey('stop-search'), findsNothing);
      expect(_byKey('list-query-scroll'), findsNothing);
      expect(model.query.search, 'Silverline');
      expect(model.query.status, DeliveryStatus.pending);
      final first = model.result.stops.first;
      _expectReadableStop(tester, model, first, _byKey('stop-list-scroll'));
      _expectToolbar(tester);

      // The explicit Show stops action is another real route out of tools.
      await _tapActual(tester, 'list-query-controls');
      expect(
        tester.widget<TextField>(_byKey('stop-search')).controller!.text,
        'Silverline',
      );
      await _dragToExpose(tester, 'list-query-apply', queryViewport);
      await _tapActual(tester, 'list-query-apply');
      expect(_byKey('stop-search'), findsNothing);
      expect(model.query.search, 'Silverline');
      expect(model.query.status, DeliveryStatus.pending);
      _expectReadableStop(tester, model, first, _byKey('stop-list-scroll'));

      // Two compact matches may both fit, which is an accessibility benefit.
      // Broaden through actual query tools before requiring nonzero scrolling.
      await _tapActual(tester, 'list-query-controls');
      await _dragToExpose(tester, 'stop-search', queryViewport);
      await tester.enterText(_byKey('stop-search'), 'a');
      await pumpFormalFrames(tester);
      await _tapActual(tester, 'list-query-controls');
      expect(model.query.search, 'a');
      expect(model.query.status, DeliveryStatus.pending);
      expect(model.result.stops.length, greaterThanOrEqualTo(10));
      final later = model.result.stops[5];
      final rowKey = 'stop-${later.reference}';
      await _dragToExpose(tester, rowKey, _byKey('stop-list-scroll'));
      final savedOffset = _listPosition(tester).pixels;
      expect(savedOffset, greaterThan(0));
      await _tapActual(tester, rowKey);
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.detailContext!.origin, DetailOrigin.list);
      expect(model.selectedStop!.reference, later.reference);
      _expectTaskArea(tester);
      final card = _byKey('delivery-detail-card');
      expect(
        tester.getSize(card).height,
        greaterThanOrEqualTo(_safeBounds.height * .9),
        reason: 'Large-text detail must use the SafeArea task workspace.',
      );
      _expectFullyWithin(
        tester,
        _byKey('detail-customer'),
        _byKey('detail-scroll'),
      );
      _expectMaximumScale(tester, _byKey('detail-customer'));
      _expectHitTarget(tester, _byKey('detail-close'));

      await _tapActual(tester, 'detail-close');
      expect(model.panel, WorkbenchPanel.list);
      expect(model.query.search, 'a');
      expect(model.query.status, DeliveryStatus.pending);
      expect(_listPosition(tester).pixels, closeTo(savedOffset, .1));
      expect(model.listSession.focusedReference, later.reference);
      expect(_byKey(rowKey).hitTestable(), findsOneWidget);
      _expectToolbar(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'maximum OS text scrolls complete detail content and saves a real offline delivery',
    (tester) async {
      _maximumPhone(tester);
      final (fixture, model) = await _mount(tester);
      await tapFormalTransition(
        tester,
        model,
        'online-toggle',
        busy: () => model.isChangingOnline,
      );
      expect(model.online, isFalse);
      await _tapActual(tester, 'browse-stops');
      final stop = model.result.stops.first;
      expect(stop.status, DeliveryStatus.pending);
      _expectReadableStop(tester, model, stop, _byKey('stop-list-scroll'));
      await _dragToExpose(
        tester,
        'stop-${stop.reference}',
        _byKey('stop-list-scroll'),
      );
      await _tapActual(tester, 'stop-${stop.reference}');
      expect(model.detailContext!.origin, DetailOrigin.list);
      _expectTaskArea(tester);
      final viewport = _byKey('detail-scroll');
      final closeBounds = tester.getRect(_byKey('detail-close'));
      _expectHitTarget(tester, _byKey('detail-close'));

      // Read the genuine full customer, street, locality and delivery window
      // in order using actual drags, rather than only reaching the close icon.
      final address = stop.address.split(',');
      for (final (key, value) in [
        ('detail-customer', stop.customerName),
        ('detail-street', address.first.trim()),
        ('detail-locality', address.skip(1).join(',').trim()),
      ]) {
        await _dragToExpose(tester, key, viewport);
        final field = _byKey(key);
        _expectFullyWithin(tester, field, viewport);
        _expectMaximumScale(tester, field);
        final text = tester.widget<Text>(field);
        expect(text.data, value);
        expect(text.maxLines, isNull);
        expect(text.overflow, isNot(TextOverflow.ellipsis));
        expect(tester.getRect(_byKey('detail-close')), closeBounds);
        _expectHitTarget(tester, _byKey('detail-close'));
      }
      final window = find.descendant(
        of: _byKey('delivery-detail-card'),
        matching: find.text(stop.timeWindow!.replaceAll('-', '–')),
      );
      await _dragFinderToExpose(
        tester,
        window,
        viewport,
        description: 'full delivery time window',
      );
      _expectFullyWithin(tester, window, viewport);
      _expectMaximumScale(tester, window);
      await _dragToExpose(tester, 'detail-complete', viewport);
      _expectFullyWithin(tester, _byKey('detail-complete'), viewport);
      _expectHitTarget(tester, _byKey('detail-complete'));
      expect(
        tester.widget<FilledButton>(_byKey('detail-complete')).onPressed,
        isNotNull,
      );
      final scrollable = find
          .descendant(of: viewport, matching: find.byType(Scrollable))
          .first;
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        greaterThan(0),
        reason:
            'The full scaled body and completion action require real scroll.',
      );

      // This helper awaits the actual UI -> VM -> file SQLite transition.
      // The action was already fully exposed by the real gestures above.
      await tapFormalTransition(
        tester,
        model,
        'detail-complete',
        busy: () => model.isSaving,
      );
      expect(model.selectedStop!.status, DeliveryStatus.completed);
      expect(model.queueCount, 1);
      expect(model.online, isFalse);
      expect(model.notice.value!.kind, NoticeKind.saved);
      expect(model.notice.value!.message, 'Saved locally · waiting to sync.');
      expect(_byKey('detail-complete'), findsNothing);

      final snapshot = (await awaitFormalIO(
        tester,
        () => fixture.sandbox.persistedSnapshot('ocean_delivery.sqlite'),
      ))!;
      final persistedStop = (snapshot['stops'] as List)
          .cast<Map<String, Object?>>()
          .singleWhere((row) => row['id'] == stop.id);
      final pending = (snapshot['outbox'] as List).cast<Map<String, Object?>>();
      expect(persistedStop['status'], 'completed');
      expect(persistedStop['recorded_at'], isA<int>());
      expect(pending, hasLength(1));
      expect(pending.single['stop_id'], stop.id);
      expect(pending.single['status'], 'completed');
      expect(pending.single['operation_id'], persistedStop['operation_id']);
      expect(pending.single['recorded_at'], persistedStop['recorded_at']);

      await _dragToExpose(tester, 'detail-saved', viewport);
      _expectFullyWithin(tester, _byKey('detail-saved'), viewport);
      _expectMaximumScale(tester, _byKey('detail-saved'));
      expect(
        tester.widget<Text>(_byKey('detail-saved')).data,
        'Saved locally. Waiting to sync.',
      );
      _expectHitTarget(tester, _byKey('detail-close'));
      await _tapActual(tester, 'detail-close');
      expect(model.panel, WorkbenchPanel.list);
      _expectTaskArea(tester);
      await _dragToExpose(tester, 'notice-message', _byKey('stop-list-scroll'));
      _expectFullyWithin(
        tester,
        _byKey('notice-message'),
        _byKey('stop-list-scroll'),
      );
      expect(
        tester.widget<Text>(_byKey('notice-message')).data,
        model.notice.value!.message,
      );
      _expectMaximumScale(tester, _byKey('notice-message'));
      final savedStop = model.stopById(stop.id)!;
      expect(savedStop.status, DeliveryStatus.completed);
      expect(model.awaitsService(savedStop), isTrue);
      _expectReadableStop(tester, model, savedStop, _byKey('stop-list-scroll'));
      _expectToolbar(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ordinary OS text preserves the prototype map drawer and complete row metadata',
    (tester) async {
      _phone(tester, scale: 1);
      final (_, model) = await _mount(tester);
      final first = model.result.stops.first;
      await _tapActual(tester, 'browse-stops');
      expect(model.panel, WorkbenchPanel.list);
      expect(_byKey('large-text-task-workspace'), findsNothing);
      final panel = _byKey('list-workspace');
      final bounds = tester.getRect(panel);
      final map = tester.getRect(_byKey('delivery-map'));
      expect(bounds.left, closeTo(map.left, .1));
      expect(bounds.right, closeTo(map.right, .1));
      expect(bounds.bottom, closeTo(map.bottom, .1));
      expect(bounds.height, lessThanOrEqualTo(530));
      expect(bounds.top, greaterThan(_safeBounds.top + 80));
      expect(_byKey('list-grip'), findsOneWidget);
      expect(find.text('Stops on the map'), findsOneWidget);
      expect(
        find.text('${model.result.matchedCount} stops · Nearest first'),
        findsOneWidget,
      );
      expect(_byKey('stop-search'), findsNothing);
      expect(_byKey('list-query-scroll'), findsNothing);
      expect(_byKey('map-attribution').hitTestable(), findsOneWidget);
      expect(MediaQuery.of(tester.element(panel)).textScaler.scale(16) / 16, 1);

      final row = _byKey('stop-${first.reference}');
      for (final value in [
        first.customerName,
        first.address,
        first.timeWindow!.replaceAll('-', '–'),
        straightLineDistanceLabel(model.result.distanceMeters(first)!),
      ]) {
        final field = find.descendant(of: row, matching: find.text(value));
        _expectFullyWithin(tester, field, _byKey('stop-list-scroll'));
      }
      final badge = find.descendant(
        of: row,
        matching: find.byType(StopStatusBadge),
      );
      expect(tester.widget<StopStatusBadge>(badge).status, first.status);
      final status = find.descendant(
        of: badge,
        matching: find.text(_statusLabel(first.status)),
      );
      _expectFullyWithin(tester, status, _byKey('stop-list-scroll'));
      expect(
        MediaQuery.of(tester.element(status)).textScaler.scale(16) / 16,
        1,
      );
      _expectToolbar(tester);
      await _tapActual(tester, 'stop-${first.reference}');
      expect(model.detailContext!.origin, DetailOrigin.list);
      expect(_byKey('large-text-task-workspace'), findsNothing);
      await _tapActual(tester, 'detail-close');
      expect(model.panel, WorkbenchPanel.list);
      expect(model.listSession.focusedReference, first.reference);
      expect(tester.getRect(panel), bounds);
      await _tapActual(tester, 'close-list');
      expect(model.panel, WorkbenchPanel.map);
      expect(tester.takeException(), isNull);
    },
  );
}

Finder _byKey(String key) => find.byKey(ValueKey(key));

void _maximumPhone(WidgetTester tester) => _phone(tester, scale: _maximumScale);

void _phone(WidgetTester tester, {required double scale}) {
  mapTestSize(tester);
  tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
  tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<(FormalWorkbenchFixture, DeliveryViewModel)> _mount(
  WidgetTester tester,
) async {
  await completeFixtureIO(tester, () async {
    final font = FontLoader('Inter')
      ..addFont(rootBundle.load('assets/InterVariable.ttf'));
    await font.load();
  }, description: 'real Inter typography must load before geometry checks');
  final sandbox = (await awaitFormalIO(tester, DeliveryRiskSandbox.create))!;
  final fixture = FormalWorkbenchFixture(sandbox);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await awaitFormalIO(tester, fixture.dispose);
  });
  final model = (await awaitFormalIO(
    tester,
    () => fixture.createModel(
      loadCsv: () => rootBundle.loadString('assets/deliveries.csv'),
    ),
  ))!;
  final provider = await fixtureProvider(tester);
  final controller = fixtureController(tester);
  await mountFormalApp(
    tester,
    model: model,
    provider: provider,
    controller: controller,
  );
  await waitForFixtureMap(tester, controller);
  return (fixture, model);
}

void _expectTaskArea(WidgetTester tester) {
  final workspace = _byKey('large-text-task-workspace');
  expect(workspace, findsOneWidget);
  final bounds = tester.getRect(workspace);
  expect(bounds.height, greaterThanOrEqualTo(_safeBounds.height * .95));
  expect(_safeBounds.inflate(.5).contains(bounds.topLeft), isTrue);
  expect(_safeBounds.inflate(.5).contains(bounds.bottomRight), isTrue);
  _expectMaximumScale(tester, workspace);
}

void _expectMaximumScale(WidgetTester tester, Finder target) {
  expect(
    MediaQuery.of(tester.element(target)).textScaler.scale(16) / 16,
    closeTo(_maximumScale, 1e-12),
    reason:
        'Layout must preserve the actual OS scaler without a product clamp.',
  );
}

void _expectFullyWithin(WidgetTester tester, Finder child, Finder viewport) {
  expect(child, findsOneWidget);
  expect(viewport, findsOneWidget);
  final bounds = tester.getRect(child);
  final visible = tester.getRect(viewport).inflate(.5);
  expect(
    visible.contains(bounds.topLeft),
    isTrue,
    reason: '$bounds in $visible',
  );
  expect(
    visible.contains(bounds.bottomRight),
    isTrue,
    reason: '$bounds in $visible must not be clipped',
  );
}

String _statusLabel(DeliveryStatus status) => switch (status) {
  DeliveryStatus.pending => 'Pending',
  DeliveryStatus.completed => 'Completed',
  DeliveryStatus.failed => 'Failed',
};

void _expectReadableStop(
  WidgetTester tester,
  DeliveryViewModel model,
  Stop stop,
  Finder viewport,
) {
  final status =
      '${_statusLabel(stop.status)}'
      '${model.awaitsService(stop) ? ' · Waiting to sync' : ''}';
  for (final (key, value) in [
    ('list-customer-${stop.reference}', stop.customerName),
    ('list-reference-${stop.reference}', stop.reference),
    ('list-status-${stop.reference}', status),
  ]) {
    final field = _byKey(key);
    _expectFullyWithin(tester, field, viewport);
    final text = tester.widget<Text>(field);
    expect(text.data, value);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    _expectMaximumScale(tester, field);
  }
  final row = _byKey('stop-${stop.reference}');
  expect(row.hitTestable(), findsOneWidget);
  expect(tester.getSize(row).height, lessThan(tester.getSize(viewport).height));
}

void _expectHitTarget(WidgetTester tester, Finder target) {
  expect(target.hitTestable(), findsOneWidget);
  expect(tester.getSize(target).width, greaterThanOrEqualTo(44));
  expect(tester.getSize(target).height, greaterThanOrEqualTo(44));
  final bounds = tester.getRect(target);
  expect(_safeBounds.inflate(.5).contains(bounds.topLeft), isTrue);
  expect(_safeBounds.inflate(.5).contains(bounds.bottomRight), isTrue);
}

void _expectToolbar(WidgetTester tester) {
  for (final key in ['list-query-controls', 'list-sync', 'close-list']) {
    _expectHitTarget(tester, _byKey(key));
  }
}

ScrollPosition _listPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: _byKey('stop-list-scroll'),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

Future<void> _tapActual(WidgetTester tester, String key) async {
  final target = _byKey(key);
  expect(
    target.hitTestable(),
    findsOneWidget,
    reason: '$key must be reachable',
  );
  await performFixtureUI(
    tester,
    () => tester.tap(target),
    description: 'actual large-text UI tap: $key',
  );
  await pumpFormalFrames(tester);
}

Future<void> _dragToExpose(WidgetTester tester, String key, Finder viewport) =>
    _dragFinderToExpose(tester, _byKey(key), viewport, description: key);

Future<void> _dragFinderToExpose(
  WidgetTester tester,
  Finder target,
  Finder viewport, {
  required String description,
}) async {
  for (var attempt = 0; attempt < 12; attempt++) {
    final visible = tester.getRect(viewport).inflate(.5);
    var delta = const Offset(0, -140);
    if (target.evaluate().isNotEmpty) {
      final bounds = tester.getRect(target);
      if (visible.contains(bounds.topLeft) &&
          visible.contains(bounds.bottomRight) &&
          target.hitTestable().evaluate().isNotEmpty) {
        return;
      }
      if (bounds.top < visible.top) delta = const Offset(0, 140);
    }
    await tester.drag(viewport, delta);
    await pumpFormalFrames(tester);
  }
  fail(
    '$description did not become fully readable after 12 actual bounded drags',
  );
}
