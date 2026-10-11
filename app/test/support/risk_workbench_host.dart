import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:ocean_delivery/models/workbench.dart';
import 'package:ocean_delivery/ui/core/brand_theme.dart';
import 'package:ocean_delivery/ui/delivery/detail/delivery_detail_card.dart';
import 'package:ocean_delivery/ui/delivery/list/stop_list_workspace.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';

/// Independent component composition, not the formal application/main entry.
/// Its results cannot sign OS back, native keyboard or startup acceptance.
class RiskWorkbenchHost extends StatelessWidget {
  const RiskWorkbenchHost({
    super.key,
    required this.model,
    this.mapController,
    this.tileProvider,
    this.viewport,
    this.tileCacheClearer,
  });

  final DeliveryViewModel model;
  final DeliveryMapController? mapController;
  final TileProvider? tileProvider;
  final MapViewport? viewport;
  final Future<void> Function()? tileCacheClearer;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: oceanTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => ListenableBuilder(
            listenable: model,
            builder: (context, _) => Stack(
              children: [
                if (mapController != null)
                  Positioned.fill(
                    child: DeliveryMapWorkspace(
                      result: model.result,
                      datasetId: viewport!.datasetId,
                      initialViewport: viewport,
                      controller: mapController,
                      tileProvider: tileProvider,
                      tileUrlTemplate:
                          'http://127.0.0.1/independent/{z}/{x}/{y}.png',
                      toolbarTop: 120,
                      fitPadding: const EdgeInsets.all(30),
                      selectedStopId: model.selectedStop?.id,
                      tileCacheClearer: tileCacheClearer ?? () async {},
                      onOpenStop: (stop, origin) =>
                          model.openDetail(stop.id, origin: origin),
                    ),
                  ),
                if (model.panel == WorkbenchPanel.list)
                  Positioned.fill(
                    child: StopListWorkspace(
                      viewModel: model,
                      onOpenStop: (stop) =>
                          model.openDetail(stop.id, origin: DetailOrigin.list),
                      onClose: model.closeList,
                    ),
                  ),
                if (model.panel == WorkbenchPanel.detail)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * 0.78,
                      ),
                      child: DeliveryDetailCard(
                        viewModel: model,
                        onClose: model.closeDetail,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> tapRiskControl(WidgetTester tester, String key) async {
  if (key == 'stop-search' ||
      key == 'waiting-only' ||
      key.startsWith('filter-')) {
    final toggle = find.byKey(const ValueKey('list-query-controls'));
    if (toggle.evaluate().isNotEmpty &&
        tester.widget<IconButton>(toggle).isSelected != true) {
      await tapRiskControl(tester, 'list-query-controls');
    }
  }
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Completer and actual UI tap run in the same real zone as the file database.
/// Bounded by a state transition, never by a random sleep or skipped submit.
Future<void> tapRiskSave(
  WidgetTester tester,
  DeliveryViewModel model,
  String key,
) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  final completed = await tester.runAsync(() async {
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
      })().timeout(const Duration(seconds: 5));
      return true;
    } finally {
      model.removeListener(observe);
    }
  });
  expect(completed, isTrue);
  await tester.pumpAndSettle();
}
