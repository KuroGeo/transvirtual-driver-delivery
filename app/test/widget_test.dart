import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/app/ocean_delivery_app.dart';
import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/delivery_view_model.dart';

import 'ui/fake_delivery_repository.dart';

Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 30),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 2),
);

Future<void> startApp(
  WidgetTester tester,
  FakeDeliveryRepository repository,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    OceanDeliveryApp(
      createViewModel: () async => DeliveryViewModel(
        repository: repository,
        syncCoordinator: SyncCoordinator(
          repository: repository,
          transport: const UnavailableTransport(),
        ),
      ),
    ),
  );
  await settle(tester);
}

void main() {
  testWidgets('loads all stops and states the local service boundary', (
    tester,
  ) async {
    final repository = FakeDeliveryRepository();
    await startApp(tester, repository);

    expect(find.text('30 站 · 29 待配送 · 0 待同步'), findsOneWidget);
    expect(find.text('本地客户端 · 服务待接入'), findsOneWidget);
    expect(find.text('Customer 1'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completion is local and unavailable sync retains its event', (
    tester,
  ) async {
    final repository = FakeDeliveryRepository();
    await startApp(tester, repository);
    await tester.tap(find.text('Customer 1'));
    await settle(tester);
    await tester.tap(find.text('标记已完成'));
    await settle(tester);

    expect(repository.stops.first.status, DeliveryStatus.completed);
    expect(repository.queue.length, 1);
    expect(find.text('已保存到本机，等待服务连接。'), findsOneWidget);
    expect(find.text('30 站 · 28 待配送 · 1 待同步'), findsOneWidget);
    await tester.tap(find.text('同步'));
    await settle(tester);
    expect(repository.queue.length, 1);
    expect(find.text('同步未完成。更新仍保存在本机，请稍后重试。'), findsOneWidget);
    expect(find.textContaining('已上传'), findsNothing);
  });

  testWidgets('failed save retains typed reason and retry persists it', (
    tester,
  ) async {
    final repository = FakeDeliveryRepository()..failSubmit = true;
    await startApp(tester, repository);
    await tester.tap(find.text('Customer 1'));
    await settle(tester);
    await tester.tap(find.text('记录配送失败'));
    await tester.pump();
    await tester.tap(find.text('保存配送失败'));
    await tester.pump();
    expect(find.text('请填写失败原因'), findsOneWidget);
    expect(repository.submitCalls, 0);

    const typedReason = '  收件人不在，请明天再送  ';
    await tester.enterText(
      find.byKey(const ValueKey('failure-reason')),
      typedReason,
    );
    await tester.tap(find.text('保存配送失败'));
    await settle(tester);
    expect(find.text('保存失败，请重试。输入内容已保留。'), findsOneWidget);
    expect(find.text(typedReason), findsOneWidget);
    expect(repository.stops.first.status, DeliveryStatus.pending);
    expect(repository.queue, isEmpty);

    repository.failSubmit = false;
    await tester.tap(find.text('保存配送失败'));
    await settle(tester);
    expect(repository.stops.first.status, DeliveryStatus.failed);
    expect(repository.stops.first.reason, '收件人不在，请明天再送');
    expect(repository.queue.single.reason, '收件人不在，请明天再送');
    await tester.tap(find.text('Customer 1'));
    await settle(tester);
    expect(find.text('失败原因：收件人不在，请明天再送'), findsOneWidget);
    expect(find.text('标记已完成'), findsNothing);
  });

  testWidgets(
    'completion save error keeps the stop pending and permits retry',
    (tester) async {
      final repository = FakeDeliveryRepository()..failSubmit = true;
      await startApp(tester, repository);
      await tester.tap(find.text('Customer 1'));
      await settle(tester);
      await tester.tap(find.text('标记已完成'));
      await settle(tester);
      expect(find.text('保存失败，请重试。输入内容已保留。'), findsOneWidget);
      expect(repository.stops.first.status, DeliveryStatus.pending);
      expect(repository.queue, isEmpty);

      repository.failSubmit = false;
      await tester.tap(find.text('标记已完成'));
      await settle(tester);
      expect(repository.stops.first.status, DeliveryStatus.completed);
      expect(repository.queue.length, 1);
    },
  );

  testWidgets('initial repository error is retryable', (tester) async {
    final repository = FakeDeliveryRepository()..failInitialization = true;
    await startApp(tester, repository);
    expect(find.text('配送数据无法加载，请重试。'), findsOneWidget);
    expect(find.text('Customer 1'), findsNothing);
    repository.failInitialization = false;
    await tester.tap(find.text('重试加载'));
    await settle(tester);
    expect(find.text('Customer 1'), findsOneWidget);
    expect(find.text('配送数据无法加载，请重试。'), findsNothing);
  });

  testWidgets(
    'database bootstrap error can reopen through its injected factory',
    (tester) async {
      final repository = FakeDeliveryRepository();
      var attempts = 0;
      await tester.pumpWidget(
        OceanDeliveryApp(
          createViewModel: () async {
            attempts += 1;
            if (attempts == 1) throw StateError('fixture cannot open database');
            return DeliveryViewModel(
              repository: repository,
              syncCoordinator: SyncCoordinator(repository: repository),
            );
          },
        ),
      );
      await settle(tester);
      expect(find.text('本地数据库无法打开，请重试。'), findsOneWidget);
      await tester.tap(find.text('重试打开'));
      await settle(tester);
      expect(find.text('Customer 1'), findsOneWidget);
      expect(attempts, 2);
    },
  );

  testWidgets(
    'persisted save is distinguished from subsequent refresh failure',
    (tester) async {
      final repository = FakeDeliveryRepository()..failRefreshAfterSave = true;
      await startApp(tester, repository);
      await tester.tap(find.text('Customer 1'));
      await settle(tester);
      await tester.tap(find.text('标记已完成'));
      await settle(tester);
      expect(repository.stops.first.status, DeliveryStatus.completed);
      expect(repository.queue.length, 1);
      expect(find.text('记录已保存，但列表刷新失败，请重试加载。'), findsOneWidget);
      expect(find.text('保存失败，请重试。输入内容已保留。'), findsNothing);
      repository.failRefreshAfterSave = false;
      await tester.tap(find.text('重试加载'));
      await settle(tester);
      expect(find.text('30 站 · 28 待配送 · 1 待同步'), findsOneWidget);
      expect(repository.submitCalls, 1);
    },
  );

  testWidgets('failure form scrolls above the keyboard without overflow', (
    tester,
  ) async {
    final repository = FakeDeliveryRepository();
    await startApp(tester, repository);
    await tester.tap(find.text('Customer 1'));
    await settle(tester);
    await tester.tap(find.text('记录配送失败'));
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.enterText(
      find.byKey(const ValueKey('failure-reason')),
      '无人接收',
    );
    await tester.ensureVisible(find.text('保存配送失败'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('保存配送失败'));
    await settle(tester);
    expect(repository.stops.first.reason, '无人接收');
  });
}
