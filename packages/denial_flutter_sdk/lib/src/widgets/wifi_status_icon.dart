import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../shell_theme.dart';

/// Connection and signal-strength glyph shared by mobile and desktop surfaces.
class WifiStatusIcon extends StatelessWidget {
  const WifiStatusIcon({
    super.key,
    required this.active,
    this.strength = 0,
    this.size = 17,
    this.color,
  });

  final bool active;
  final int strength;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? context.shellColors.textPrimary;
    if (!active) {
      return Icon(
        Icons.wifi_off_rounded,
        color: foreground.withValues(alpha: 0.35),
        size: size,
      );
    }
    // Thirds of the strength, one per part of the glyph: its wedge, middle
    // arc and outer arc. Every level keeps the full icon's shape; the parts
    // the signal does not reach are dimmed, as Android does.
    final level = (strength.clamp(0, 100) * 3 / 100).ceil();
    final full = Icon(Icons.wifi_rounded, color: foreground, size: size);
    if (level >= 3) return full;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: <Widget>[
          Icon(
            Icons.wifi_rounded,
            color: foreground.withValues(alpha: 0.3),
            size: size,
          ),
          if (level > 0)
            ClipPath(
              clipper: _WifiReach(level == 1 ? 0.21 : 0.45),
              child: full,
            ),
        ],
      ),
    );
  }
}

/// A circle around the glyph's point (at 81 % of its height), reaching
/// [radius] of its size: 0.21 holds the wedge, 0.45 the middle arc too.
class _WifiReach extends CustomClipper<Path> {
  const _WifiReach(this.radius);

  final double radius;

  @override
  Path getClip(Size size) => Path()
    ..addOval(
      Rect.fromCircle(
        center: Offset(size.width / 2, size.height * 0.813),
        radius: size.shortestSide * radius,
      ),
    );

  @override
  bool shouldReclip(_WifiReach oldClipper) => oldClipper.radius != radius;
}
