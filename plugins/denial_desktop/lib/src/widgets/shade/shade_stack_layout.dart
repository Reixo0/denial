import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'notification_shade_list.dart' show AndroidStackExpansion;

/// The parts of the shade, each moved on its own.
enum ShadePart {
  /// The shade header's clock (ShadeHeaderController's MotionLayout).
  clock,

  /// The header's date.
  date,

  /// The header's status icons and battery.
  icons,

  /// The header's network operator, shown in the full quick settings.
  carrier,

  /// The brightness slider.
  slider,

  /// The tile grid's first page at its full height.
  grid,

  /// The row under the grid (page dots, edit).
  gridFooter,

  /// The media player.
  media,

  /// The footer actions (settings, power), at the bottom of the screen.
  footer,

  /// The notification stack.
  list,
}

/// Places one part of the shade ([ShadePart]).
class ShadeStackSlot extends ParentDataWidget<_ShadeStackParentData> {
  const ShadeStackSlot({required this.part, required super.child, super.key});

  final ShadePart part;

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _ShadeStackParentData;
    if (data.part != part) {
      data.part = part;
      renderObject.parent?.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => ShadeStackLayout;
}

/// The shade as EvolutionX draws it: AOSP's Compose quick settings
/// (QSFragmentCompose) over the notification stack, with the classic shade
/// header.
///
/// Every part is laid out once at its own size; the panel fraction (how far
/// the shade is pulled) and the quick-settings fraction only move, scale,
/// clip and fade them, so nothing is built or laid out during the motion.
///
/// Quick settings (`FromQuickQuickSettingsToQuickSettings`): the grid's
/// anchor moves linearly from the quick tiles' place to the full quick
/// settings'; the tiles both show are shared elements and stay opaque; the
/// rest of the content keeps its place relative to the anchor
/// (anchoredTranslate) and fades in from 0.43; the footer actions fade in
/// from 0.9 at the bottom of the screen. Everything of the quick settings
/// is clipped at the notification stack's top, which follows the finger to
/// the bottom of the screen (measured on EvolutionX: 235 dp + 701.5 dp × the
/// fraction).
///
/// Header (`combined_qs_header_scene.xml`, progress = the fraction): the
/// clock moves down into the carrier row and scales by 2.57; the date and
/// icons fade out by 0.14, jump while hidden and fade in from 0.58; the
/// operator fades in from 0.58.
///
/// First pull (EvolutionX's slow-pull recording): the stack's top comes
/// down from the screen's top with the panel (AOSP's stackY) and cuts the
/// quick tiles and an active media player, which stay in place and opaque,
/// squashed by AOSP's QS squishiness (QsTileMotion). The notifications come
/// down with that top, squashed, and fade in (getContentAlpha); the header
/// fades in as the top passes the first row ([ShadeReveal]).
///
/// Units are the shade's dp, from the top of the screen.
/// How far the notifications have scrolled up.
class ShadeListScroll extends ChangeNotifier {
  ScrollController? _controller;

  void attach(ScrollController controller) {
    _controller?.removeListener(notifyListeners);
    _controller = controller..addListener(notifyListeners);
  }

  void detach(ScrollController controller) {
    if (!identical(_controller, controller)) return;
    controller.removeListener(notifyListeners);
    _controller = null;
  }

  double get offset {
    final controller = _controller;
    if (controller == null || !controller.hasClients) return 0;
    final position = controller.positions.first;
    return position.hasPixels ? math.max(0, position.pixels) : 0;
  }
}

class ShadeStackLayout extends MultiChildRenderObjectWidget {
  const ShadeStackLayout({
    super.key,
    required this.panel,
    required this.qs,
    required this.pullsBoth,
    required this.listScroll,
    required this.panelColor,
    required this.sideMargin,
    required this.quickTilesHeight,
    required this.mediaActive,
    required this.onTravel,
    super.children,
  });

  final Animation<double> panel;
  final Animation<double> qs;

  /// A two-finger pull: the panel uncovers the full quick settings, without
  /// the notifications.
  final ValueListenable<bool> pullsBoth;

