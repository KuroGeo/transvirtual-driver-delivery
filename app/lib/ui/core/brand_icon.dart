import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The licensed Carbon paths from the approved prototype, loaded once.
class BrandIcon extends StatelessWidget {
  const BrandIcon(this.name, {super.key, this.size = 20, this.color});

  final String name;
  final double size;
  final Color? color;
  static final _paths = rootBundle
      .loadString('assets/icons.json')
      .then((source) => Map<String, String>.from(jsonDecode(source) as Map));

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: FutureBuilder<Map<String, String>>(
      future: _paths,
      builder: (context, snapshot) {
        final path = snapshot.data?[name];
        if (path == null) return const SizedBox.shrink();
        return SvgPicture.string(
          path,
          width: size,
          height: size,
          excludeFromSemantics: true,
          colorFilter: ColorFilter.mode(
            color ?? IconTheme.of(context).color ?? Colors.black,
            BlendMode.srcIn,
          ),
        );
      },
    ),
  );
}

class SyncActionIcon extends StatefulWidget {
  const SyncActionIcon({super.key, required this.syncing, this.size = 20});
  final bool syncing;
  final double size;

  @override
  State<SyncActionIcon> createState() => _SyncActionIconState();
}

class _SyncActionIconState extends State<SyncActionIcon>
    with SingleTickerProviderStateMixin {
  late final _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(covariant SyncActionIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  void _update() {
    if (widget.syncing && !MediaQuery.disableAnimationsOf(context)) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
      _rotation.value = 0;
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _rotation,
    child: BrandIcon('sync', size: widget.size),
  );
}
