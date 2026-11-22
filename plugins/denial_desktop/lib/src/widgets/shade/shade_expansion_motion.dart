import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/motion.dart';

/// The owner's EvolutionX plays every animation in three quarters of the time
/// its code says (Android's animator duration scale): measured on its shade's
/// flings, their spring back and the quick settings' closing.
const double androidAnimatorScale = 0.75;

/// [milliseconds] of Android's code, as the owner's phone plays them.
Duration androidDuration(int milliseconds) => Duration(
  microseconds: (milliseconds * 1000 * androidAnimatorScale).round(),
);

/// AOSP's ShadeInterpolation: how the shade's scrim, blur and content follow
/// its expansion fraction, the same opening and closing.
abstract final class AospShadeInterpolation {
  /// getNotificationScrimAlpha: the scrim, the panel's tint and the blur
  /// (NotificationShadeDepthController blurs by it), full at half the pull.
  static double scrimAlpha(double fraction) => _easeInOut(unit(fraction / 0.5));

  /// NotificationShadeDepthController's blur: 0.8 of it follows the scrim
  /// (INTERACTION_BLUR_FRACTION) and 0.2 springs in as soon as the shade
  /// starts moving and out as it is let go to close (shadeAnimation,
  /// ANIMATION_BLUR_FRACTION), which is why what is behind blurs at the first
  /// touch of a pull. The full quick settings keep it up with the panel.
  static double blurFraction(double fraction, double depth, double qs) =>
      math.max(
        0.8 * scrimAlpha(fraction) + 0.2 * unit(depth),
        scrimAlpha(qs) * unit(fraction),
      );

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
    duration: Duration(
      microseconds: (seconds * androidAnimatorScale * 1e6).round(),
    ),
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
  static final Duration springBack = androidDuration(400);

  /// The list past its end: 6 dp of Android's pixels, in seconds of its
  /// speed, and the way back (ANIMATION_DURATION_STANDARD).
  static const double overfling = 6 * _androidPixelsPerDp / 1000;
  static final Duration listSpringBack = androidDuration(360);

  /// Opened without a finger's speed (SHADE_OPEN_SPRING_OUT_DURATION).
  static final Duration springOut = androidDuration(350);

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

/// [AospShadeInterpolation.blurFraction] of a shade's panel fraction, its
/// [ShadeExpansion.depth] and its quick settings (which move on their own only
/// under a full blur).
class ShadeBlurAnimation extends CompoundAnimation<double> {
  ShadeBlurAnimation(Animation<double> panel, Animation<double> depth, this._qs)
    : super(first: panel, next: depth);

  final Animation<double> _qs;

  @override
  double get value =>
      AospShadeInterpolation.blurFraction(first.value, next.value, _qs.value);
}

/// NotificationShadeDepthController's shadeAnimation: the spring of the part
/// of the blur that does not follow the finger.
abstract final class AospDepthSpring {
  /// SpringForce.STIFFNESS_LOW, DAMPING_RATIO_NO_BOUNCY, as fast as the
  /// animator scale makes it (DynamicAnimation divides the time by it).
  static final SpringDescription spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 200 / (androidAnimatorScale * androidAnimatorScale),
  );

  /// max_shade_window_blur_radius, 34 dp, in EvolutionX's pixels.
  static const double radius = 34 * 2.925;

  /// It ends within three quarters of a pixel (DynamicAnimation's
  /// VALUE_THRESHOLD_MULTIPLIER; the speed, that in a frame of 16 ms).
  static const Tolerance tolerance = Tolerance(
    distance: 0.75 / radius,
    velocity: 0.75 / radius * 62.5,
  );

  /// The spring's speed at the start of a move of the panel by [change] in
  /// [seconds] (VELOCITY_SCALE, MAX_VELOCITY), in blurs per second.
  static double speed(double change, double seconds) =>
      (100 * change / seconds.clamp(0.00001, 1.0)).clamp(-3000.0, 3000.0) /
      radius /
      androidAnimatorScale;
}
