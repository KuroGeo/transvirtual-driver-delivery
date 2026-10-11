import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/ui/delivery/map/delivery_map_workspace.dart';

import '../integration_test/support/native_workbench_bridge.dart';

void main() {
  for (final height in [44.0, 43.5]) {
    testWidgets(
      'native bounds retain $height layout height at fractional global offset',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'ocean-native-geometry-',
        );
        final controller = DeliveryMapController();
        addTearDown(controller.dispose);
        addTearDown(() => directory.deleteSync(recursive: true));
        final journal = NativeWorkbenchJournal(
          file: File('${directory.path}/$nativeJournalName'),
          candidate: 'geometry-fixture',
          configuration: 'local-client',
          session: 'geometry-fixture-session',
        );
        journal.record({'stage': 'geometry_fixture_ready'});
        final bridge = NativeWorkbenchBridge(
          candidate: 'geometry-fixture',
          configuration: 'local-client',
          session: 'geometry-fixture-session',
          transport: 'unavailable',
          databasePath: '${directory.path}/unused.sqlite',
          launchConfigPath: '${directory.path}/unused-launch.json',
          launchConfigBytes: 1,
          mapController: controller,
          journal: journal,
        );
        const key = ValueKey('map-sync');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned(
                    left: 477.09,
                    top: 477.09,
                    child: SizedBox(
                      key: key,
                      width: 88,
                      height: height,
                      child: const ColoredBox(color: Colors.blue),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final render = tester.renderObject<RenderBox>(find.byKey(key));
        final global = render.localToGlobal(Offset.zero) & render.size;
        if (height == 44) {
          // This is the actual floating-point counterexample from N7:
          // subtracting global bottom/top turns a 44px layout into <44.
          expect(global.height, lessThan(44));
          expect(global.width, lessThan(88));
        }
        final snapshot = await tester.runAsync(() async {
          final request = bridge.requestData('snapshot');
          await tester.pump();
          return jsonDecode(await request) as Map<String, dynamic>;
        });
        final bounds = snapshot!['bounds'] as Map<String, dynamic>;
        final measured =
            (bounds['map-sync'] as List<dynamic>).single
                as Map<String, dynamic>;
        expect(measured['width'], 88);
        expect(measured['height'], height);
        expect(measured['left'], global.left);
        expect(measured['top'], global.top);
        expect(measured['right'], global.right);
        expect(measured['bottom'], global.bottom);
        expect(measured['centerHit'], isTrue);
        if (height < 44) {
          // Measurement cannot round up a genuinely undersized target.
          expect(measured['height'], lessThan(44));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