  final ShadeListScroll listScroll;

  /// The tint of the panel behind the notifications (AOSP's notifications
  /// scrim), which reaches over [sideMargin] to the screen's sides.
  final Color panelColor;
  final double sideMargin;

  /// The quick tiles' grid height (two rows), unsquished.
  final double quickTilesHeight;

  /// The media player shows in the quick tiles too (AOSP
  /// showsOnlyActiveMedia): it moves between the two places, opaque.
  final bool mediaActive;

  /// The finger's travel from the quick tiles to the full quick settings:
  /// the notification stack's, which follows it.
  final ValueChanged<double> onTravel;

  @override
  RenderShadeStack createRenderObject(BuildContext context) => RenderShadeStack(
    panel: panel,
    qs: qs,
    pullsBoth: pullsBoth,
    listScroll: listScroll,
    panelColor: panelColor,
    sideMargin: sideMargin,
    quickTilesHeight: quickTilesHeight,
    mediaActive: mediaActive,
    onTravel: onTravel,
  );

  @override
  void updateRenderObject(BuildContext context, RenderShadeStack renderObject) {
    renderObject
      ..panel = panel
      ..qs = qs
      ..pullsBoth = pullsBoth
      ..listScroll = listScroll
      ..panelColor = panelColor
      ..sideMargin = sideMargin
      ..quickTilesHeight = quickTilesHeight
      ..mediaActive = mediaActive
      ..onTravel = onTravel;
  }
}

/// Which side of the notification panel's edge a part shows on.
enum _ShadeClip { none, abovePanel, inPanel }

class _ShadeStackParentData extends ContainerBoxParentData<RenderBox> {
  ShadePart? part;

  /// How the part is drawn for the current fractions.
  Offset place = Offset.zero;
  double scale = 1;
  _ShadeClip clip = _ShadeClip.none;
  double alpha = 1;
  bool hittable = false;

  final clipLayer = LayerHandle<ClipRRectLayer>();
  final outsideLayer = LayerHandle<ClipPathLayer>();
  final aboveLayer = LayerHandle<ClipRectLayer>();
  final opacityLayer = LayerHandle<OpacityLayer>();
  final transformLayer = LayerHandle<TransformLayer>();
}

/// EvolutionX's places, in dp from uiautomator dumps of both states.
/// The first pull, as EvolutionX's slow-pull recording shows it.
abstract final class ShadeReveal {
  /// AOSP's QS squishiness: constrainSquishiness (0.1 + 0.9 ×) of the
  /// stack's squishiness fraction.
  static double tileSquish(double panel) =>
      0.1 + 0.9 * AndroidStackExpansion.squish(panel);

  /// The header fades in quickly as the stack's top passes the first tile
  /// row (about 90 ms on the recording, as the notifications appear).
  static double headerAlpha(double panel) =>
      ((panel - 0.45) / 0.08).clamp(0.0, 1.0);
}

abstract final class _Places {
  /// The quick tiles' grid top, under the 48 dp header row.
  static const double quickGridTop = 48;

  /// The full quick settings' grid top.
  static const double fullGridTop = 216;

  /// The slider's top over the full grid: 150 dp.
  static const double sliderAboveGrid = 66;

  /// Between the grid's last element and the media player.
  static const double mediaGap = 8;

  /// From the quick tiles' bottom to the notification stack.
  static const double stackGap = 40;

  /// The panel behind the notifications starts this far above them and has
  /// these corners (notification_scrim_corner_radius).
  static const double panelPadding = 16;
  static const double panelRadius = 32;

  /// The stack's top in the full quick settings, past the screen's bottom.
  static const double stackPastBottom = 18;

  /// The footer actions end above the navigation bar: 895 of 919 dp.
  static const double footerBottom = 24;

