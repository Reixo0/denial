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

/// The shade's flings (NotificationPanelViewController): opening and the
/// quick settings take at most 0.4 s without a speed-up (`loadDimens`),
/// closing at most 0.6 s with ShadeViewController's speed-up of 0.6.
enum AospFling {
  open(0.4, 0),
  close(0.6, 0.6),

  /// A notification's height (ExpandHelper).
  expand(0.3, 0);

  const AospFling(this.maxSeconds, this.speedUp);

  final double maxSeconds;
  final double speedUp;
}

/// Android's fling (FlingAnimationUtils): the motion starts at the finger's
/// speed and slows down on a linear-out-slow-in curve. Where that would take
/// longer than the fling may, it crosses over from the finger's speed to that
/// curve; too slow to be a fling, it is fast-out-slow-in.
///
/// Distances and speeds share one unit of which [dp] make one dp. The longest
/// time falls with the square root of [distance] over [maxDistance]; without
/// one it stays.
({Duration duration, Curve curve}) aospFling(
  AospFling kind, {
  required double distance,
  required double velocity,
  required double dp,
  double? maxDistance,
}) {
  final diff = distance.abs();
  if (diff <= 0) return (duration: Duration.zero, curve: Curves.linear);
  final speed = velocity.abs();
  final maxLength =
      kind.maxSeconds *
      (maxDistance == null ? 1 : math.sqrt(diff / maxDistance));
  final x2 = 0.35 + (0.68 - 0.35) * kind.speedUp;
  // Android compares its pixels with its 3000 dp per second here.
  final factor = kind.speedUp == 0
      ? 1.0
      : math.min(speed / (3000 * dp / _androidPixelsPerDp), 1.0);
  final gradient = 0.75 * (1 - factor) + factor / x2;
  final x1 = kind.speedUp * (1 - factor);
  final slowIn = Cubic(x1, x1 * gradient, x2, 1);
  var seconds = speed <= 0 ? double.infinity : gradient * diff / speed;
  Curve curve = slowIn;
  if (seconds > maxLength) {
    seconds = maxLength;
    curve = speed >= 250 * dp
        ? _FlingCurve(slowIn, seconds * speed / diff)
        : Curves.fastOutSlowIn;
  }
  return (
    duration: Duration(microseconds: (seconds * 1e6).round()),
    curve: curve,
  );
}

/// EvolutionX's density on this phone, 468 dpi.
const _androidPixelsPerDp = 468 / 160;

/// From a constant speed ([distance] over the whole time) to [slowIn].
class _FlingCurve extends Curve {
  const _FlingCurve(this.slowIn, this.distance);

  final Curve slowIn;
  final double distance;

  static const _crossfade = Cubic(0, 0, 0.2, 1);

  @override
  double transformInternal(double t) {
    final fade = _crossfade.transform(t);
    return math.min(1, (1 - fade) * distance * t + fade * slowIn.transform(t));
  }
}

/// The overshoot of a shade flung open (`flingToHeight`): while the panel
/// opens, the notifications go this far past their place, up to 16 dp
/// (panel_overshoot_amount) by the finger's speed, and spring back.
abstract final class AospOvershoot {
  static const double amount = 16;
  static const Duration springBack = Duration(milliseconds: 400);

  /// The list past its end: 6 dp of Android's pixels, in seconds of its
  /// speed, and the way back (ANIMATION_DURATION_STANDARD).
  static const double overfling = 6 * _androidPixelsPerDp / 1000;
  static const Duration listSpringBack = Duration(milliseconds: 360);

  /// Opened without a finger's speed (SHADE_OPEN_SPRING_OUT_DURATION).
  static const Duration springOut = Duration(milliseconds: 350);

  /// In dp, for a release at [speed] dp per second.
  static double of(double speed) =>
      amount * (0.2 + 0.8 * unit(speed / (3000 * 0.5)));
}

/// [second] over [first]'s progress.
class ChainedCurve extends Curve {
  const ChainedCurve(this.first, this.second);

  final Curve first;
  final Curve second;

  @override
  double transformInternal(double t) =>
      second.transform(first.transform(t).clamp(0.0, 1.0));
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
