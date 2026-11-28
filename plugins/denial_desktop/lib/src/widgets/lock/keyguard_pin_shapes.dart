import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/animation.dart' show Curve;
import 'package:flutter/rendering.dart';

/// A small player for Android animated vector drawables, enough for the PIN
/// bouncer's shapes (AOSP pin_dot_shape_N_avd): nested groups that translate,
/// scale and rotate about a pivot, filled paths of moves and cubics that
/// morph, and objectAnimators with cubic path interpolators. The data comes
/// from tools/generate-keyguard-pin-shapes.py.
class AvdDrawable {
  const AvdDrawable({required this.viewport, required this.children});

  /// The square viewport the paths are drawn in.
  final double viewport;
  final List<AvdNode> children;

  /// How long it animates, in ms.
  double get duration {
    var end = 0.0;
    void visit(AvdNode node) {
      for (final frame in node._frames) {
        end = math.max(end, frame.start + frame.duration);
      }
      if (node is AvdGroup) node.children.forEach(visit);
    }

    children.forEach(visit);
    return end;
  }

  /// Draws it at [ms] into [rect] in [color].
  void paint(Canvas canvas, Rect rect, double ms, Color color) {
    canvas.save();
    canvas.translate(rect.left, rect.top);
    canvas.scale(rect.width / viewport, rect.height / viewport);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    for (final child in children) {
      child._paint(canvas, ms, paint);
    }
    canvas.restore();
  }
}

/// One animator: from [from] to [to] over [duration] ms after [start] ms.
class AvdKeyframe {
  const AvdKeyframe({
    required this.start,
    required this.duration,
    required this.from,
    required this.to,
    this.curve,
  });

  final double start;
  final double duration;

  /// A number, or a path's numbers.
  final Object from;
  final Object to;

  /// Null is Android's default, accelerate-decelerate.
  final Curve? curve;

  double _progress(double ms) {
    if (duration <= 0) return 1;
    final t = ((ms - start) / duration).clamp(0.0, 1.0);
    final curve = this.curve;
    return curve == null
        ? math.cos((t + 1) * math.pi) / 2 + 0.5
        : curve.transform(t);
  }
}

sealed class AvdNode {
  const AvdNode();

  Iterable<AvdKeyframe> get _frames;

  void _paint(Canvas canvas, double ms, Paint paint);
}

/// A value at [ms]: the static one until an animator starts, then each
/// animator in turn, holding its end value once it has run.
double _number(double initial, List<AvdKeyframe> frames, double ms) {
  var value = initial;
  for (final frame in frames) {
    if (ms < frame.start) break;
    final from = frame.from as double;
    final to = frame.to as double;
    value = from + (to - from) * frame._progress(ms);
  }
  return value;
}

class AvdGroup extends AvdNode {
  const AvdGroup({
    this.translateX = 0,
    this.translateY = 0,
    this.scaleX = 1,
    this.scaleY = 1,
    this.pivotX = 0,
    this.pivotY = 0,
    this.rotation = 0,
    this.translateXFrames = const [],
    this.translateYFrames = const [],
    this.scaleXFrames = const [],
    this.scaleYFrames = const [],
    this.rotationFrames = const [],
    required this.children,
  });

  final double translateX;
  final double translateY;
  final double scaleX;
  final double scaleY;
  final double pivotX;
  final double pivotY;

  /// Degrees.
  final double rotation;
  final List<AvdKeyframe> translateXFrames;
  final List<AvdKeyframe> translateYFrames;
  final List<AvdKeyframe> scaleXFrames;
  final List<AvdKeyframe> scaleYFrames;
  final List<AvdKeyframe> rotationFrames;
  final List<AvdNode> children;

  @override
  Iterable<AvdKeyframe> get _frames => [
    ...translateXFrames,
    ...translateYFrames,
    ...scaleXFrames,
    ...scaleYFrames,
    ...rotationFrames,
  ];

  @override
  void _paint(Canvas canvas, double ms, Paint paint) {
    final sx = _number(scaleX, scaleXFrames, ms);
    final sy = _number(scaleY, scaleYFrames, ms);
    if (sx == 0 || sy == 0) return;
    // VectorDrawable's group matrix: T(translate + pivot) R S T(-pivot).
    canvas.save();
    canvas.translate(
      _number(translateX, translateXFrames, ms) + pivotX,
      _number(translateY, translateYFrames, ms) + pivotY,
    );
    final degrees = _number(rotation, rotationFrames, ms);
    if (degrees != 0) canvas.rotate(degrees * math.pi / 180);
    canvas.scale(sx, sy);
    canvas.translate(-pivotX, -pivotY);
    for (final child in children) {
      child._paint(canvas, ms, paint);
    }
    canvas.restore();
  }
}

class AvdPath extends AvdNode {
  const AvdPath({
    required this.commands,
    required this.numbers,
    this.morph = const [],
  });

  /// One letter per command: M (2 numbers), C (6), Z.
  final String commands;
  final List<double> numbers;
  final List<AvdKeyframe> morph;

  @override
  Iterable<AvdKeyframe> get _frames => morph;

  List<double> _numbersAt(double ms) {
    var value = numbers;
    for (final frame in morph) {
      if (ms < frame.start) break;
      final from = frame.from as List<double>;
      final to = frame.to as List<double>;
      final t = frame._progress(ms);
      value = [
        for (var i = 0; i < from.length; i++) from[i] + (to[i] - from[i]) * t,
      ];
    }
    return value;
  }

  @override
  void _paint(Canvas canvas, double ms, Paint paint) {
    final n = _numbersAt(ms);
    final path = ui.Path();
    var i = 0;
    for (final command in commands.split('')) {
      switch (command) {
        case 'M':
          path.moveTo(n[i], n[i + 1]);
          i += 2;
        case 'C':
          path.cubicTo(n[i], n[i + 1], n[i + 2], n[i + 3], n[i + 4], n[i + 5]);
          i += 6;
        case 'Z':
          path.close();
      }
    }
    canvas.drawPath(path, paint);
  }
}
