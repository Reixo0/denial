import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'notification_shade_list.dart' show AndroidStackExpansion;
import 'shade_expansion_motion.dart';

/// The parts of the shade's column, top to bottom.
enum ShadePart {
  /// The first pull's status row (time, date, icons).
  collapsedHeader,

  /// The full quick settings' header (large clock, date, operator).
  expandedHeader,

  /// The brightness slider, which grows in above the tiles.
  slider,

  /// The tile grid at its full height.
  grid,

  /// The grid's footer row (page dots, edit).
  gridFooter,

  /// The media player.
  media,

  /// The footer actions (settings, power).
  footer,

  /// The notification stack.
  list,
}

/// Places one part of the shade's column ([ShadePart]).
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

/// The shade's column laid out as Android's views move: each part is laid
/// out once at its own size, and the panel and quick-settings fractions only
/// move, clip and fade them while a finger or a fling drives the shade
/// (View translation, clip bounds and alpha). Nothing is built or laid out
/// again during the motion, and each part keeps its own cached layer.
///
/// Geometry, in this box's units (the shade's dp):
/// the header grows from [collapsedHeader] to [expandedHeader]; under it the
/// slider shows its bottom part, then [gap] and the grid cut from
/// [firstGridHeight] to its full height with its footer row, then the media
/// player (whole when [mediaActive], else growing with the quick settings),
/// the footer actions, and [listGap] above the notification stack, which
/// keeps the height it has under the quick tiles (AOSP moves the stack with
/// the quick settings' bottom, calculateNotificationsTopPadding).
class ShadeStackLayout extends MultiChildRenderObjectWidget {
  const ShadeStackLayout({
    super.key,
    required this.panel,
    required this.qs,
    required this.collapsedHeader,
    required this.expandedHeader,
    required this.gap,
    required this.listGap,
    required this.firstGridHeight,
    required this.mediaActive,
    required this.onTravel,
    super.children,
  });

  final Animation<double> panel;
  final Animation<double> qs;
  final double collapsedHeader;
  final double expandedHeader;
  final double gap;
  final double listGap;
  final double firstGridHeight;
  final bool mediaActive;

  /// The distance the quick settings' bottom moves from the quick tiles to
  /// the full quick settings, after each layout.
  final ValueChanged<double> onTravel;

  @override
  RenderShadeStack createRenderObject(BuildContext context) => RenderShadeStack(
    panel: panel,
    qs: qs,
    collapsedHeader: collapsedHeader,
    expandedHeader: expandedHeader,
    gap: gap,
    listGap: listGap,
    firstGridHeight: firstGridHeight,
    mediaActive: mediaActive,
    onTravel: onTravel,
  );

  @override
  void updateRenderObject(BuildContext context, RenderShadeStack renderObject) {
    renderObject
      ..panel = panel
      ..qs = qs
      ..collapsedHeader = collapsedHeader
      ..expandedHeader = expandedHeader
      ..gap = gap
      ..listGap = listGap
      ..firstGridHeight = firstGridHeight
      ..mediaActive = mediaActive
      ..onTravel = onTravel;
  }
}

class _ShadeStackParentData extends ContainerBoxParentData<RenderBox> {
  ShadePart? part;

  /// Where the part is drawn and what of it shows, for the current
  /// fractions (paint and hit testing).
  Offset place = Offset.zero;
  Rect clip = Rect.zero;
  double alpha = 1;
  bool hittable = false;

  final clipLayer = LayerHandle<ClipRectLayer>();
  final opacityLayer = LayerHandle<OpacityLayer>();
}

