import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/shell_theme.dart';

/// Identifies the scene layer painted behind the notification shade so cards can
/// snapshot and blur it once per opening instead of adding a live BackdropFilter.
final shadeSceneBoundaryKeyProvider = Provider<GlobalKey>(
  (ref) => GlobalKey(debugLabel: 'shade scene backdrop'),
);

/// Host render object that collects notification cards and shelf shapes for
/// painting their shared 25 dp blurred scene slice.
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

@immutable
class ShadeCardBackdrop {
  const ShadeCardBackdrop(this.image, this.rect);

  final ui.Image image;
  final Rect rect;

  void dispose() => image.dispose();
}

/// Captures and blurs the scene behind the shade once per opening at
/// `25 / 34` of the shade's blur radius, avoiding a second live `BackdropFilter`.
class ShadeCardBackdropCapture extends ValueNotifier<ShadeCardBackdrop?> {
  ShadeCardBackdropCapture() : super(null);

  static const double _pixelRatio = 0.25;

  /// Ratio of Android's notification card blur radius (25 dp) to the shade's
  /// maximum blur radius (34 dp).
  static const double cardBlurRatio = 25 / 34;
  static const double _margin = 96;

  int _generation = 0;
  bool _capturing = false;
  bool _disposed = false;
  GlobalKey? _pendingKey;
  ShellThemeData? _pendingTheme;
  double? _pendingScale;

  void clear() {
    _generation++;
    _pendingKey = null;
    _pendingTheme = null;
    _pendingScale = null;
    _replace(null);
  }

  void capture(
    GlobalKey boundaryKey,
    ShellThemeData theme, {
    required double scale,
  }) {
    if (_disposed) return;
    final disabled =
        !theme.backdropBlurEnabled ||
        theme.blurStrength <= 0 ||
        theme.effectivePanelOpacity >= 1.0 ||
        theme.edgelessBlurSigmaAt(1.0, scale: scale) <= 0;
    if (disabled) {
      clear();
      return;
    }
    if (_capturing) {
      _pendingKey = boundaryKey;
      _pendingTheme = theme;
      _pendingScale = scale;
      return;
    }
    unawaited(_captureNow(boundaryKey, theme, scale));
  }

  Future<void> _captureNow(
    GlobalKey boundaryKey,
    ShellThemeData theme,
    double scale,
  ) async {
    final object = boundaryKey.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary || !object.attached || !object.hasSize) {
      return;
    }
    final filter = theme
        .edgelessBlurConfigAt(1.0, scale: scale)
        .resolve(
          ImageFilterContext(bounds: Offset.zero & object.size),
        );
    final generation = ++_generation;
    final rect = MatrixUtils.transformRect(
      object.getTransformTo(null),
      Offset.zero & object.size,
    );
    _capturing = true;
    ui.Image? source;
    try {
      source = await object.toImage(pixelRatio: _pixelRatio);
      if (_disposed || generation != _generation) return;
      final blurred = await _frost(source, rect.size, filter);
      if (_disposed || generation != _generation) {
        blurred.dispose();
        return;
      }
      _replace(ShadeCardBackdrop(blurred, rect));
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'denial rendering',
          context: ErrorDescription('while capturing notification card blur'),
        ),
      );
    } finally {
      source?.dispose();
      _capturing = false;
      final nextKey = _pendingKey;
      final nextTheme = _pendingTheme;
      final nextScale = _pendingScale;
      _pendingKey = null;
      _pendingTheme = null;
      _pendingScale = null;
      if (!_disposed &&
          nextKey != null &&
          nextTheme != null &&
          nextScale != null) {
        capture(nextKey, nextTheme, scale: nextScale);
      }
    }
  }

  static Future<ui.Image> _frost(
    ui.Image source,
    Size size,
    ui.ImageFilter filter,
  ) async {
    final bounds = (Offset.zero & size).inflate(_margin);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)..scale(_pixelRatio);
    canvas.saveLayer(null, Paint()..imageFilter = filter);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.ImageShader(
          source,
          ui.TileMode.clamp,
          ui.TileMode.clamp,
          Matrix4.diagonal3Values(
            size.width / source.width,
            size.height / source.height,
            1,
          ).storage,
          filterQuality: ui.FilterQuality.low,
        ),
    );
    canvas.restore();
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(
        (size.width * _pixelRatio).ceil(),
        (size.height * _pixelRatio).ceil(),
      );
    } finally {
      picture.dispose();
    }
  }

  void _replace(ShadeCardBackdrop? next) {
    final previous = value;
    if (previous == null && next == null) return;
    value = next;
    if (previous == null) return;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => previous.dispose())
      ..ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    value?.dispose();
    super.dispose();
  }
}
