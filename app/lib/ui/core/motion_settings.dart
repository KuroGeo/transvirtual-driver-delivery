import 'package:flutter/widgets.dart';

/// iOS exposes Reduce Motion separately from the disable-animations flag.
/// Preserve a caller's MediaQuery opt-out while honoring both engine signals.
bool reduceMotionRequested(BuildContext context) {
  final features =
      WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
  return features.reduceMotion ||
      features.disableAnimations ||
      MediaQuery.disableAnimationsOf(context);
}