/// The geometry of one frame of the shade.
class _Frame {
  _Frame(RenderShadeStack stack) {
    final e = stack.qs.value.clamp(0.0, 1.0);
    final p = stack.panel.value.clamp(0.0, 1.0);
    final m = stack._mediaHeight;
    final quickTiles = stack._quickTilesBottom;
    final c = stack.collapsedHeader;
    final x = stack.expandedHeader;
    headerHeight = c + (x - c) * e;
    sliderShown = stack._sliderHeight * e;
    gridTop = headerHeight + sliderShown + stack.gap;
    gridShown =
        stack.firstGridHeight +
        (stack._fullGridHeight - stack.firstGridHeight) * e;
    mediaTop = gridTop + gridShown;
    mediaShown = m * (stack.mediaActive ? 1 : e);
    footerTop = mediaTop + mediaShown;
    footerShown = stack._footerHeight * e;
    listTop = footerTop + footerShown + stack.listGap;
    // AOSP: the quick settings come down a little with the pull
    // (getHeaderTranslation, QS_PARALLAX_AMOUNT) and fade in with the
    // shade's content (getContentAlpha).
    parallax = -AospShadeInterpolation.qsParallax * quickTiles * (1 - p);
    contentAlpha = AospShadeInterpolation.contentAlpha(p);
    listAlpha = AndroidStackExpansion.alpha(p);
    // AOSP: the QS content fades in from 0.43, the footer actions from 0.9.
    qsAlpha = ((e - 0.43) / 0.57).clamp(0.0, 1.0);
    footerAlpha = ((e - 0.9) / 0.1).clamp(0.0, 1.0);
    expansion = e;
  }

  late final double headerHeight;
  late final double sliderShown;
  late final double gridTop;
  late final double gridShown;
  late final double mediaTop;
  late final double mediaShown;
  late final double footerTop;
  late final double footerShown;
  late final double listTop;
  late final double parallax;
  late final double contentAlpha;
  late final double listAlpha;
  late final double qsAlpha;
  late final double footerAlpha;
  late final double expansion;
}

