import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/core/brand_icon.dart';
import 'package:ocean_delivery/ui/core/brand_theme.dart';
import 'package:ocean_delivery/ui/delivery/list/stop_list_workspace.dart';
import 'package:ocean_delivery/ui/delivery/list/stop_status_badge.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';

import '../query/query_repository_fixture.dart';

Widget listHost(
  DeliveryViewModel model, {
  double textScale = 1,
  VoidCallback? onSync,
  double? panelHeight,
  EdgeInsets safePadding = EdgeInsets.zero,
}) => MaterialApp(
  theme: oceanTheme(),
  home: MediaQuery(
    data: MediaQueryData(
      textScaler: TextScaler.linear(textScale),
      padding: safePadding,
    ),
    child: Scaffold(
      body: SafeArea(
        child: SizedBox(
          height: panelHeight,
          child: ListenableBuilder(
            listenable: model,
            builder: (context, _) => model.panel == WorkbenchPanel.list
                ? StopListWorkspace(
                    viewModel: model,
                    onOpenStop: (stop) =>
                        model.openDetail(stop.id, origin: DetailOrigin.list),
                    onClose: model.closeList,
                    onSync: onSync,
                  )
                : model.panel == WorkbenchPanel.detail
                ? Column(
                    children: [
                      Text('Detail ${model.selectedStop?.reference}'),
                      TextButton(
                        onPressed: model.closeDetail,
                        child: const Text('Back to stops'),
                      ),
                    ],
                  )
                : const Text('Map workspace'),
          ),
        ),
      ),
    ),
  ),
);

Future<DeliveryViewModel> loadList(QueryRepositoryFixture repository) async {
  final model = repository.createModel();
  await model.load();
  model.openList();
  return model;
}

Future<void> closeHost(WidgetTester tester, DeliveryViewModel model) async {
  await tester.pumpWidget(const SizedBox());
  await model.close();
}

