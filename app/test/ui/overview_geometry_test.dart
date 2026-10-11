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

      // Reproduce the short map area beneath the expanded/scaled header.
      // The old 69px overview viewport could not contain this >100px button.
      expect(
        tester.getSize(find.byKey(const ValueKey('delivery-map'))).height,
        lessThan(400),
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
    'max system text shows a readable stop and preserves query on detail return',
    (tester) async {
      mapTestSize(tester);
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
      tester.platformDispatcher.textScaleFactorTestValue = 53 / 17;
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final (fixture, model, _) = await _mount(tester);
      await tapFormalControl(tester, 'browse-stops');
      final primary = find.byKey(const ValueKey('stop-list-scroll'));
      expect(tester.getSize(primary).height, greaterThan(500));
      expect(find.byKey(const ValueKey('map-attribution')), findsNothing);
      final reference = model.result.stops.first.reference;
      _expectFullyWithin(
        tester,
        find.byKey(ValueKey('list-customer-$reference')),
        primary,
      );
      _expectFullyWithin(
        tester,
        find.byKey(ValueKey('list-reference-$reference')),
        primary,
      );
      _expectListActionsExposed(tester);
      await tapFormalControl(tester, 'list-query-controls');
      final search = find.byKey(const ValueKey('stop-search'));
      await revealFormalControl(tester, 'stop-search');
      await tester.enterText(search, 'TV-300004');
      await pumpFormalFrames(tester);
      await tapFormalControl(tester, 'list-query-controls');
      expect(model.query.search, 'TV-300004');
      final row = find.byKey(const ValueKey('stop-TV-300004'));
      expect(row.hitTestable(), findsOneWidget);
      _expectFullyWithin(
        tester,
        find.byKey(const ValueKey('list-customer-TV-300004')),
        primary,
      );
      _expectFullyWithin(
        tester,
        find.byKey(const ValueKey('list-reference-TV-300004')),
        primary,
      );
      expect(
        tester.getSize(row).height,
        lessThan(tester.getSize(primary).height),
      );
      final scrollable = find
          .descendant(of: primary, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      final offset = position.pixels;
      await tapFormalControl(tester, 'stop-TV-300004');
      expect(model.detailContext!.origin, DetailOrigin.list);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('delivery-detail-card')))
            .height,
        greaterThan(700),
      );
      await tapFormalControl(tester, 'detail-close');
      expect(model.panel, WorkbenchPanel.list);
      expect(model.query.search, 'TV-300004');
      expect(position.pixels, closeTo(offset, .1));
      _expectListActionsExposed(tester);
      await tapFormalControl(tester, 'close-list');
      expect(model.panel, WorkbenchPanel.map);
      expect(tester.takeException(), isNull);
      await unmountFormalApp(tester, model);
      await awaitFormalIO(tester, fixture.dispose);
    },
  );

  testWidgets(
    'maximum text task traversal never focuses hidden map or query controls',
    (tester) async {
      mapTestSize(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 53 / 17;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final (fixture, model, _) = await _mount(tester);
      await tapFormalControl(tester, 'open-search');
      await tapFormalControl(tester, 'browse-stops');
      for (final tools in [false, true, false]) {
        if (tools ||
            find
                .byKey(const ValueKey('list-query-scroll'))
                .evaluate()
                .isNotEmpty) {
          await tapFormalControl(tester, 'list-query-controls');
        }
        for (var step = 0; step < 12; step++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await pumpFormalFrames(tester);
          final focus = FocusManager.instance.primaryFocus?.context;
          var hidden = false;
          focus?.visitAncestorElements((element) {
            final widget = element.widget;
            if (widget is Offstage && widget.offstage) hidden = true;
            return true;
          });
          expect(
            hidden,
            isFalse,
            reason: 'Tab must only visit the displayed task.',
          );
        }
      }
      expect(tester.takeException(), isNull);
      await unmountFormalApp(tester, model);
      await awaitFormalIO(tester, fixture.dispose);
    },
  );

  testWidgets(
    'landscape status fit keeps the matching stop and Browse reachable',
    (tester) async {
      mapTestSize(tester);
      tester.view.physicalSize = const Size(844, 390);
      tester.view.padding = const FakeViewPadding(
        left: 47,
        right: 47,
        bottom: 21,
      );
      tester.view.viewPadding = const FakeViewPadding(
        left: 47,
        right: 47,
        bottom: 21,
      );
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final (fixture, model, map) = await _mount(tester);
      await tapFormalControl(tester, 'open-search');
      await tester.enterText(
        find.byKey(const ValueKey('map-search')),
        'TV-300002',
      );
      await pumpFormalFrames(tester);
      await tapFormalControl(tester, 'header-filter-pending');
      await waitForFixtureMap(tester, map);
      expect(model.result.stops.single.reference, 'TV-300002');
      expect(
        tester.getSize(find.byKey(const ValueKey('delivery-map'))).height,
        lessThan(200),
      );
      _expectMatchExposed(tester);
      _expectFullyWithin(
        tester,
        find.byKey(const ValueKey('browse-stops')),
        find.byKey(const ValueKey('delivery-map')),
      );
      await tapFormalControl(tester, 'browse-stops');
      expect(model.panel, WorkbenchPanel.list);
      await tapFormalControl(tester, 'close-list');
      expect(model.panel, WorkbenchPanel.map);
      expect(model.query.search, 'TV-300002');
      await waitForFixtureMap(tester, map);
      _expectMatchExposed(tester);
      expect(tester.takeException(), isNull);
      await unmountFormalApp(tester, model);
      await awaitFormalIO(tester, fixture.dispose);
    },
  );

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
  final task = find.byKey(const ValueKey('large-text-task-workspace'));
  final primary = tester.getRect(
    find.byKey(const ValueKey('stop-list-scroll')),
  );
  expect(find.byKey(const ValueKey('map-attribution')), findsNothing);
  for (final key in ['list-sync', 'close-list']) {
    final action = find.byKey(ValueKey(key));
    _expectFullyWithin(tester, action, panel);
    _expectFullyWithin(tester, action, task);
    expect(tester.getSize(action).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
    expect(tester.getRect(action).overlaps(primary), isFalse);
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
