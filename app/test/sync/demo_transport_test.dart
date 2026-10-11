import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/data/services/demo_transport.dart';
import 'package:ocean_delivery/models/delivery.dart';

void main() {
  const update = PendingUpdate(
    seq: 7,
    operationId: 'demo-operation',
    datasetId: 'demo-dataset',
    stopId: 'demo-stop',
    status: DeliveryStatus.completed,
  );

  testWidgets('explicit demo waits 720ms before its matching simulated ack', (
    tester,
  ) async {
    final transport = DemoTransport();
    Ack? response;
    final sending = transport.send(update).then((ack) => response = ack);
    await tester.pump(const Duration(milliseconds: 719));
    expect(response, isNull);
    await tester.pump(const Duration(milliseconds: 1));
    await sending;
    expect(response!.operationId, update.operationId);
    expect(response!.datasetId, update.datasetId);
    expect(response!.stopId, update.stopId);
  });

  test('demo test latency accepts zero and rejects a negative delay', () async {
    final ack = await DemoTransport(latency: Duration.zero).send(update);
    expect(ack.operationId, update.operationId);
    expect(
      () => DemoTransport(latency: const Duration(milliseconds: -1)),
      throwsArgumentError,
    );
  });
}
