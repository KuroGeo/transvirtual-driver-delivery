import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/delivery/delivery_repository.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/core/brand_theme.dart';
import 'package:ocean_delivery/ui/delivery/list/stop_list_workspace.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';

// Independent review fixture: navigation uses the real VM and list component.
// No navigation animation or tap ripple can supply an incidental restore frame.
class _ReviewRepository implements DeliveryRepository {
  _ReviewRepository(int count)
    : _stops = List.generate(count, (index) {
        final reference = 'REVIEW-${(index + 1).toString().padLeft(2, '0')}';
        return Stop(
          id: 'id-$reference',
          reference: reference,
          customerName: 'Review customer $index',
          address: 'Review address $index',
          latitude: TestReference.latitude,
          longitude: TestReference.longitude,
          status: DeliveryStatus.pending,
        );
      });

  final List<Stop> _stops;
  final List<PendingUpdate> _queue = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<List<Stop>> loadStops() async => List.of(_stops);

  @override
  Future<List<PendingUpdate>> pendingUpdates() async => List.of(_queue);

  @override
  Future<void> submit(
    String stopId,
    DeliveryStatus status, {
    String? reason,
    String? note,
  }) async {
    final index = _stops.indexWhere((stop) => stop.id == stopId);
    final stop = _stops[index];
    if (stop.status != DeliveryStatus.pending) {
      throw StateError('Already terminal');
    }
    _stops[index] = Stop(
      id: stop.id,
      reference: stop.reference,
      customerName: stop.customerName,
      address: stop.address,
      latitude: stop.latitude,
      longitude: stop.longitude,
      status: status,
      reason: reason,
      note: note,
    );
    _queue.add(
      PendingUpdate(
        seq: 1,
        operationId: 'review-operation',
        datasetId: 'review-dataset',
        stopId: stopId,
        status: status,
        reason: reason,
        note: note,
      ),
    );
  }

  @override
  Future<bool> acknowledge(Ack ack) async => false;

  @override
  Future<void> close() async {}
}

Widget _host(DeliveryViewModel model) => MaterialApp(
  theme: oceanTheme().copyWith(
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
  ),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: true, accessibleNavigation: true),
      child: Scaffold(
        body: ListenableBuilder(
          listenable: model,
          builder: (context, _) => model.panel == WorkbenchPanel.list
              ? StopListWorkspace(
                  viewModel: model,
                  onOpenStop: (stop) =>
                      model.openDetail(stop.id, origin: DetailOrigin.list),
                  onClose: model.closeList,
                )
              : const Text('Review detail'),
        ),
      ),
    ),
  ),
);

class _ReviewIOValue<T> {
  const _ReviewIOValue(this.value);
  final T value;
}

Future<T> _reviewIO<T>(
  WidgetTester tester,
  Future<T> Function() action, {
  required String description,
}) async {
  final result = await tester.runAsync(
    () async => _ReviewIOValue(
      await action().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException(description),
      ),
    ),
  );
  expect(result, isNotNull, reason: description);
  return result!.value;
}

Future<DeliveryViewModel> _model(WidgetTester tester, int count) async {
  final model = await _reviewIO(tester, () async {
    // Preload the approved glyphs before mounting the real list in FakeAsync.
    // This supplies no navigation or restoration frames and replaces no icon.
    final paths = Map<String, String>.from(
      jsonDecode(await rootBundle.loadString('assets/icons.json')) as Map,
    );
    for (final source in paths.values) {
      final picture = await vg.loadPicture(SvgStringLoader(source), null);
      picture.picture.dispose();
    }
    final repository = _ReviewRepository(count);
    return DeliveryViewModel(
      repository: repository,
      syncCoordinator: SyncCoordinator(repository: repository),
    );
  }, description: 'held-out fixture and approved glyph setup must finish');
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _reviewIO(
      tester,
      model.close,
      description: 'held-out model and repository must close',
    );
  });
  await _reviewIO(
    tester,
    model.load,
    description: 'held-out model initial load must finish',
  );
  model.openList();
  return model;
}

void main() {
  testWidgets(
    'system-style return restores lazy row focus without extra pumps',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = await _model(tester, 30);
      await tester.pumpWidget(_host(model));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('stop-REVIEW-18')),
        450,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('stop-list-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const ValueKey('stop-REVIEW-18')));
      await tester.pumpAndSettle();
      final offset = model.detailContext!.listSession!.scrollOffset;
      expect(offset, greaterThan(500));
      expect(model.panel, WorkbenchPanel.detail);

      // Direct VM close models OS/system return, with no Back-button ink ticker.
      model.closeDetail();
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<CustomScrollView>(
            find.byKey(const ValueKey('stop-list-scroll')),
          )
          .controller!;
      expect(scroll.offset, closeTo(offset, 0.1));
      final ink = tester.widget<InkWell>(
        find.descendant(
          of: find.byKey(const ValueKey('stop-REVIEW-18')),
          matching: find.byType(InkWell),
        ),
      );
      expect(ink.focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('filtered return restores close focus without animation frames', (
    tester,
  ) async {
    final model = await _model(tester, 1);
    model.setStatus(DeliveryStatus.pending);
    await tester.pumpWidget(_host(model));
    await tester.tap(find.byKey(const ValueKey('stop-REVIEW-01')));
    await tester.pumpAndSettle();
    expect(
      await _reviewIO(
        tester,
        () => model.submit('id-REVIEW-01', DeliveryStatus.completed),
        description: 'held-out filtered-return completion must commit',
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(model.selectedStop?.status, DeliveryStatus.completed);
    expect(model.result.matchedCount, 0);

    model.closeDetail();
    await tester.pumpAndSettle();
    expect(find.text('No matching stops'), findsOneWidget);
    final close = tester.widget<IconButton>(
      find.byKey(const ValueKey('close-list')),
    );
    expect(close.focusNode!.hasFocus, isTrue);
    expect(model.query.status, DeliveryStatus.pending);
    expect(tester.takeException(), isNull);
  });
}
