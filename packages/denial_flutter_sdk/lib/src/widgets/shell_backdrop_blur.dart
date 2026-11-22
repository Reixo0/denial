import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../models/display_layout.dart';
import '../models/output_configuration.dart' show DenialOutputTransform;
import '../theme/shell_theme.dart';
import '../theme/glass_configuration.dart';

/// A tightly clipped, layout-aware blur for translucent compositor surfaces.
///
/// Every instance owns its backdrop unless [grouped] is true. Windows must
/// never be grouped because they can overlap; non-overlapping siblings such as
/// system-bar pills can opt into one shared engine blur through [BackdropGroup].
class ShellBackdropBlur extends StatelessWidget {
  const ShellBackdropBlur({
    required this.child,
    this.blur = true,
    this.grouped = false,
    this.useWindowAlphaThreshold = false,
    this.singleWindowSurface = false,
    this.separateChild = false,
    this.strength = 1,
    this.borderRadius,
    this.blendMode = ui.BlendMode.src,
    this.opacity,
    this.clipUnfiltered = true,
    this.edgeless = false,
    this.edgelessScale = 1,
    this.edgelessZoom,
    this.edgelessZoomOutput,
    super.key,
  }) : assert(strength >= 0 && strength <= 1),
       assert(!separateChild || !useWindowAlphaThreshold),
       assert(edgelessZoom == null || (edgeless && separateChild)),
       assert(!separateChild || blendMode == ui.BlendMode.src);

  final Widget child;
  final bool blur;
  final bool grouped;
  final bool useWindowAlphaThreshold;
  final bool singleWindowSurface;

  /// Paint foreground controls after the backdrop assignment. This keeps
  /// their geometry out of the filter's intermediate color layer. Window
  /// alpha-threshold materials need the foreground inside that layer instead.
  final bool separateChild;
  final double strength;
  final BorderRadiusGeometry? borderRadius;
  final ui.BlendMode blendMode;

  /// Fade the completed backdrop and foreground independently. In particular,
  /// separate-child glass must not be isolated with controls in an opacity group.
  final Animation<double>? opacity;

  /// Clip [child] to [borderRadius] even when no filter runs. Pass false for
  /// a child that paints its own rounded shape, such as a decorated tile, to
  /// spare it a clip on every frame.
  final bool clipUnfiltered;

  /// A plain blur without the glass edge, for a surface as large as the
  /// screen (see [ShellThemeData.edgelessBlurConfigAt]).
  final bool edgeless;

  /// Widens an [edgeless] blur.
  final double edgelessScale;

  /// Draws what is behind an [edgeless] surface that spans
  /// [edgelessZoomOutput] at this scale about its centre, its edges drawn out
  /// (SurfaceFlinger's background blur scale) as far as the blur covers the
  /// border. Only with [separateChild]. Null leaves the zoom out altogether.
  final double? edgelessZoom;

  /// Without it there is no zoom.
  final DisplayOutput? edgelessZoomOutput;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    final resolvedStrength = strength.clamp(0.0, 1.0).toDouble();
    final radius = borderRadius?.resolve(Directionality.of(context));
    final available =
        blur &&
        theme.backdropBlurEnabled &&
        (theme.transparencyMode == ShellTransparencyMode.glass ||
            theme.backdropBlurSigma > 0) &&
        (!edgeless || theme.blurStrength > 0) &&
        (!useWindowAlphaThreshold || theme.backdropBlurOpacityThreshold < 1.0);
    final enabled = available && resolvedStrength > 0;
    Widget fade(Widget value) => opacity == null
        ? value
        : FadeTransition(opacity: opacity!, child: value);
    final effectiveBlendMode = opacity == null
        ? blendMode
        : ui.BlendMode.srcOver;
    final Widget filtered;
    final zoomOutput = edgelessZoom == null ? null : edgelessZoomOutput;
    if (available && zoomOutput != null) {
      filtered = Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: fade(
              _ZoomedBackdrop(
                strength: resolvedStrength,
                scale: edgelessScale,
                zoom: edgelessZoom!,
                output: zoomOutput,
                grouped: grouped,
                blendMode: effectiveBlendMode,
                enabled: enabled,
              ),
            ),
          ),
          fade(child),
        ],
      );
    } else if (available) {
      final filterConfig = edgeless
          ? theme.edgelessBlurConfigAt(resolvedStrength, scale: edgelessScale)
          : theme.backdropFilterConfigAt(
              resolvedStrength,
              borderRadius: radius ?? BorderRadius.zero,
              useWindowAlphaThreshold: useWindowAlphaThreshold,
              singleWindowSurface: singleWindowSurface,
            );
      final filterChild = separateChild ? const SizedBox.expand() : child;
      final backdrop = grouped
          ? BackdropFilter.grouped(
              filterConfig: filterConfig,
              blendMode: effectiveBlendMode,
              enabled: enabled,
              child: filterChild,
            )
          : BackdropFilter(
              filterConfig: filterConfig,
              blendMode: effectiveBlendMode,
              enabled: enabled,
              child: filterChild,
            );
      filtered = separateChild
          ? Stack(
              fit: StackFit.passthrough,
              children: [
                Positioned.fill(child: fade(backdrop)),
                fade(child),
              ],
            )
          : fade(backdrop);
    } else {
      filtered = fade(child);
    }

    if (!available && !clipUnfiltered) {
      return filtered;
    }
    if (radius == null) {
      return available
          ? ClipRect(clipBehavior: Clip.hardEdge, child: filtered)
          : filtered;
    }
    if (radius == BorderRadius.zero) {
      return ClipRect(clipBehavior: Clip.hardEdge, child: filtered);
    }
    return ClipRRect(
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: filtered,
    );
  }
}

