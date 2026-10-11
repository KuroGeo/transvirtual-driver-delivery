/// Build configuration also chooses a separate durable container. A demo must
/// never acknowledge operations saved by the local client.
class RuntimeConfiguration {
  const RuntimeConfiguration._(this.isDemo);

  factory RuntimeConfiguration.parse(String name) => switch (name) {
    'demo' => const RuntimeConfiguration._(true),
    '' || 'local-client' => const RuntimeConfiguration._(false),
    _ => throw FormatException('Unsupported OCEAN_MODE: $name'),
  };

  static RuntimeConfiguration get environment => RuntimeConfiguration.parse(
    const String.fromEnvironment('OCEAN_MODE', defaultValue: 'local-client'),
  );

  final bool isDemo;

  String get databaseName =>
      isDemo ? 'ocean_delivery-demo.sqlite' : 'ocean_delivery.sqlite';
  String get name => isDemo ? 'demo' : 'local-client';
}
