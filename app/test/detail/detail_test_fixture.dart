import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/delivery/delivery_repository.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/core/brand_theme.dart';
import 'package:ocean_delivery/ui/delivery/detail/delivery_detail_card.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';

Stop detailStop({
  DeliveryStatus status = DeliveryStatus.pending,
  String? reason,
  String? note,
  String? timeWindow = '08:00-10:00',
  DateTime? recordedAt,
  DateTime? acknowledgedAt,
}) => Stop(
  id: 'detail-stop',
  reference: 'TV-300002',
  customerName: 'Silverline Supplies',
  address: '215 Pitt St, Newtown NSW',
  latitude: -33.909712,
  longitude: 151.162838,
  status: status,
  reason: reason,
  note: note,
  timeWindow: timeWindow,
  recordedAt: recordedAt,
  acknowledgedAt: acknowledgedAt,
);

class DetailRepositoryFixture implements DeliveryRepository {
  DetailRepositoryFixture({Stop? stop}) : stop = stop ?? detailStop();

  Stop stop;
  final queue = <PendingUpdate>[];
  int submitCalls = 0;
  int closeCalls = 0;
  Completer<void>? saveGate;
  bool failSubmit = false;
  bool failRefreshAfterSave = false;
  bool _saved = false;

  DeliveryViewModel createModel() => DeliveryViewModel(
    repository: this,
    syncCoordinator: SyncCoordinator(repository: this),
  );

  @override
  Future<void> initialize() async {}

  @override
  Future<List<Stop>> loadStops() async {
    if (_saved && failRefreshAfterSave) {
      throw StateError('Controlled snapshot read failure');
    }
    return [stop];
  }

  @override
  Future<List<PendingUpdate>> pendingUpdates() async => List.of(queue);

  @override
  Future<void> submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
    String? note,
  }) async {
    submitCalls++;
    await saveGate?.future;
    if (failSubmit) throw StateError('Controlled write failure');
    if (stopId != stop.id || stop.status != DeliveryStatus.pending) {
      throw StateError('Terminal or missing stop');
    }
    final recordedAt = DateTime.utc(2026, 10, 10, 7, 8);
    final operationId = 'detail-operation-$submitCalls';
    stop = Stop(
      id: stop.id,
      reference: stop.reference,
      customerName: stop.customerName,
      address: stop.address,
      latitude: stop.latitude,
      longitude: stop.longitude,
      status: status,
      timeWindow: stop.timeWindow,
      reason: reason,
      note: note,
      recordedAt: recordedAt,
      operationId: operationId,
    );
    queue.add(
      PendingUpdate(
        seq: submitCalls,
        operationId: operationId,
        datasetId: 'detail-dataset',
        stopId: stopId,
        status: status,
        reason: reason,
        note: note,
        recordedAt: recordedAt,
      ),
    );
    _saved = true;
  }

  @override
  Future<bool> acknowledge(Ack ack) async => false;

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

Widget detailHost(
  DeliveryViewModel model, {
  double textScale = 1,
  double keyboardInset = 0,
}) => MaterialApp(
  theme: oceanTheme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: true,
      viewInsets: EdgeInsets.only(bottom: keyboardInset),
    ),
    child: child!,
  ),
  home: ListenableBuilder(
    listenable: model,
    builder: (context, _) => PopScope<void>(
      canPop: model.panel != WorkbenchPanel.detail,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) model.closeDetail();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) =>
                model.panel == WorkbenchPanel.detail
                ? Align(
                    alignment: Alignment.bottomCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * 0.8,
                      ),
                      child: DeliveryDetailCard(
                        viewModel: model,
                        onClose: model.closeDetail,
                      ),
                    ),
                  )
                : Center(
                    child: Text(
                      model.panel == WorkbenchPanel.list
                          ? 'List workspace'
                          : 'Map workspace',
                    ),
                  ),
          ),
        ),
      ),
    ),
  ),
);

Future<DeliveryViewModel> loadedDetail(
  DetailRepositoryFixture repository, {
  DetailOrigin origin = DetailOrigin.map,
}) async {
  final model = repository.createModel();
  await model.load();
  model.openDetail(repository.stop.id, origin: origin);
  return model;
}

Future<void> tapVisible(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> unmountDetail(WidgetTester tester, DeliveryViewModel model) async {
  await tester.pumpWidget(const SizedBox());
  await model.close();
}
