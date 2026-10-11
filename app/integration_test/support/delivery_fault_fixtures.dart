import 'dart:async';

import 'package:ocean_delivery/data/delivery/sync_coordinator.dart';
import 'package:ocean_delivery/models/delivery.dart';

/// Synthetic seven-column source. It contains no user data or service endpoint.
/// Instrumentation may inject this into its own app sandbox; product code must
/// not import this test directory or silently replace an existing source.
const independentRiskCsv =
    '''reference,customer_name,address,latitude,longitude,status,time_window
REF-A,Harbour A,"1 Risk Street, Sydney",-33.8995,151.138,pending,08:00-10:00
REF-B,Harbour B,"2 Risk Street, Sydney",-33.905,151.145,pending,10:00-12:00
REF-C,Historical C,"3 Risk Street, Sydney",-33.91,151.15,completed,12:00-14:00
REF-D,Historical D,"4 Risk Street, Sydney",-33.92,151.16,failed,14:00-16:00
''';

Ack fixtureMatchingAck(PendingUpdate update) => Ack(
  operationId: update.operationId,
  datasetId: update.datasetId,
  stopId: update.stopId,
);

/// Test-only transport with an explicit response fence, no timer or network.
/// Not completing [reply] exercises the coordinator's real request deadline.
/// Native instrumentation must label these responses as simulated.
class HeldAckTransport implements SyncTransport {
  final firstSent = Completer<PendingUpdate>();
  final reply = Completer<Ack>();
  final requests = <PendingUpdate>[];

  @override
  Future<Ack> send(PendingUpdate update) {
    requests.add(update);
    if (requests.length != 1) {
      throw StateError('This one-request fixture detected another send.');
    }
    firstSent.complete(update);
    return reply.future;
  }

  void releaseMatching() => reply.complete(fixtureMatchingAck(requests.single));
}