  /// The header's rows: 0-48 (first pull), 48-96 operator, 96-120 date.
  static const double quickRowCentre = 24;
  static const double clockCentre = 65;
  static const double carrierCentre = 72;
  static const double dateCentre = 108;
  static const double clockScale = 2.57;
  static const double dateAfterClock = 8;
}

/// MotionLayout's keyframes for the date and the icons: they leave
/// (0.1066 of the way down by frame 14), cross while hidden (half-way by
/// frame 50) and arrive.
double _keyframed(double t, List<(double, double)> frames) {
  for (var i = 1; i < frames.length; i++) {
    final (t1, v1) = frames[i];
    if (t <= t1) {
      final (t0, v0) = frames[i - 1];
      final f = t1 == t0 ? 1.0 : (t - t0) / (t1 - t0);
      return v0 + (v1 - v0) * f;
    }
  }
  return frames.last.$2;
}

const _hiddenX = <(double, double)>[(0, 0), (0.14, 0), (0.5, 1), (1, 1)];
const _hiddenY = <(double, double)>[(0, 0), (0.14, 0.1066), (0.5, 0.5), (1, 1)];
const _hiddenAlpha = <(double, double)>[(0, 1), (0.14, 0), (0.58, 0), (1, 1)];
const _carrierAlpha = <(double, double)>[(0, 0), (0.58, 0), (1, 1)];

class RenderShadeStack extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ShadeStackParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ShadeStackParentData> {
  RenderShadeStack({
    required this._panel,
    required this._qs,
    required this._pullsBoth,
    required this._listScroll,
    required this._panelColor,
    required this._sideMargin,
    required this._quickTilesHeight,
    required this._mediaActive,
    required this.onTravel,
  });

  ValueChanged<double> onTravel;

  Animation<double> _panel;
  Animation<double> get panel => _panel;
  set panel(Animation<double> value) {
    if (identical(value, _panel)) return;
    if (attached) _panel.removeListener(markNeedsPaint);
    _panel = value;
    if (attached) _panel.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Animation<double> _qs;
  Animation<double> get qs => _qs;
  set qs(Animation<double> value) {
    if (identical(value, _qs)) return;
    if (attached) _qs.removeListener(markNeedsPaint);
    _qs = value;
    if (attached) _qs.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  ValueListenable<bool> _pullsBoth;
  ValueListenable<bool> get pullsBoth => _pullsBoth;
  set pullsBoth(ValueListenable<bool> value) {
    if (identical(value, _pullsBoth)) return;
    if (attached) _pullsBoth.removeListener(markNeedsPaint);
    _pullsBoth = value;
    if (attached) _pullsBoth.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  ShadeListScroll _listScroll;
  ShadeListScroll get listScroll => _listScroll;
  set listScroll(ShadeListScroll value) {
    if (identical(value, _listScroll)) return;
    if (attached) _listScroll.removeListener(markNeedsPaint);
    _listScroll = value;
    if (attached) _listScroll.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color _panelColor;
  Color get panelColor => _panelColor;
  set panelColor(Color value) {
    if (value == _panelColor) return;
    _panelColor = value;
    markNeedsPaint();
  }

  double _sideMargin;
  double get sideMargin => _sideMargin;
  set sideMargin(double value) {
    if (value == _sideMargin) return;
    _sideMargin = value;
    markNeedsPaint();
  }

  double _quickTilesHeight;
  double get quickTilesHeight => _quickTilesHeight;
  set quickTilesHeight(double value) {
    if (value == _quickTilesHeight) return;
    _quickTilesHeight = value;
    markNeedsLayout();
  }

  bool _mediaActive;
  bool get mediaActive => _mediaActive;
  set mediaActive(bool value) {
    if (value == _mediaActive) return;
    _mediaActive = value;
    markNeedsLayout();
  }

  /// The quick tiles' bottom (with an active media player) and the stack's
  /// top under them, from the last layout.
  double _quickBottom = 0;
  double _stackTop = 0;

  /// The panel behind the notifications, for the current fractions.
  RRect _edge = RRect.zero;
  double _panelAlpha = 0;
  bool _quickTilesClear = false;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ShadeStackParentData) {
      child.parentData = _ShadeStackParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _panel.addListener(markNeedsPaint);
    _qs.addListener(markNeedsPaint);
    _pullsBoth.addListener(markNeedsPaint);
    _listScroll.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _panel.removeListener(markNeedsPaint);
    _qs.removeListener(markNeedsPaint);
    _pullsBoth.removeListener(markNeedsPaint);
    _listScroll.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as _ShadeStackParentData;
      data.clipLayer.layer = null;
      data.opacityLayer.layer = null;
      data.transformLayer.layer = null;
    }
    super.dispose();
  }

  RenderBox? _child(ShadePart part) {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if ((child.parentData! as _ShadeStackParentData).part == part) {
        return child;
      }
    }
    return null;
  }

  double _height(ShadePart part) => _child(part)?.size.height ?? 0;
  double _width(ShadePart part) => _child(part)?.size.width ?? 0;

  @override
  bool get isRepaintBoundary => true;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    size = constraints.biggest;
    final width = size.width;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final part = (child.parentData! as _ShadeStackParentData).part;
      switch (part) {
        // The header's parts take their own width.
        case ShadePart.clock ||
            ShadePart.date ||
            ShadePart.icons ||
            ShadePart.carrier:
          child.layout(
            BoxConstraints.loose(Size(width, 120)),
            parentUsesSize: true,
          );
        case ShadePart.list:
          break;
        default:
          child.layout(
            BoxConstraints.tightFor(width: width),
            parentUsesSize: true,
          );
      }
    }
    _quickBottom =
        _Places.quickGridTop +
        quickTilesHeight +
        (mediaActive ? _height(ShadePart.media) : 0);
    _stackTop = _quickBottom + _Places.stackGap;
    _child(ShadePart.list)?.layout(
      // The list starts at the screen's top and its rows at the stack's: it
      // is told where by the smallest height it may have.
      BoxConstraints(
        minWidth: width,
        maxWidth: width,
        minHeight: math.max(0, size.height - _stackTop),
        maxHeight: size.height,
      ),
      parentUsesSize: true,
    );
    onTravel(size.height + _Places.stackPastBottom - _stackTop);
  }

