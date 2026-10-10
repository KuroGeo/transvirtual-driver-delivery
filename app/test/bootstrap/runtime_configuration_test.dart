import 'package:flutter_test/flutter_test.dart';
import 'package:ocean_delivery/app/runtime_configuration.dart';

void main() {
  test('demo cannot use the existing local-client database container', () {
    final local = RuntimeConfiguration.parse('local-client');
    final demo = RuntimeConfiguration.parse('demo');
    expect(local.isDemo, isFalse);
    expect(local.databaseName, 'ocean_delivery.sqlite');
    expect(demo.isDemo, isTrue);
    expect(demo.databaseName, isNot(local.databaseName));
    expect(RuntimeConfiguration.parse('').isDemo, isFalse);
    expect(
      () => RuntimeConfiguration.parse('connected'),
      throwsFormatException,
    );
  });
}
