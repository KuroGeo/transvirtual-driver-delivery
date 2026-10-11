import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/ui/delivery/feedback/workbench_notice.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../map/map_fixture.dart';
import '../support/delivery_risk_fixture.dart';
import '../support/formal_workbench_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  testWidgets(
    'max system text keeps Browse fully exposed after nearest return and summary scroll',
    (tester) async {
      mapTestSize(tester);
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
      // The actual iOS N7 observation was 3.1176470588235294. Supply this
      // through the test platform dispatcher, never a product MediaQuery clamp.
      tester.platformDispatcher.textScaleFactorTestValue = 53 / 17;
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final (fixture, model, map) = await _mount(tester);
      expect(model.stops, hasLength(30));
      await tapFormalControl(tester, 'open-search');
      await tester.enterText(
        find.byKey(const ValueKey('map-search')),
        'TV-300002',
      );
      await pumpFormalFrames(tester);
      expect(model.result.stops.single.reference, 'TV-300002');
      final browse = find.byKey(const ValueKey('browse-stops'));
      final inherited = MediaQuery.of(tester.element(browse));
      expect(inherited.textScaler.scale(16) / 16, closeTo(53 / 17, 1e-12));
      expect(inherited.viewInsets.bottom, 0);

      // The compact map still has to contain the complete scaled entry, even
      // with its search field open. Attribution no longer repeats the reference.
      expect(
        tester.getSize(find.byKey(const ValueKey('delivery-map'))).height,
        lessThan(500),
      );
      expect(tester.getSize(browse).height, greaterThan(100));
      _expectEntryExposed(tester);

      await tapFormalControl(tester, 'fit-stops');
      await waitForFixtureMap(tester, map);
      _expectMatchExposed(tester);
      expect(model.selectedStop, isNull);
      await tapFormalControl(tester, 'map-stop-TV-300002');
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.detailContext!.origin, DetailOrigin.map);
      expect(model.selectedStop!.reference, 'TV-300002');
      await tapFormalControl(tester, 'detail-close');
      expect(model.panel, WorkbenchPanel.map);
      await waitForFixtureMap(tester, map);
      _expectMatchExposed(tester);
      _expectEntryExposed(tester);

      await tapFormalControl(tester, 'nearest-stop');
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.detailContext!.origin, DetailOrigin.nearest);
      await tapFormalControl(tester, 'detail-close');
      expect(model.panel, WorkbenchPanel.map);
      await waitForFixtureMap(tester, map);
      _expectEntryExposed(tester);

      model.showNotice(
        'The service is unavailable. Your locally saved delivery updates remain safe until a matching confirmation is saved.',
        kind: NoticeKind.error,
        persistent: true,
      );
      await pumpFormalFrames(tester);
      final pinned = tester.getRect(browse);
      final summary = find.byKey(const ValueKey('overview-summary'));
      final scrollable = find.descendant(
        of: summary,
        matching: find.byType(Scrollable),
      );
      expect(scrollable, findsOneWidget);
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));
      await tester.drag(summary, const Offset(0, -180));
      await pumpFormalFrames(tester);
      expect(position.pixels, greaterThan(0));
      expect(tester.getRect(browse), pinned);
      _expectEntryExposed(tester);

      // The pinned entry receives an actual tap without a reveal shortcut.
      await performFixtureUI(
        tester,
        () => tester.tap(browse),
        description: 'max-scale pinned Browse must receive its actual UI tap',
      );
      await pumpFormalFrames(tester);
      expect(model.panel, WorkbenchPanel.list);
      expect(find.byKey(const ValueKey('list-workspace')), findsOneWidget);
      expect(model.query.search, 'TV-300002');
      expect(tester.takeException(), isNull);
      await unmountFormalApp(tester, model);
      await awaitFormalIO(tester, fixture.dispose);
    },
  );

  testWidgets(
    'max system text keeps list search and tall rows reachable with typed return',
    (tester) async {
      mapTestSize(tester);
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
      tester.platformDispatcher.textScaleFactorTestValue = 53 / 17;
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final (fixture, model, _) = await _mount(tester);
      expect(model.stops, hasLength(30));
      await tapFormalTransition(
        tester,
        model,
        'online-toggle',
        busy: () => model.isChangingOnline,
      );
      expect(model.online, isFalse);
      expect(model.notice.value!.message, contains('Offline'));
      await tapFormalControl(tester, 'browse-stops');
      expect(model.panel, WorkbenchPanel.list);

      final title = find.text('Stops on the map');
      final primary = find.byKey(const ValueKey('stop-list-scroll'));
      final scrollable = find
          .descendant(of: primary, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(
        MediaQuery.of(tester.element(title)).textScaler.scale(16) / 16,
        closeTo(53 / 17, 1e-12),
      );
      expect(find.text('Stops on the map'), findsOneWidget);
      _expectListActionsExposed(tester);
      final viewport = tester.getRect(primary);
      // In the actual failed run, the fixed heading left only65.84px. There
      // must now be room for the full scaled field and an actual row target.
      await tapFormalControl(tester, 'list-query-controls');
      final search = find.byKey(const ValueKey('stop-search'));
      await tester.scrollUntilVisible(
        search,
        100,
        scrollable: scrollable,
        maxScrolls: 12,
      );
      await pumpFormalFrames(tester);
      expect(viewport.height, greaterThan(tester.getSize(search).height));
      final feedback = tester.getRect(
        find.byKey(const ValueKey('list-feedback-viewport')),
      );
      expect(feedback.height, greaterThan(0));
      expect(feedback.overlaps(viewport), isFalse);
      expect(
        tester.getRect(find.byKey(const ValueKey('workbench-notice'))).height,
        greaterThan(feedback.height),
        reason: 'The real scaled message requires its bounded feedback scroll',
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('notice-message'))).data,
        model.notice.value!.message,
      );
      final noticeScrollable = find.descendant(
        of: find.byKey(const ValueKey('list-feedback-viewport')),
        matching: find.byType(Scrollable),
      );
      expect(noticeScrollable, findsOneWidget);
      final noticePosition = tester
          .state<ScrollableState>(noticeScrollable)
          .position;
      expect(noticePosition.maxScrollExtent, greaterThan(0));
      final closeBounds = tester.getRect(
        find.byKey(const ValueKey('close-list')),
      );
      await tester.drag(
        find.byKey(const ValueKey('list-feedback-viewport')),
        const Offset(0, -100),
      );
      await pumpFormalFrames(tester);
      expect(noticePosition.pixels, greaterThan(0));
      expect(
        tester.getRect(find.byKey(const ValueKey('close-list'))),
        closeBounds,
      );
      _expectListActionsExposed(tester);

      await revealFormalControl(tester, 'stop-search');
      _expectFullyWithin(tester, search, primary);
      await tester.enterText(search, 'TV-300004');
      await pumpFormalFrames(tester);
      expect(model.result.stops.single.reference, 'TV-300004');
      expect(model.query.search, 'TV-300004');

      final row = find.byKey(const ValueKey('stop-TV-300004'));
      // Full OS-scaled query controls can extend beyond the lazy build cache.
      // Discover the matching row through actual finite primary-list drags,
      // before centering its existing tap target below.
      await tester.scrollUntilVisible(
        row,
        160,
        scrollable: scrollable,
        maxScrolls: 12,
      );
      expect(row, findsOneWidget);
      expect(tester.getSize(row).height, greaterThan(viewport.height));
      // A row larger than the viewport still exposes a genuine tap target
      // when the existing primary scroll centers it, just like Driver does.
      await revealFormalControl(tester, 'stop-TV-300004');
      expect(position.pixels, greaterThan(0));
      expect(tester.getRect(primary).contains(tester.getCenter(row)), isTrue);
      expect(row.hitTestable(), findsOneWidget);
      _expectListActionsExposed(tester);
      final savedOffset = position.pixels;
      await tapFormalControl(tester, 'stop-TV-300004');
      expect(model.panel, WorkbenchPanel.detail);
      expect(model.selectedStop!.reference, 'TV-300004');
      expect(model.detailContext!.origin, DetailOrigin.list);
      expect(model.listSession.focusedReference, 'TV-300004');
      expect(model.listSession.scrollOffset, closeTo(savedOffset, .1));

      await tapFormalControl(tester, 'detail-close');
      await tester.pump();
      expect(model.panel, WorkbenchPanel.list);
      expect(model.query.search, 'TV-300004');
      expect(position.pixels, closeTo(savedOffset, .1));
      final ink = tester.widget<InkWell>(
        find.descendant(of: row, matching: find.byType(InkWell)).first,
      );
      expect(ink.focusNode!.hasFocus, isTrue);
      expect(row.hitTestable(), findsOneWidget);
      _expectListActionsExposed(tester);
      await tapFormalControl(tester, 'close-list');
      expect(model.panel, WorkbenchPanel.map);
      expect(model.query.search, 'TV-300004');
      expect(tester.takeException(), isNull);
      await unmountFormalApp(tester, model);
      await awaitFormalIO(tester, fixture.dispose);
    },
  );

  for (final size in [const Size(390, 844), const Size(320, 640)]) {
    testWidgets('max text Browse has a usable viewport at $size', (
      tester,
    ) async {
      mapTestSize(tester);
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetViewInsets);
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
      tester.platformDispatcher.textScaleFactorTestValue = 53 / 17;
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final (fixture, model, _) = await _mount(tester);
      await tapFormalControl(tester, 'open-search');
      await tester.enterText(
        find.byKey(const ValueKey('map-search')),
        'TV-300006',
      );
      await pumpFormalFrames(tester);
      await tapFormalControl(tester, 'header-filter-pending');
      expect(model.query.status?.name, 'pending');
      model.showNotice(
        'Saved locally · Waiting for confirmation',
        kind: NoticeKind.information,
        persistent: true,
      );
      await pumpFormalFrames(tester);
      await tapFormalControl(tester, 'browse-stops');
      final primary = find.byKey(const ValueKey('stop-list-scroll'));
      final viewport = tester.getRect(primary);
      expect(
        viewport.height,
        greaterThan(size.height * .45),
        reason:
            'Large-text Browse must reserve room for results, not repeated map controls',
      );
      final footer = tester.getRect(
        find.byKey(const ValueKey('map-attribution')),
      );
      debugPrint(
        'Large-text geometry ${size.width}x${size.height}: '
        'results=${viewport.height}, attribution=${footer.height}, scale=${53 / 17}',
      );
      expect(footer.height, lessThanOrEqualTo(104));
      expect(viewport.overlaps(footer), isFalse);
      _expectListActionsExposed(tester);
      await tapFormalControl(tester, 'list-query-controls');
      final scrollable = find
          .descendant(of: primary, matching: find.byType(Scrollable))
          .first;
      final search = find.byKey(const ValueKey('stop-search'));
      await tester.scrollUntilVisible(
        search,
        120,
        scrollable: scrollable,
        maxScrolls: 12,
      );
      await pumpFormalFrames(tester);
      _expectFullyWithin(tester, search, primary);
      tester.view.viewInsets = FakeViewPadding(bottom: size.height * .3);
      await pumpFormalFrames(tester);
      await revealFormalControl(tester, 'stop-search');
      _expectFullyWithin(tester, search, primary);
      _expectListActionsExposed(tester);
      tester.view.resetViewInsets();
      await pumpFormalFrames(tester);
      await tester.enterText(search, 'TV-300006');
      await pumpFormalFrames(tester);
      expect(model.result.stops.single.reference, 'TV-300006');
      await tapFormalControl(tester, 'filter-failed');
      expect(model.result.stops, isEmpty);
      await tapFormalControl(tester, 'filter-pending');
      expect(model.result.stops.single.reference, 'TV-300006');
      await tapFormalControl(tester, 'waiting-only');
      expect(model.result.stops, isEmpty);
      await tapFormalControl(tester, 'waiting-only');
      expect(model.result.stops.single.reference, 'TV-300006');
      final row = find.byKey(const ValueKey('stop-TV-300006'));
      await tester.scrollUntilVisible(
        row,
        160,
        scrollable: scrollable,
        maxScrolls: 16,
      );
      await revealFormalControl(tester, 'stop-TV-300006');
      expect(row.hitTestable(), findsOneWidget);
      expect(
        MediaQuery.textScalerOf(tester.element(row)).scale(16) / 16,
        closeTo(53 / 17, 1e-12),
      );
      await tapFormalControl(tester, 'stop-TV-300006');
      expect(model.detailContext!.origin, DetailOrigin.list);
      await tapFormalControl(tester, 'detail-close');
      expect(model.panel, WorkbenchPanel.list);
      expect(model.query.search, 'TV-300006');
      _expectListActionsExposed(tester);
      await tapFormalControl(tester, 'close-list');
      expect(model.panel, WorkbenchPanel.map);
      expect(model.query.search, 'TV-300006');
      await tapFormalControl(tester, 'map-attribution');
      expect(find.text('Map information'), findsOneWidget);
      expect(
        find.textContaining('Map data © OpenStreetMap contributors'),
        findsOneWidget,
      );
      await tapFormalControl(tester, 'close-map-information');
      expect(find.text('Map information'), findsNothing);
      expect(tester.takeException(), isNull);
      await unmountFormalApp(tester, model);
      await awaitFormalIO(tester, fixture.dispose);
    });
  }

  testWidgets('normal text narrow phone keeps Browse controls usable', (
    tester,
  ) async {
    mapTestSize(tester);
    tester.view.physicalSize = const Size(320, 640);
    final (fixture, model, _) = await _mount(tester);
    await tapFormalControl(tester, 'browse-stops');
    _expectListActionsExposed(tester);
    await tapFormalControl(tester, 'list-query-controls');
    await tapFormalControl(tester, 'stop-search');
    await tester.enterText(
      find.byKey(const ValueKey('stop-search')),
      'TV-300006',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpFormalFrames(tester);
    expect(model.result.stops.single.reference, 'TV-300006');
    final scrollable = find
        .descendant(
          of: find.byKey(const ValueKey('stop-list-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('stop-TV-300006')),
      120,
      scrollable: scrollable,
      maxScrolls: 12,
    );
    await tapFormalControl(tester, 'stop-TV-300006');
    expect(model.detailContext!.origin, DetailOrigin.list);
    await tapFormalControl(tester, 'detail-close');
    await tapFormalControl(tester, 'close-list');
    expect(model.panel, WorkbenchPanel.map);
    expect(model.query.search, 'TV-300006');
    expect(tester.takeException(), isNull);
    await unmountFormalApp(tester, model);
    await awaitFormalIO(tester, fixture.dispose);
  });

  testWidgets('normal overview keeps its summary and Browse in one card', (
    tester,
  ) async {
    mapTestSize(tester);
    final (fixture, model, _) = await _mount(tester);
    expect(find.byKey(const ValueKey('overview-summary')), findsNothing);
    final card = tester.getRect(
      find.byKey(const ValueKey('delivery-overview')),
    );
    final browse = tester.getRect(find.byKey(const ValueKey('browse-stops')));
    final nearest = tester.getRect(find.byKey(const ValueKey('nearest-stop')));
    expect(card.contains(browse.topLeft), isTrue);
    expect(card.contains(browse.bottomRight), isTrue);
    expect(card.contains(nearest.topLeft), isTrue);
    expect(card.contains(nearest.bottomRight), isTrue);
    expect(browse.bottom, lessThan(nearest.top));
    _expectEntryExposed(tester);
    await tapFormalControl(tester, 'browse-stops');
    expect(model.panel, WorkbenchPanel.list);
    await tapFormalControl(tester, 'close-list');
    expect(model.panel, WorkbenchPanel.map);
    expect(find.byKey(const ValueKey('overview-summary')), findsNothing);
    _expectEntryExposed(tester);
    expect(tester.takeException(), isNull);
    await unmountFormalApp(tester, model);
    await awaitFormalIO(tester, fixture.dispose);
  });
}

void _expectFullyWithin(WidgetTester tester, Finder target, Finder container) {
  final bounds = tester.getRect(target);
  final area = tester.getRect(container);
  expect(area.contains(bounds.topLeft), isTrue, reason: '$bounds inside $area');
  expect(
    area.contains(bounds.bottomRight),
    isTrue,
    reason: '$bounds inside $area',
  );
  expect(target.hitTestable(), findsOneWidget);
}

void _expectListActionsExposed(WidgetTester tester) {
  final panel = find.byKey(const ValueKey('list-workspace'));
  final map = find.byKey(const ValueKey('delivery-map'));
  final footer = tester.getRect(find.byKey(const ValueKey('map-attribution')));
  final feedback = tester.getRect(
    find.byKey(const ValueKey('list-feedback-viewport')),
  );
  for (final key in ['list-sync', 'close-list']) {
    final action = find.byKey(ValueKey(key));
    _expectFullyWithin(tester, action, panel);
    _expectFullyWithin(tester, action, map);
    expect(tester.getSize(action).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
    expect(tester.getRect(action).overlaps(footer), isFalse);
    expect(tester.getRect(action).overlaps(feedback), isFalse);
  }
}

Future<(FormalWorkbenchFixture, DeliveryViewModel, DeliveryMapController)>
_mount(WidgetTester tester) async {
  // Widget tests otherwise render the missing font with Ahem square glyphs.
  // Use the same approved typography as the native App for this geometry case.
  await completeFixtureIO(
    tester,
    () async {
      final font = FontLoader('Inter')
        ..addFont(rootBundle.load('assets/InterVariable.ttf'));
      await font.load();
    },
    description: 'approved Inter asset must load before overview measurement',
  );
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
  final map = fixtureController(tester);
  await mountFormalApp(
    tester,
    model: model,
    provider: provider,
    controller: map,
  );
  await waitForFixtureMap(tester, map);
  return (fixture, model, map);
}

void _expectEntryExposed(WidgetTester tester) {
  final browse = find.byKey(const ValueKey('browse-stops'));
  final bounds = tester.getRect(browse);
  final map = tester.getRect(find.byKey(const ValueKey('delivery-map')));
  final footer = tester.getRect(find.byKey(const ValueKey('map-attribution')));
  expect(browse.hitTestable(), findsOneWidget, reason: '$bounds inside $map');
  expect(tester.getSize(browse).width, greaterThanOrEqualTo(44));
  expect(tester.getSize(browse).height, greaterThanOrEqualTo(44));
  expect(map.contains(bounds.topLeft), isTrue);
  expect(map.contains(bounds.bottomRight), isTrue);
  expect(bounds.overlaps(footer), isFalse);
  expect(footer.bottom, lessThanOrEqualTo(844));
  for (final key in [
    'zoom-in',
    'zoom-out',
    'fit-stops',
    'locate-reference',
    'map-sync',
  ]) {
    final tool = find.byKey(ValueKey(key));
    expect(tool.hitTestable(), findsOneWidget, reason: key);
    expect(bounds.overlaps(tester.getRect(tool)), isFalse, reason: key);
  }
}

void _expectMatchExposed(WidgetTester tester) {
  final marker = find.byKey(const ValueKey('map-stop-TV-300002'));
  final bounds = tester.getRect(marker);
  final map = tester.getRect(find.byKey(const ValueKey('delivery-map')));
  expect(marker.hitTestable(), findsOneWidget, reason: '$bounds inside $map');
  expect(tester.getSize(marker), const Size(44, 44));
  expect(map.contains(bounds.topLeft), isTrue);
  expect(map.contains(bounds.bottomRight), isTrue);
  for (final key in [
    'delivery-overview',
    'zoom-in',
    'zoom-out',
    'fit-stops',
    'locate-reference',
    'map-sync',
    'map-attribution',
  ]) {
    expect(
      bounds.overlaps(tester.getRect(find.byKey(ValueKey(key)))),
      isFalse,
      reason: 'Matching marker hidden by $key',
    );
  }
}