  /// Where each part is, how big and how visible at the current fractions.
  void _place() {
    final e = qs.value.clamp(0.0, 1.0);
    final p = panel.value.clamp(0.0, 1.0);
    final width = size.width;
    final anchor = lerpDouble(_Places.quickGridTop, _Places.fullGridTop, e)!;
    final contentAlpha = ((e - 0.43) / 0.57).clamp(0.0, 1.0);
    final footerAlpha = ((e - 0.9) / 0.1).clamp(0.0, 1.0);
    // The stack rests at restTop; on the first pull its top comes down
    // from the screen's top with the panel (AOSP's stackY), uncovering the
    // quick settings, which are cut there and neither move nor fade.
    final restTop = lerpDouble(
      _stackTop,
      size.height + _Places.stackPastBottom,
      e,
    )!;
    final both = _pullsBoth.value;
    final stackTop = both
        ? (restTop - _Places.panelPadding) * p
        : e > 0
        ? restTop - _Places.panelPadding
        : (_stackTop - _Places.panelPadding) * p;
    // AOSP's getEdgePosition: the panel of the notifications scrolls up over
    // the quick tiles, to the header.
    final edge = math.max(
      _Places.quickGridTop * p,
      stackTop - _listScroll.offset,
    );
    final radius =
        _Places.panelRadius * math.min(edge / _Places.panelRadius, 1);
    _edge = RRect.fromRectAndCorners(
      Rect.fromLTRB(
        -_sideMargin,
        edge,
        width + _sideMargin,
        math.max(edge, size.height + _Places.panelRadius),
      ),
      topLeft: Radius.circular(math.max(0, radius)),
      topRight: Radius.circular(math.max(0, radius)),
    );
    _panelAlpha = p;
    _quickTilesClear = e <= 0 && edge >= _quickBottom;
    final headerAlpha = ShadeReveal.headerAlpha(p);
    final gridHeight = _height(ShadePart.grid);
    final fullMediaTop =
        _Places.fullGridTop +
        gridHeight +
        _height(ShadePart.gridFooter) +
        _Places.mediaGap;
    final quickMediaTop =
        _Places.quickGridTop + quickTilesHeight + _Places.mediaGap;

    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as _ShadeStackParentData;
      final h = child.size.height;
      final w = child.size.width;
      var x = 0.0;
      var y = 0.0;
      var scale = 1.0;
      var alpha = 1.0;
      _ShadeClip clip = _ShadeClip.abovePanel;
      var hittable = true;
      switch (data.part) {
        case ShadePart.clock:
          // Scaled about its left edge and vertical centre.
          final centre = lerpDouble(
            _Places.quickRowCentre,
            _Places.clockCentre,
            e,
          )!;
          scale = lerpDouble(1, _Places.clockScale, e)!;
          y = centre - h * scale / 2;
          clip = _ShadeClip.none;
          hittable = false;
        case ShadePart.date:
          final fromX = _width(ShadePart.clock) + _Places.dateAfterClock;
          x = lerpDouble(fromX, 0, _keyframed(e, _hiddenX))!;
          final centre = lerpDouble(
            _Places.quickRowCentre,
            _Places.dateCentre,
            _keyframed(e, _hiddenY),
          )!;
          y = centre - h / 2;
          alpha = _keyframed(e, _hiddenAlpha);
          clip = _ShadeClip.none;
          hittable = false;
        case ShadePart.icons:
          x = width - w;
          final centre = lerpDouble(
            _Places.quickRowCentre,
            _Places.dateCentre,
            _keyframed(e, _hiddenY),
          )!;
          y = centre - h / 2;
          alpha = _keyframed(e, _hiddenAlpha);
          clip = _ShadeClip.none;
          hittable = false;
        case ShadePart.carrier:
          x = width - w;
          final centre = lerpDouble(
            _Places.quickRowCentre,
            _Places.carrierCentre,
            e,
          )!;
          y = centre - h / 2;
          alpha = _keyframed(e, _carrierAlpha);
          clip = _ShadeClip.none;
          hittable = false;
        case ShadePart.slider:
          y = anchor - _Places.sliderAboveGrid;
          alpha = contentAlpha;
          hittable = alpha > 0.5;
        case ShadePart.grid:
          // Its shared rows stay opaque; the others fade with the content
          // inside the grid (QsTileMotion).
          y = anchor;
        case ShadePart.gridFooter:
          y = anchor + gridHeight;
          alpha = contentAlpha;
          hittable = alpha > 0.5;
        case ShadePart.media:
          // The child carries the gap above it.
          if (mediaActive) {
            y = lerpDouble(quickMediaTop, fullMediaTop, e)! - _Places.mediaGap;
          } else {
            y = fullMediaTop - _Places.fullGridTop + anchor - _Places.mediaGap;
            alpha = contentAlpha;
            hittable = alpha > 0.5;
          }
        case ShadePart.footer:
          y = size.height - _Places.footerBottom - h;
          alpha = footerAlpha;
          clip = _ShadeClip.none;
          hittable = e >= 0.99;
        case ShadePart.list:
          // The list rises to its place by itself (NotificationShadeList).
          y = restTop - _stackTop;
          // AOSP hides the stack until a two-finger pull is fully open.
          alpha = both ? 0 : AndroidStackExpansion.alpha(p);
          clip = _ShadeClip.inPanel;
          hittable = e <= 0.01;
        case null:
          alpha = 0;
      }
      if (data.part
          case ShadePart.clock ||
              ShadePart.date ||
              ShadePart.icons ||
              ShadePart.carrier) {
        alpha *= headerAlpha;
      }
      data
        ..place = Offset(x, y)
        ..scale = scale
        ..clip = clip
        ..alpha = alpha
        ..hittable = hittable && alpha > 0;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _place();
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as _ShadeStackParentData;
      final alpha = (data.alpha * 255).round();
      final bounds = data.place & (child.size * data.scale);
      // Wholly on the wrong side of the edge, or on the right one.
      final hidden =
          data.clip == _ShadeClip.abovePanel && _edge.top <= bounds.top;
      final whole =
          data.clip == _ShadeClip.none ||
          (data.clip == _ShadeClip.abovePanel && bounds.bottom <= _edge.top);
      if (data.part == ShadePart.list) _paintPanel(context, offset);
      if (alpha <= 0 || hidden) {
        data.clipLayer.layer = null;
        data.outsideLayer.layer = null;
        data.aboveLayer.layer = null;
        data.opacityLayer.layer = null;
        data.transformLayer.layer = null;
        continue;
      }
      void faded(PaintingContext context, Offset offset) {
        if (alpha >= 255) {
          data.opacityLayer.layer = null;
          context.paintChild(child!, offset);
          return;
        }
        data.opacityLayer.layer = context.pushOpacity(
          offset,
          alpha,
          (context, offset) => context.paintChild(child!, offset),
          oldLayer: data.opacityLayer.layer,
        );
      }

      void placed(PaintingContext context, Offset offset) {
        final at = offset + data.place;
        if (data.scale == 1) {
          data.transformLayer.layer = null;
          faded(context, at);
          return;
        }
        final transform = Matrix4.translationValues(at.dx, at.dy, 0)
          ..scaleByDouble(data.scale, data.scale, 1, 1);
        data.transformLayer.layer = context.pushTransform(
          needsCompositing,
          Offset.zero,
          transform,
          faded,
          oldLayer: data.transformLayer.layer,
        );
      }

      if (whole) {
        data.clipLayer.layer = null;
        data.outsideLayer.layer = null;
        data.aboveLayer.layer = null;
        placed(context, offset);
      } else if (data.clip == _ShadeClip.inPanel) {
        data.outsideLayer.layer = null;
        data.clipLayer.layer = context.pushClipRRect(
          needsCompositing,
          offset,
          _edge.outerRect,
          _edge,
          placed,
          oldLayer: data.clipLayer.layer,
        );
      } else if (_quickTilesClear) {
        // The edge's corners are below everything that shows.
        data.outsideLayer.layer = null;
        data.aboveLayer.layer = context.pushClipRect(
          needsCompositing,
          offset,
          Rect.fromLTRB(-size.width, -size.height, size.width * 2, _edge.top),
          placed,
          oldLayer: data.aboveLayer.layer,
        );
      } else {
        data.aboveLayer.layer = null;
        final far = Rect.fromLTRB(
          -size.width,
          -size.height,
          size.width * 2,
          _edge.bottom,
        );
        data.outsideLayer.layer = context.pushClipPath(
          needsCompositing,
          offset,
          far,
          Path()
            ..fillType = PathFillType.evenOdd
            ..addRect(far)
            ..addRRect(_edge),
          placed,
          oldLayer: data.outsideLayer.layer,
        );
      }
    }
  }

  void _paintPanel(PaintingContext context, Offset offset) {
    if (_panelAlpha <= 0 || _edge.top >= size.height) return;
    context.canvas.drawRRect(
      _edge.shift(offset),
      Paint()
        ..color = _panelColor.withValues(alpha: _panelColor.a * _panelAlpha),
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    _place();
    for (var child = lastChild; child != null; child = childBefore(child)) {
      final data = child.parentData! as _ShadeStackParentData;
      if (!data.hittable) continue;
      if (data.clip == _ShadeClip.abovePanel && position.dy >= _edge.top) {
        continue;
      }
      if (data.clip == _ShadeClip.inPanel && position.dy < _edge.top) continue;
      final hit = result.addWithPaintOffset(
        offset: data.place,
        position: position,
        hitTest: (result, transformed) =>
            child!.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final data = child.parentData! as _ShadeStackParentData;
    transform
      ..translateByDouble(data.place.dx, data.place.dy, 0, 1)
      ..scaleByDouble(data.scale, data.scale, 1, 1);
  }
}