void main() {
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  testWidgets(
    'list shows identity, window, status and separate global queue count',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = await loadList(
        QueryRepositoryFixture(
          stops: [
            queryStop(
              'REF-01',
              customer: 'Harbour Foods',
              status: DeliveryStatus.failed,
            ),
          ],
          queue: [queryUpdate('REF-01'), queryUpdate('outside-query', seq: 2)],
        ),
      );
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(listHost(model));
        expect(find.byKey(const ValueKey('list-workspace')), findsOneWidget);
        expect(find.byKey(const ValueKey('stop-REF-01')), findsOneWidget);
        expect(find.text('Stops on the map'), findsOneWidget);
        expect(find.text('1 stop · Nearest first'), findsOneWidget);
        expect(find.byKey(const ValueKey('list-grip')), findsOneWidget);
        expect(find.byKey(const ValueKey('stop-search')), findsNothing);
        expect(find.byKey(const ValueKey('waiting-only')), findsNothing);
        expect(find.text('REF-01'), findsNothing);
        expect(find.text('Harbour Foods'), findsOneWidget);
        expect(find.text('10 Ocean Street, Sydney NSW'), findsOneWidget);
        expect(find.text('08:00–10:00'), findsOneWidget);
        expect(find.text('Waiting to sync'), findsOneWidget);
        final row = find.byKey(const ValueKey('stop-REF-01'));
        expect(tester.getSize(row).height, greaterThanOrEqualTo(112));
        expect(
          tester.getSize(
            find.byKey(const ValueKey('list-status-symbol-REF-01')),
          ),
          const Size(30, 30),
        );
        final customer = tester.getRect(find.text('Harbour Foods'));
        final address = tester.getRect(
          find.text('10 Ocean Street, Sydney NSW'),
        );
        final distance = tester.getRect(find.text('0 m'));
        final window = tester.getRect(find.text('08:00–10:00'));
        final status = tester.getRect(find.text('Failed'));
        expect(customer.top, lessThan(address.top));
        expect(address.bottom, lessThanOrEqualTo(distance.top));
        expect(
          distance.top < window.top || distance.left < window.left,
          isTrue,
          reason: 'Distance precedes the delivery window in reading order',
        );
        expect(
          window.top < status.top || window.left < status.left,
          isTrue,
          reason: 'Outcome follows distance and delivery window',
        );
        final rowIcons = tester.widgetList<BrandIcon>(
          find.descendant(of: row, matching: find.byType(BrandIcon)),
        );
        expect(rowIcons.map((icon) => icon.name), ['warning', 'arrow']);
        expect(rowIcons.last.size, 14);
        expect(
          tester
              .widget<StopStatusBadge>(find.byType(StopStatusBadge))
              .showSymbol,
          isFalse,
          reason: 'The leading outcome symbol is not repeated in metadata',
        );
        expect(
          find.text('1 matching stops · 2 waiting in total'),
          findsNothing,
        );
        expect(
          find.text('Nearest first · straight-line from test reference'),
          findsNothing,
        );
        final rowSemantics = tester
            .getSemantics(find.byType(StopStatusBadge))
            .getSemanticsData();
        for (final label in [
          'REF-01',
          'Harbour Foods',
          '10 Ocean Street, Sydney NSW',
          'Status: Failed',
          'Delivery window 08:00-10:00',
          'Waiting to sync',
        ]) {
          expect(rowSemantics.label, contains(label));
        }
        expect(rowSemantics.hasAction(SemanticsAction.tap), isTrue);
        expect(rowSemantics.hasAction(SemanticsAction.focus), isTrue);
        await tester.tap(find.byKey(const ValueKey('list-query-controls')));
        await tester.pump();
        expect(find.byKey(const ValueKey('stop-search')), findsOneWidget);
        expect(
          find.text('1 matching stops · 2 waiting in total'),
          findsOneWidget,
        );
        expect(
          find.text('Nearest first · straight-line from test reference'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await closeHost(tester, model);
      }
    },
  );

  testWidgets(
    'list sync joins an active run without opening or changing list context',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final update = queryUpdate('REF-01');
      final repository = QueryRepositoryFixture(
        stops: [queryStop('REF-01', status: DeliveryStatus.completed)],
        queue: [update],
      );
      final response = Completer<Ack>();
      var sends = 0;
      final model = DeliveryViewModel(
        repository: repository,
        syncCoordinator: SyncCoordinator(
          repository: repository,
          transport: FakeSyncTransport(
            onSend: (_) {
              sends++;
              return response.future;
            },
          ),
        ),
      );
      final ack = Ack(
        operationId: update.operationId,
        datasetId: update.datasetId,
        stopId: update.stopId,
      );
      try {
        await model.load();
        model.openList();
        model.setSearch('REF-01');
        var syncCalls = 0;
        final runs = <Future<void>>[];
        await tester.pumpWidget(
          listHost(
            model,
            textScale: 2,
            onSync: () {
              syncCalls++;
              runs.add(model.sync());
            },
          ),
        );
        final button = find.byKey(const ValueKey('list-sync'));
        expect(tester.getSize(button), const Size(44, 44));
        await tester.tap(button);
        await tester.pump();
        expect(model.isSyncing, isTrue);
        expect(
          tester.widget<SyncActionIcon>(find.byType(SyncActionIcon)).syncing,
          isTrue,
        );
        await tester.tap(button);
        await tester.pump(const Duration(milliseconds: 100));
        expect(syncCalls, 2);
        expect(sends, 1, reason: 'the second action joins the existing sender');
        expect(model.panel, WorkbenchPanel.list);
        expect(model.query.search, 'REF-01');
        expect(
          model.queueCount,
          1,
          reason: 'busy progress is not acknowledgement',
        );
        expect(find.byKey(const ValueKey('stop-REF-01')), findsOneWidget);
        expect(tester.takeException(), isNull);
        response.complete(ack);
        await Future.wait(runs);
        await tester.pump();
        expect(model.queueCount, 0);
        expect(model.isSyncing, isFalse);
        expect(model.panel, WorkbenchPanel.list);
        expect(model.query.search, 'REF-01');
        expect(tester.takeException(), isNull);
      } finally {
        if (!response.isCompleted) response.complete(ack);
        await closeHost(tester, model);
      }
    },
  );

  testWidgets(
    'search and status intersect with Waiting and clear empty state',
    (tester) async {
      final model = await loadList(
        QueryRepositoryFixture(
          stops: [
            queryStop('REF-01', customer: 'Harbour Foods'),
            queryStop(
              'REF-02',
              customer: 'Harbour Shop',
              status: DeliveryStatus.completed,
            ),
          ],
          queue: [queryUpdate('REF-02')],
        ),
      );
      await tester.pumpWidget(listHost(model));
      await tester.tap(find.byKey(const ValueKey('list-query-controls')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('stop-search')),
        'HARBOUR',
      );
      await tester.tap(find.byKey(const ValueKey('filter-completed')));
      await tester.tap(find.byKey(const ValueKey('waiting-only')));
      await tester.pump();
      expect(model.result.stops.single.reference, 'REF-02');
      expect(find.byKey(const ValueKey('stop-REF-02')), findsOneWidget);
      expect(find.byKey(const ValueKey('stop-REF-01')), findsNothing);
      final retainedQuery = model.query;
      await tester.tap(find.byKey(const ValueKey('list-query-controls')));
      await tester.pump();
      expect(find.byKey(const ValueKey('stop-search')), findsNothing);
      expect(find.text('1 stop · Nearest first'), findsOneWidget);
      expect(model.query, retainedQuery);
      await tester.tap(find.byKey(const ValueKey('list-query-controls')));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('stop-search')))
            .controller
            ?.text,
        'HARBOUR',
      );
      expect(model.query, retainedQuery);
      await tester.enterText(
        find.byKey(const ValueKey('stop-search')),
        'missing',
      );
      await tester.pump();
      expect(model.result.nearest, isNull);
      expect(find.text('No matching stops'), findsOneWidget);
      await tester.ensureVisible(find.text('Clear search and filters'));
      await tester.tap(find.text('Clear search and filters'));
      await tester.pump();
      expect(model.query, const WorkbenchQuery());
      expect(model.result.matchedCount, 2);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('stop-search')))
            .controller
            ?.text,
        '',
      );
      expect(tester.takeException(), isNull);
      await closeHost(tester, model);
    },
  );

  testWidgets(
    'list origin restores actual scroll offset and row focus on remount',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = await loadList(
        QueryRepositoryFixture(
          stops: List.generate(
            30,
            (index) =>
                queryStop('REF-${(index + 1).toString().padLeft(2, '0')}'),
          ),
        ),
      );
      model.setSearch('Ocean');
      await tester.pumpWidget(listHost(model));
      final targetRow = find.byKey(const ValueKey('stop-REF-18'));
      await tester.scrollUntilVisible(
        targetRow,
        450,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('stop-list-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await Scrollable.ensureVisible(tester.element(targetRow), alignment: 0.5);
      await tester.pump();
      expect(targetRow.hitTestable(), findsOneWidget);
      await tester.tap(targetRow.hitTestable());
      await tester.pump();
      expect(model.detailContext, isNotNull);
      final offset = model.detailContext!.listSession!.scrollOffset;
      expect(offset, greaterThan(500));
      expect(find.text('Detail REF-18'), findsOneWidget);
      await tester.tap(find.text('Back to stops'));
      await tester.pump();
      await tester.pump();
      final scroll = tester
          .widget<CustomScrollView>(
            find.byKey(const ValueKey('stop-list-scroll')),
          )
          .controller!;
      expect(scroll.offset, closeTo(offset, 0.1));
      final row = find.byKey(const ValueKey('stop-REF-18'));
      final ink = tester.widget<InkWell>(
        find.descendant(of: row, matching: find.byType(InkWell)),
      );
      expect(ink.focusNode!.hasFocus, isTrue);
      expect(model.query.search, 'Ocean');
      expect(find.byKey(const ValueKey('stop-search')), findsNothing);
      expect(tester.takeException(), isNull);
      await closeHost(tester, model);
    },
  );

  testWidgets('saved filtered row returns to list with close focus fallback', (
    tester,
  ) async {
    final model = await loadList(QueryRepositoryFixture());
    model.setStatus(DeliveryStatus.pending);
    await tester.pumpWidget(listHost(model));
    await tester.tap(find.byKey(const ValueKey('stop-REF-01')));
    await tester.pump();
    expect(await model.submit('id-REF-01', DeliveryStatus.completed), isTrue);
    await tester.pump();
    expect(model.selectedStop?.status, DeliveryStatus.completed);
    expect(find.text('Detail REF-01'), findsOneWidget);
    await tester.tap(find.text('Back to stops'));
    await tester.pump();
    await tester.pump();
    expect(find.text('No matching stops'), findsOneWidget);
    final close = tester.widget<IconButton>(
      find.byKey(const ValueKey('close-list')),
    );
    expect(close.focusNode!.hasFocus, isTrue);
    expect(model.query.status, DeliveryStatus.pending);
    expect(tester.takeException(), isNull);
    await closeHost(tester, model);
  });

  testWidgets(
    'cold list does not request row or close focus and close returns map',
    (tester) async {
      final model = await loadList(QueryRepositoryFixture());
      await tester.pumpWidget(listHost(model));
      final close = tester.widget<IconButton>(
        find.byKey(const ValueKey('close-list')),
      );
      expect(close.focusNode!.hasFocus, isFalse);
      expect(find.byKey(const ValueKey('list-sync')), findsNothing);
      expect(find.byKey(const ValueKey('stop-search')), findsNothing);
      expect(
        find.byKey(const ValueKey('list-query-controls')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('close-list')));
      await tester.pump();
      expect(find.text('Map workspace'), findsOneWidget);
      expect(model.panel, WorkbenchPanel.map);
      await closeHost(tester, model);
    },
  );

  testWidgets(
    'full-height large text task preserves query, readable row and typed return',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = await loadList(
        QueryRepositoryFixture(
          stops: List.generate(
            30,
            (index) => queryStop(
              'REF-${(index + 1).toString().padLeft(2, '0')}',
              customer: 'Harbour Foods ${index + 1}',
            ),
          ),
        ),
      );
      try {
        await tester.pumpWidget(
          listHost(
            model,
            textScale: 53 / 17,
            panelHeight: 763,
            safePadding: const EdgeInsets.only(top: 47, bottom: 34),
            onSync: () {},
          ),
        );
        final panel = tester.getRect(
          find.byKey(const ValueKey('list-workspace')),
        );
        expect(panel.top, greaterThanOrEqualTo(47));
        expect(panel.bottom, lessThanOrEqualTo(810));
        for (final key in ['list-query-controls', 'list-sync', 'close-list']) {
          final control = find.byKey(ValueKey(key));
          expect(tester.getSize(control), const Size(44, 44));
          expect(control.hitTestable(), findsOneWidget);
        }
        expect(find.byKey(const ValueKey('stop-search')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('list-query-controls')));
        await tester.pump();
        final primary = find.byKey(const ValueKey('stop-list-scroll'));
        final tools = find.byKey(const ValueKey('list-query-scroll'));
        final toolsScrollable = find
            .descendant(of: tools, matching: find.byType(Scrollable))
            .first;
        expect(primary, findsNothing);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('stop-search')),
          160,
          scrollable: toolsScrollable,
          maxScrolls: 12,
        );
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const ValueKey('stop-search'))),
          alignment: 0.5,
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('stop-search')).hitTestable(),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const ValueKey('stop-search')),
          'REF-20',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('list-query-controls')));
        await tester.pump();
        expect(model.query.search, 'REF-20');
        expect(model.result.stops.single.reference, 'REF-20');
        final row = find.byKey(const ValueKey('stop-REF-20'));
        final customer = find.text('Harbour Foods 20');
        final viewport = tester.getRect(primary);
        expect(viewport.height, greaterThan(500));
        for (final key in [
          'list-customer-REF-20',
          'list-reference-REF-20',
          'list-status-REF-20',
        ]) {
          final bounds = tester.getRect(find.byKey(ValueKey(key)));
          expect(viewport.contains(bounds.topLeft), isTrue);
          expect(viewport.contains(bounds.bottomRight), isTrue);
        }
        expect(find.byTooltip('Search and filters'), findsOneWidget);
        expect(
          MediaQuery.textScalerOf(tester.element(customer)).scale(16) / 16,
          closeTo(53 / 17, 1e-12),
        );
        expect(customer.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(customer.hitTestable());
        await tester.pump();
        expect(model.detailContext?.origin, DetailOrigin.list);
        expect(model.selectedStop?.reference, 'REF-20');
        final offset = model.detailContext!.listSession!.scrollOffset;
        await tester.tap(find.text('Back to stops'));
        await tester.pump();
        await tester.pump();
        final scroll = tester.widget<CustomScrollView>(primary).controller!;
        expect(scroll.offset, closeTo(offset, 0.1));
        final ink = tester.widget<InkWell>(
          find.descendant(of: row, matching: find.byType(InkWell)),
        );
        expect(ink.focusNode!.hasFocus, isTrue);
        expect(model.query.search, 'REF-20');
        expect(find.byKey(const ValueKey('stop-search')), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await closeHost(tester, model);
      }
    },
  );

  testWidgets(
    '390px layout remains scrollable at 2x text and keyboard-sized height',
    (tester) async {
      tester.view.physicalSize = const Size(390, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = await loadList(
        QueryRepositoryFixture(
          stops: [
            queryStop(
              'REF-01',
              customer: 'Harbour Wholesale Distribution',
              timeWindow: null,
            ),
          ],
        ),
      );
      await tester.pumpWidget(listHost(model, textScale: 2));
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('stop-REF-01')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('stop-list-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Harbour Wholesale Distribution')),
        alignment: 0.5,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.text('Harbour Wholesale Distribution').hitTestable(),
        findsOneWidget,
      );
      expect(find.text('08:00–10:00'), findsNothing);
      await closeHost(tester, model);
    },
  );
}
