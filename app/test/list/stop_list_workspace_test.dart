import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/core/brand_theme.dart';
import 'package:ocean_delivery/ui/delivery/list/stop_list_workspace.dart';
import 'package:ocean_delivery/ui/delivery/list/stop_status_badge.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';

import '../query/query_repository_fixture.dart';

Widget listHost(DeliveryViewModel model, {double textScale = 1}) => MaterialApp(
  theme: oceanTheme(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: model,
          builder: (context, _) => model.panel == WorkbenchPanel.list
              ? StopListWorkspace(
                  viewModel: model,
                  onOpenStop: (stop) =>
                      model.openDetail(stop.id, origin: DetailOrigin.list),
                  onClose: model.closeList,
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
      await tester.pumpWidget(listHost(model));
      expect(find.byKey(const ValueKey('list-workspace')), findsOneWidget);
      expect(find.byKey(const ValueKey('stop-REF-01')), findsOneWidget);
      expect(find.text('Harbour Foods'), findsOneWidget);
      expect(find.text('10 Ocean Street, Sydney NSW'), findsOneWidget);
      expect(find.text('08:00–10:00'), findsOneWidget);
      expect(find.text('Waiting to sync'), findsOneWidget);
      expect(
        find.text('1 matching stops · 2 waiting in total'),
        findsOneWidget,
      );
      expect(
        find.text('Nearest first · straight-line from test reference'),
        findsOneWidget,
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
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await closeHost(tester, model);
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
      await tester.tap(find.byKey(const ValueKey('close-list')));
      await tester.pump();
      expect(find.text('Map workspace'), findsOneWidget);
      expect(model.panel, WorkbenchPanel.map);
      await closeHost(tester, model);
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