class RenderShadeStack extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ShadeStackParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ShadeStackParentData> {
  RenderShadeStack({
    required this._panel,
    required this._qs,
    required this._collapsedHeader,
    required this._expandedHeader,
    required this._gap,
    required this._listGap,
    required this._firstGridHeight,
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

  double _collapsedHeader;
  double get collapsedHeader => _collapsedHeader;
  set collapsedHeader(double value) {
    if (value == _collapsedHeader) return;
    _collapsedHeader = value;
    markNeedsLayout();
  }

  double _expandedHeader;
  double get expandedHeader => _expandedHeader;
  set expandedHeader(double value) {
    if (value == _expandedHeader) return;
    _expandedHeader = value;
    markNeedsLayout();
  }

  double _gap;
  double get gap => _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  double _listGap;
  double get listGap => _listGap;
  set listGap(double value) {
    if (value == _listGap) return;
    _listGap = value;
    markNeedsLayout();
  }

  double _firstGridHeight;
  double get firstGridHeight => _firstGridHeight;
  set firstGridHeight(double value) {
    if (value == _firstGridHeight) return;
    _firstGridHeight = value;
    markNeedsLayout();
  }

  bool _mediaActive;
  bool get mediaActive => _mediaActive;
  set mediaActive(bool value) {
    if (value == _mediaActive) return;
    _mediaActive = value;
    markNeedsLayout();
  }

  // Part sizes from the last layout.
  double _sliderHeight = 0;
  double _gridHeight = 0;
  double _fullGridHeight = 0;
  double _mediaHeight = 0;
  double _footerHeight = 0;
  double _quickTilesBottom = 0;

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
  }

  @override
  void detach() {
    _panel.removeListener(markNeedsPaint);
    _qs.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void dispose() {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as _ShadeStackParentData;
      data.clipLayer.layer = null;
      data.opacityLayer.layer = null;
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
    double layout(ShadePart part, {double? height}) {
      final child = _child(part);
      if (child == null) return 0;
      child.layout(
        height == null
            ? BoxConstraints.tightFor(width: width)
            : BoxConstraints.tightFor(width: width, height: height),
        parentUsesSize: true,
      );
      return child.size.height;
    }

    layout(ShadePart.collapsedHeader, height: collapsedHeader);
    layout(ShadePart.expandedHeader, height: expandedHeader);
    _sliderHeight = layout(ShadePart.slider);
    _gridHeight = layout(ShadePart.grid);
    _fullGridHeight = _gridHeight + layout(ShadePart.gridFooter);
    _mediaHeight = layout(ShadePart.media);
    _footerHeight = layout(ShadePart.footer);
    _quickTilesBottom =
        collapsedHeader +
        gap +
        firstGridHeight +
        (mediaActive ? _mediaHeight : 0);
    layout(
      ShadePart.list,
      height: math.max(0, size.height - _quickTilesBottom - listGap),
    );
    onTravel(
      expandedHeader -
          collapsedHeader +
          _sliderHeight +
          _fullGridHeight -
          firstGridHeight +
          (mediaActive ? 0 : _mediaHeight) +
          _footerHeight,
    );
  }

  /// Where each part is and how much of it shows at the current fractions.
  void _place() {
    final f = _Frame(this);
    final width = size.width;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as _ShadeStackParentData;
      final h = child.size.height;
      double top;
      double clipTop;
      double clipBottom;
      double alpha;
      bool hittable;
      switch (data.part) {
        case ShadePart.collapsedHeader:
          top = 0;
          clipTop = 0;
          clipBottom = f.headerHeight;
          alpha = (1 - f.expansion * 2).clamp(0.0, 1.0);
          hittable = false;
        case ShadePart.expandedHeader:
          // Its content sits at its bottom, which follows the header's.
          top = f.headerHeight - h;
          clipTop = 0;
          clipBottom = f.headerHeight;
          alpha = ((f.expansion - 0.4) / 0.6).clamp(0.0, 1.0);
          hittable = false;
        case ShadePart.slider:
          // Grows in above the tiles, its bottom part first.
          top = f.headerHeight + f.sliderShown - h;
          clipTop = f.headerHeight;
          clipBottom = f.headerHeight + f.sliderShown;
          alpha = f.qsAlpha;
          hittable = alpha > 0.5;
        case ShadePart.grid:
          top = f.gridTop;
          clipTop = f.gridTop;
          clipBottom = f.gridTop + f.gridShown;
          alpha = 1;
          hittable = true;
        case ShadePart.gridFooter:
          top = f.gridTop + _gridHeight;
          clipTop = f.gridTop;
          clipBottom = f.gridTop + f.gridShown;
          alpha = f.qsAlpha;
          hittable = alpha > 0.5;
        case ShadePart.media:
          top = f.mediaTop;
          clipTop = f.mediaTop;
          clipBottom = f.mediaTop + f.mediaShown;
          alpha = mediaActive ? 1 : f.qsAlpha;
          hittable = alpha > 0.5;
        case ShadePart.footer:
          top = f.footerTop;
          clipTop = f.footerTop;
          clipBottom = f.footerTop + f.footerShown;
          alpha = f.footerAlpha;
          hittable = f.expansion >= 0.99;
        case ShadePart.list:
          top = f.listTop;
          clipTop = f.listTop;
          clipBottom = size.height;
          alpha = f.listAlpha;
          hittable = f.expansion <= 0.01;
        case null:
          top = 0;
          clipTop = 0;
          clipBottom = 0;
          alpha = 0;
          hittable = false;
      }
      if (data.part != ShadePart.list) {
        top += f.parallax;
        clipTop += f.parallax;
        clipBottom += f.parallax;
        alpha *= f.contentAlpha;
      }
      data
        ..place = Offset(0, top)
        ..clip = Rect.fromLTRB(0, clipTop, width, math.max(clipTop, clipBottom))
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
      if (alpha <= 0 || data.clip.isEmpty) {
        data.clipLayer.layer = null;
        data.opacityLayer.layer = null;
        continue;
      }
      data.clipLayer.layer = context.pushClipRect(
        needsCompositing,
        offset,
        data.clip,
        (context, offset) {
          if (alpha >= 255) {
            data.opacityLayer.layer = null;
            context.paintChild(child!, offset + data.place);
            return;
          }
          data.opacityLayer.layer = context.pushOpacity(
            offset,
            alpha,
            (context, offset) =>
                context.paintChild(child!, offset + data.place),
            oldLayer: data.opacityLayer.layer,
          );
        },
        oldLayer: data.clipLayer.layer,
      );
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    _place();
    for (var child = lastChild; child != null; child = childBefore(child)) {
      final data = child.parentData! as _ShadeStackParentData;
      if (!data.hittable || !data.clip.contains(position)) continue;
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
    transform.translateByDouble(data.place.dx, data.place.dy, 0, 1);
  }
}
