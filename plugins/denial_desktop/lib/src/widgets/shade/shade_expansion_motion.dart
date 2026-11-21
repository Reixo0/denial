import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/motion.dart';

/// AOSP's ShadeInterpolation: how the shade's scrim, blur and content follow
/// its expansion fraction, the same opening and closing.
abstract final class AospShadeInterpolation {
  /// getNotificationScrimAlpha: the scrim, the panel's tint and the blur
  /// (NotificationShadeDepthController blurs by it), full at half the pull.
  static double scrimAlpha(double fraction) => _easeInOut(unit(fraction / 0.5));

  /// NotificationShadeDepthController's blur: 0.8 of it follows the scrim
  /// (INTERACTION_BLUR_FRACTION) and 0.2 springs in as soon as the shade
  /// starts moving (shadeAnimation, ANIMATION_BLUR_FRACTION), which is why
  /// what is behind blurs at the first touch of a pull.
  static double blurFraction(double fraction, double engaged) =>
      0.8 * scrimAlpha(fraction) + 0.2 * unit(engaged);

  /// getContentAlpha: the shade's content, from 30 % of the pull on.
  static double contentAlpha(double fraction) =>
      _easeInOut(unit((fraction - 0.3) / 0.7));

  static double _easeInOut(double fraction) {
    final mapped = fraction * 1.2 - 0.2;
    if (mapped <= 0) return 0;
    final rest = 1 - mapped;
    return 1 - 0.5 * (1 - math.cos(3.14159 * rest * rest));
  }

  /// NotificationPanelViewController.QS_PARALLAX_AMOUNT: the quick settings
  /// come down from this share of their height above their place.
  static const double qsParallax = 0.175;
}

/// Android's shade fling (FlingAnimationUtils with ShadeViewController's
/// FLING_MAX_LENGTH_SECONDS 0.6 and FLING_SPEED_UP_FACTOR 0.6): the motion
/// starts at the finger's speed and slows down on a linear-out-slow-in
/// curve, taking at most 0.6 s, less over a shorter way (by its square
/// root). Without a fling it takes the longest time, fast-out-slow-in.
/// Distances and speeds are in the animation's own units (its whole travel
/// is 1); [dp] is how many of those units make one dp.
({Duration duration, Curve curve}) aospShadeFling({
  required double distance,
  required double velocity,
  required double dp,
  double maxSeconds = 0.6,
}) {
  const speedUp = 0.6;
  const x2Min = 0.35;
  const x2Max = 0.68;
  final diff = distance.abs();
  if (diff <= 0) return (duration: Duration.zero, curve: Curves.linear);
  final speed = velocity.abs();
  final minSpeed = 250 * dp;
  final highSpeed = 3000 * dp;
  final maxLength = maxSeconds * math.sqrt(diff.clamp(0.0, 1.0));
  final fastest = x2Min + (x2Max - x2Min) * speedUp;
  final factor = math.min(speed / highSpeed, 1.0);
  final x2 = x2Min + (fastest - x2Min) * factor;
  var seconds = speed <= 0 ? double.infinity : diff / (speed * x2);
  Curve curve = Cubic(0, 0, x2, 1);
  if (seconds > maxLength) {
    seconds = maxLength;
    if (speed < minSpeed) curve = Curves.fastOutSlowIn;
  }
  return (
    duration: Duration(microseconds: (seconds * 1e6).round()),
    curve: curve,
  );
}

/// [AospShadeInterpolation.blurFraction] of a shade's panel fraction and its
/// [ShadeExpansion.engaged] animation.
class ShadeBlurAnimation extends CompoundAnimation<double> {
  ShadeBlurAnimation(Animation<double> panel, Animation<double> engaged)
    : super(first: panel, next: engaged);

  @override
  double get value =>
      AospShadeInterpolation.blurFraction(first.value, next.value);
}
