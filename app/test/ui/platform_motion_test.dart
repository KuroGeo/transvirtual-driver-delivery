import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/models/delivery.dart';
import 'package:ocean_delivery/ui/core/brand_icon.dart';
import 'package:ocean_delivery/ui/delivery/failure/delivery_failure_sheet.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';

import '../../integration_test/support/native_workbench_bridge.dart';

const _stop = Stop(
  id: 'motion-stop',
  reference: 'MOTION-1',
  customerName: 'Motion fixture',
  address: '1 Test Street',
  latitude: -33.9,
  longitude: 151.1,
  status: DeliveryStatus.pending,
);

Widget _syncHost({bool syncing = true}) => MaterialApp(
  home: Scaffold(
    body: Center(child: SyncActionIcon(syncing: syncing)),
  ),
);

Animation<double> _turns(WidgetTester tester) => tester
    .widget<RotationTransition>(
      find.descendant(
        of: find.byType(SyncActionIcon),
        matching: find.byType(RotationTransition),
      ),
    )
    .turns;

void main() {
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  for (final (label, platform, reduced, disabled) in [
    ('iOS Reduce Motion', TargetPlatform.iOS, true, false),
    ('Android disable animations', TargetPlatform.android, false, true),
    ('normal motion', TargetPlatform.iOS, false, false),
  ]) {
    testWidgets('$label controls actual sync rotation', (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = platform;
      try {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(
              reduceMotion: reduced,
              disableAnimations: disabled,
            );
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pumpWidget(_syncHost());
        final context = tester.element(find.byType(SyncActionIcon));
        // The iOS engine flag must work without pretending that UIKit changed
        // the separate MediaQuery disableAnimations value.
        expect(MediaQuery.disableAnimationsOf(context), disabled);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 280));
        if (reduced || disabled) {
          expect(_turns(tester).value, 0);
          await tester.pump(const Duration(milliseconds: 500));
          expect(_turns(tester).value, 0);
        } else {
          expect(_turns(tester).value, greaterThan(0));
          expect(_turns(tester).value, lessThan(1));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    });

    testWidgets('$label controls the real failure-sheet transition', (
      tester,
    ) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = platform;
      try {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            FakeAccessibilityFeatures(
              reduceMotion: reduced,
              disableAnimations: disabled,
            );
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  key: const ValueKey('open-motion-sheet'),
                  onPressed: () => showDeliveryFailureSheet(
                    context,
                    stop: _stop,
                    onSubmit: ({required reason, note}) async => false,
                  ),
                  child: const Text('Report failure'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('open-motion-sheet')));
        await tester.pump();
        final sheet = find.byType(DeliveryFailureSheet);
        expect(sheet, findsOneWidget);
        final route = ModalRoute.of(tester.element(sheet))!;
        if (reduced || disabled) {
          expect(route.transitionDuration, Duration.zero);
          expect(route.reverseTransitionDuration, Duration.zero);
          expect(route.animation!.value, 1);
          expect(route.animation!.status, AnimationStatus.completed);
        } else {
          expect(route.transitionDuration, const Duration(milliseconds: 190));
          await tester.pump(const Duration(milliseconds: 40));
          expect(route.animation!.value, greaterThan(0));
          expect(route.animation!.value, lessThan(1));
          await tester.pump(const Duration(milliseconds: 200));
        }
        await tester.tap(find.byKey(const ValueKey('failure-close')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(sheet, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    });
  }

  testWidgets(
    'live platform motion changes stop and resume the same sync icon',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures();
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(_syncHost());
      final originalState = tester.state(find.byType(SyncActionIcon));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 280));
      expect(_turns(tester).value, greaterThan(0));

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 280));
      expect(_turns(tester).value, 0);
      expect(tester.state(find.byType(SyncActionIcon)), same(originalState));
      expect(
        MediaQuery.disableAnimationsOf(
          tester.element(find.byType(SyncActionIcon)),
        ),
        isFalse,
      );

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 280));
      expect(_turns(tester).value, greaterThan(0));
      expect(tester.state(find.byType(SyncActionIcon)), same(originalState));

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 280));
      expect(_turns(tester).value, 0);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 280));
      expect(_turns(tester).value, greaterThan(0));

      await tester.pumpWidget(_syncHost(syncing: false));
      await tester.pump(const Duration(milliseconds: 280));
      expect(_turns(tester).value, 0);
      await tester.pumpWidget(_syncHost());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 280));
      expect(_turns(tester).value, greaterThan(0));

      // An actual feature notification after unmount cannot reach a disposed
      // controller or keep the icon's observer alive.
      await tester.pumpWidget(const SizedBox.shrink());
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('readonly native snapshot reports both actual engine flags', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(reduceMotion: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final directory = Directory.systemTemp.createTempSync('ocean-motion-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final controller = DeliveryMapController();
    addTearDown(controller.dispose);
    final journal = NativeWorkbenchJournal(
      file: File('${directory.path}/$nativeJournalName'),
      candidate: 'motion-fixture',
      configuration: 'local-client',
      session: 'motion-session',
    );
    journal.record({'stage': 'motion_fixture_ready'});
    final bridge = NativeWorkbenchBridge(
      candidate: 'motion-fixture',
      configuration: 'local-client',
      session: 'motion-session',
      transport: 'unavailable',
      databasePath: '${directory.path}/unused.sqlite',
      launchConfigPath: '${directory.path}/unused-launch.json',
      launchConfigBytes: 1,
      mapController: controller,
      journal: journal,
    );
    await tester.pumpWidget(_syncHost(syncing: false));
    Future<Map<String, dynamic>> snapshot() async {
      return (await tester.runAsync(() async {
        final request = bridge.requestData('snapshot');
        await tester.pump();
        return jsonDecode(await request) as Map<String, dynamic>;
      }))!;
    }

    final reduced = await snapshot();
    expect(reduced['platformAccessibility'], {
      'platform': Platform.operatingSystem,
      'reduceMotion': true,
      'disableAnimations': false,
    });
    expect(reduced['mediaQuery'], isNull); // No DeliveryScreen was fabricated.
    expect(reduced['model'], isNull);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    final disabled = await snapshot();
    expect(disabled['platformAccessibility'], {
      'platform': Platform.operatingSystem,
      'reduceMotion': false,
      'disableAnimations': true,
    });
    expect(disabled['model'], isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