/// The blur of a scaled backdrop. The scale is the input of the blur, which
/// costs no pass of its own.
///
/// The engine evaluates a backdrop's matrix in the target's pixels when it
/// filters straight into the target, but in the canvas' axes when it keeps
/// the result for later frames, and the canvas may be turned (OpenGL's
/// targets are upside down). The filter is therefore laid out in the target's
/// pixels, where the two are the same.
class _ZoomedBackdrop extends StatelessWidget {
  const _ZoomedBackdrop({
    required this.strength,
    required this.scale,
    required this.zoom,
    required this.output,
    required this.grouped,
    required this.blendMode,
    required this.enabled,
  });

  final double strength;
  final double scale;
  final double zoom;
  final DisplayOutput output;
  final bool grouped;
  final ui.BlendMode blendMode;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ratio = output.scale;
    final target = output.transform.swapsAxes
        ? output.pixelSize.flipped
        : output.pixelSize;
    final centre = target.center(Offset.zero);
    final theme = ShellTheme.of(context);
    var config = theme.edgelessBlurConfigAt(strength, scale: scale * ratio);
    // The blur fills the border that the zoom leaves, as far as it hides that
    // the picture's edge is drawn out there. (SurfaceFlinger mirrors it.)
    final reach =
        0.8 * theme.edgelessBlurSigmaAt(strength, scale: scale * ratio);
    final zoom = math.max(this.zoom, 1 - 2 * reach / target.longestSide);
    if (zoom != 1) {
      config = ImageFilterConfig.compose(
        outer: config,
        inner: ImageFilterConfig(
          ui.ImageFilter.matrix(
            (Matrix4.translationValues(centre.dx, centre.dy, 0)
                  ..scaleByDouble(zoom, zoom, 1, 1)
                  ..translateByDouble(-centre.dx, -centre.dy, 0, 1))
                .storage,
            filterQuality: ui.FilterQuality.low,
          ),
        ),
      );
    }
    const child = SizedBox.expand();
    return Transform(
      transform: _logicalFromTarget(output),
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: target.width,
        maxWidth: target.width,
        minHeight: target.height,
        maxHeight: target.height,
        child: grouped
            ? BackdropFilter.grouped(
                filterConfig: config,
                blendMode: blendMode,
                enabled: enabled,
                child: child,
              )
            : BackdropFilter(
                filterConfig: config,
                blendMode: blendMode,
                enabled: enabled,
                child: child,
              ),
      ),
    );
  }
}

/// Maps the pixels of [output]'s target, whose rows run upwards in OpenGL, to
/// the output's logical coordinates: what the compositor's OutputProjection
/// and the engine do to the canvas, undone.
Matrix4 _logicalFromTarget(DisplayOutput output) {
  final Size(:width, :height) = output.pixelSize;
  // x' = a x + b y + c, y' = d x + e y + f, in pixels.
  final (a, b, c, d, e, f) = switch (output.transform) {
    DenialOutputTransform.normal => (1.0, 0.0, 0.0, 0.0, 1.0, 0.0),
    DenialOutputTransform.rotate90 => (0.0, 1.0, 0.0, -1.0, 0.0, width),
    DenialOutputTransform.rotate180 => (-1.0, 0.0, width, 0.0, -1.0, height),
    DenialOutputTransform.rotate270 => (0.0, -1.0, height, 1.0, 0.0, 0.0),
    DenialOutputTransform.flipped => (-1.0, 0.0, width, 0.0, 1.0, 0.0),
    DenialOutputTransform.flipped90 => (0.0, 1.0, 0.0, 1.0, 0.0, 0.0),
    DenialOutputTransform.flipped180 => (1.0, 0.0, 0.0, 0.0, -1.0, height),
    DenialOutputTransform.flipped270 => (0.0, -1.0, height, -1.0, 0.0, width),
  };
  final targetHeight = output.transform.swapsAxes ? width : height;
  final scale = output.scale;
  return Matrix4(
    a * scale,
    -d * scale,
    0,
    0, //
    b * scale,
    -e * scale,
    0,
    0, //
    0,
    0,
    1,
    0, //
    c,
    targetHeight - f,
    0,
    1,
  )..invert();
}
