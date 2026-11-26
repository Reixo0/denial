import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/effects.dart'
    show edgelessZoomedBackdropConfig;
import 'package:denial_flutter_sdk/models.dart' show DisplayOutput;
import 'package:denial_flutter_sdk/shell_theme.dart';

/// Android's notification card and shelf blur radius (25 dp,
/// NotificationBackgroundView) against the shade's (34 dp): the cards blur
/// what is behind the shade live, from the same backdrop sample as the shade
/// (SurfaceFlinger blur regions of one window), only less.
const double shadeCardBlurRatio = 25 / 34;

/// Host render object that collects notification cards and shelf shapes for
/// painting their 25 dp blur of what is behind the shade.
abstract interface class ShadeCardHost implements RenderObject {
  void addCard(RenderShadeCard card);
  void removeCard(RenderShadeCard card);
}

/// Registers a notification card (or shelf) shape with an ancestor
/// [ShadeCardHost], tracking transforms and animations through [motion].
class ShadeCard extends SingleChildRenderObjectWidget {
  const ShadeCard({
    required this.shape,
    required this.motion,
    required super.child,
    super.key,
  });

  final RRect? Function(Size size) shape;
  final Listenable motion;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderShadeCard(shape, motion);

  @override
  void updateRenderObject(BuildContext context, RenderShadeCard renderObject) {
    renderObject
      ..shape = shape
      ..motion = motion;
  }
}

class RenderShadeCard extends RenderProxyBox {
  RenderShadeCard(this._shape, this._motion);

  ShadeCardHost? _host;

  RRect? Function(Size size) _shape;
  set shape(RRect? Function(Size size) value) {
    _shape = value;
    _moved();
  }

  Listenable _motion;
  set motion(Listenable value) {
    if (identical(value, _motion)) return;
    if (attached) {
      _motion.removeListener(_moved);
      value.addListener(_moved);
    }
    _motion = value;
    _moved();
  }

  void _moved() => _host?.markNeedsPaint();

  void addTo(Path path, RenderObject target) {
    if (!attached || !hasSize) return;
    final shape = _shape(size);
    if (shape == null || shape.isEmpty) return;
    path.addPath(
      Path()..addRRect(shape),
      Offset.zero,
      matrix4: getTransformTo(target).storage,
    );
  }

  @override
  void performLayout() {
    super.performLayout();
    _moved();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    RenderObject? ancestor = parent;
    while (ancestor != null && ancestor is! ShadeCardHost) {
      ancestor = ancestor.parent;
    }
    _host = ancestor as ShadeCardHost?;
    _host?.addCard(this);
    _motion.addListener(_moved);
  }

  @override
  void detach() {
    _motion.removeListener(_moved);
    _host?.removeCard(this);
    _host = null;
    super.detach();
  }
}

/// What the notification cards need to blur what is behind the shade the way
/// the shade does: its backdrop group (one sample of the screen for both
/// blurs), the output whose pixels the blur is drawn in, and the blur scale.
@immutable
class ShadeCardBlur {
  const ShadeCardBlur({
    required this.theme,
    required this.output,
    required this.scale,
    required this.backdropKey,
  });

  final ShellThemeData theme;
  final DisplayOutput output;

  /// The shade's edgeless blur scale times [shadeCardBlurRatio].
  final double scale;
  final BackdropKey? backdropKey;

  /// The filter at the shade's blur fraction [strength] and zoom [zoom].
  ui.ImageFilter filterAt(double strength, double zoom) {
    final target = output.transform.swapsAxes
        ? output.pixelSize.flipped
        : output.pixelSize;
    return edgelessZoomedBackdropConfig(
      theme,
      strength: strength,
      scale: scale,
      zoom: zoom,
      output: output,
    ).resolve(ImageFilterContext(bounds: Offset.zero & target));
  }

  @override
  bool operator ==(Object other) =>
      other is ShadeCardBlur &&
      other.theme == theme &&
      other.output == output &&
      other.scale == scale &&
      other.backdropKey == backdropKey;

  @override
  int get hashCode => Object.hash(theme, output, scale, backdropKey);
}
