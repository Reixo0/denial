import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'shade_backdrop_scene.dart';

/// Android's notification stack while the shade opens or closes, from AOSP
/// StackScrollAlgorithm and NotificationStackScrollLayout. [f] is the
/// shade's expansion fraction.
abstract final class AndroidStackExpansion {
  /// How much of each row's height, and of the gap below it, shows:
  /// the interpolated stack height over its end height, from
  /// `StackScrollAlgorithm.START_FRACTION` (0.5) to 1.
  static double squish(double f) =>
      LockShadeHandover.active ? 1 : 0.5 + 0.5 * f.clamp(0.0, 1.0);

  /// The rows' alpha: `ShadeInterpolation.getContentAlpha`.
  static double alpha(double f) {
    final mapped = ((f - 0.3) / 0.7).clamp(0.0, 1.0);
    final eased = mapped * 1.2 - 0.2;
    if (eased <= 0) return 0;
    final rest = 1 - eased;
    return 1 - 0.5 * (1 - math.cos(math.pi * rest * rest));
  }
}

/// The shade opening over the lock screen (LockscreenShadeTransitionController
/// and the keyguard's StackScrollAlgorithm): the lock screen's stack is the
/// shade's, so its cards neither shrink nor fade. They move from where the
/// lock screen shows them to the shade's place (QuickSettingsControllerImpl's
/// transition position, FAST_OUT_SLOW_IN), and what was only an icon on the
/// shelf fades in as on any opening. It holds from the first frame the shade
/// leaves closed until it is fully open, or closed again after springing
/// back; past that the shade's own rules give the same places.
abstract final class LockShadeHandover {
  /// The lock screen's stack top (its first card, or the shelf), in global
  /// logical pixels; null while it shows nothing.
  static double? lockTop;

  /// The groups with a card on the lock screen.
  static Set<String> kept = const <String>{};

  /// The lock screen's stack is up under the shade (it says so itself: the
  /// shade may not have rebuilt since the phone locked).
  static bool locked = false;

  /// The card the finger went down on, on the lock screen
  /// ([RemoteNotificationPull.key]).
  static Object? pressed;

  static bool get active => _active;
  static bool _active = false;
  static bool _closed = true;

  /// The shade covers the lock screen's stack: it waits, as it was, until
  /// the shade has closed (filtering is off while the shade is open).
  static final ValueNotifier<bool> covering = ValueNotifier<bool>(false);

  /// The last opening sprang back to the lock screen inside the handover:
  /// its cards are where the lock screen's are.
  static bool get returned => _returned;
  static bool _returned = false;

  /// Follows the shade's expansion.
  static void follow(double p) {
    if (p <= 0) {
      _returned = _active;
      _active = false;
      _closed = true;
      covering.value = false;
      return;
    }
    if (_closed) {
      _closed = false;
      _active = locked && lockTop != null;
      _returned = false;
      covering.value = true;
    }
    if (p >= 1) _active = false;
  }

  /// How far the cards have gone from the lock screen's place.
  static double travel(double p) =>
      Curves.fastOutSlowIn.transform(p.clamp(0.0, 1.0));
}

/// A normal, lazily laid-out list with expansion-aware vertical positions.
/// While [progress] is below 1 the rows sit at their positions times
/// [AndroidStackExpansion.squish] (the rows clip themselves to the same
/// fraction), and the whole stack rises toward the top of the screen as
/// Android's `stackY` does. [entrance] invalidates the cached silhouettes.
/// Neither animation rebuilds or resizes notification cards or scroll
/// extent.
///
/// Rows that overlap while the stack compresses stack by direction: opening
/// from closed, each row lies over the ones below it; closing from open, the
/// last row lies on top, so the stack gathers upward under it. The order only
/// changes at rest, fully open or closed, where no rows overlap.
class NotificationShadeList extends SliverList {
  const NotificationShadeList({
    required super.delegate,
    required this.progress,
    required this.entrance,
    this.topPadding = 0,
    this.opaqueRows = false,
    this.onRowsMoved,
    this.onExtent,
    super.key,
  });

  final Animation<double> progress;
  final Animation<double> entrance;

  /// The padding above this sliver: the stack's resting top on the screen,
  /// where the list starts.
  final double topPadding;

  /// The rows paint opaque material. Once [entrance] has revealed them they
  /// hide one another by paint order alone, without per-row clips.
  final bool opaqueRows;

  /// Called whenever rows may have moved without this list repainting them:
  /// after a layout, and for a descendant transform such as a dismissal.
  /// Retained glass slices in the rows follow through it.
  final VoidCallback? onRowsMoved;

  /// Told after a layout where the rows end, from the list's top: its
  /// bottom when more than fit.
  final ValueChanged<double>? onExtent;

  /// Descendant paint transforms (for example a sideways dismissal) also move
  /// the silhouette, even when a retained row does not repaint this sliver.
  static void invalidateOcclusion(BuildContext context) {
    final list = context
        .findAncestorRenderObjectOfType<_RenderNotificationShadeList>();
    list?.markNeedsPaint();
    list?.onRowsMoved?.call();
  }

  /// How far below the list's top [box], somewhere inside a row, rests:
  /// whatever the shade's expansion, on screen or not.
  static double? restingTop(RenderBox box) {
    RenderObject child = box;
    while (true) {
      final parent = child.parent;
      if (parent == null) return null;
      if (parent is _RenderNotificationShadeList) {
        final row = child as RenderBox;
        return parent._restingTop(row) +
            box.localToGlobal(Offset.zero, ancestor: row).dy;
      }
      child = parent;
    }
  }

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _RenderNotificationShadeList(
          progress,
          entrance,
          childManager: context as SliverMultiBoxAdaptorElement,
        )
        ..topPadding = topPadding
        ..opaqueRows = opaqueRows
        ..onRowsMoved = onRowsMoved
        ..onExtent = onExtent;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSliverList renderObject,
  ) {
    (renderObject as _RenderNotificationShadeList)
      ..progress = progress
      ..entrance = entrance
      ..topPadding = topPadding
      ..opaqueRows = opaqueRows
      ..onRowsMoved = onRowsMoved
      ..onExtent = onExtent;
  }
}

class _RenderNotificationShadeList extends RenderSliverList {
  _RenderNotificationShadeList(
    this._progress,
    this._entrance, {
    required super.childManager,
  });

  Animation<double> _progress;
  Animation<double> _entrance;
  VoidCallback? onRowsMoved;
  ValueChanged<double>? onExtent;
  bool _opaqueRows = false;
  set opaqueRows(bool value) {
    if (value == _opaqueRows) return;
    _opaqueRows = value;
    markNeedsPaint();
  }

  final _surfaces = <_RenderNotificationShadeSurface>{};
  final _clips = <RenderBox, LayerHandle<ClipPathLayer>>{};
  List<_NotificationPaintRow>? _cachedRows;
  RenderShadeBackdropScene? _scene;
  double _restingOpen = 0;
  bool _lastOnTop = false;

  @override
  void markNeedsPaint() {
    _cachedRows = null;
    _lockTopRead = false;
    super.markNeedsPaint();
    if (_scene?.attached ?? false) _scene!.markNeedsPaint();
  }

  @override
  void performLayout() {
    super.performLayout();
    final live = <RenderBox>{};
    for (var child = firstChild; child != null; child = childAfter(child)) {
      live.add(child);
    }
    for (final child
        in _clips.keys.where((child) => !live.contains(child)).toList()) {
      _clips.remove(child)!.layer = null;
    }
    _cachedRows = null;
    _lockTopRead = false;
    onExtent?.call(
      math.min(
        constraints.viewportMainAxisExtent,
        _topPadding + (geometry?.scrollExtent ?? 0),
      ),
    );
    onRowsMoved?.call();
  }

  @override
  bool paintsChild(RenderBox child) {
    if (!super.paintsChild(child) || !child.hasSize) return false;
    final y = super.childMainAxisPosition(child);
    return y < constraints.remainingPaintExtent && y + child.size.height > 0;
  }

  @override
  void dispose() {
    for (final clip in _clips.values) {
      clip.layer = null;
    }
    _clips.clear();
    super.dispose();
  }

  set progress(Animation<double> value) {
    if (identical(value, _progress)) return;
    if (attached) _progress.removeListener(_motionChanged);
    _progress = value;
    if (attached) _progress.addListener(_motionChanged);
    _motionChanged();
  }

  set entrance(Animation<double> value) {
    if (identical(value, _entrance)) return;
    if (attached) _entrance.removeListener(_motionChanged);
    _entrance = value;
    if (attached) _entrance.addListener(_motionChanged);
    _motionChanged();
  }

  double get _open => _progress.value.clamp(0.0, 1.0);

  /// The lock screen's stack top in the list's own coordinates (from its
  /// top), for this frame.
  double? _lockTop;
  bool _lockTopRead = false;

  double? get _lockTopHere {
    if (_lockTopRead) return _lockTop;
    _lockTopRead = true;
    final global = LockShadeHandover.lockTop;
    final toHere = global == null
        ? null
        : Matrix4.tryInvert(getTransformTo(null));
    _lockTop = toHere == null
        ? null
        : MatrixUtils.transformPoint(toHere, Offset(0, global!)).dy +
              _sliverTop;
    return _lockTop;
  }

  double _topPadding = 0;
  set topPadding(double value) {
    if (value == _topPadding) return;
    _topPadding = value;
    markNeedsPaint();
  }

  /// How far this sliver starts below the list's top: the part of the
  /// padding above it that is not scrolled away.
  double get _sliverTop => math.max(
    0,
    constraints.viewportMainAxisExtent - constraints.remainingPaintExtent,
  );

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    RenderObject? ancestor = parent;
    while (ancestor != null && ancestor is! RenderShadeBackdropScene) {
      ancestor = ancestor.parent;
    }
    _scene = ancestor as RenderShadeBackdropScene?;
    _restingOpen = _open;
    _progress.addListener(_motionChanged);
    _entrance.addListener(_motionChanged);
  }

  @override
  void detach() {
    _progress.removeListener(_motionChanged);
    _entrance.removeListener(_motionChanged);
    _scene = null;
    super.detach();
  }

  void _motionChanged() {
    final open = _open;
    if (_restingOpen >= 1 && open < 1) {
      _lastOnTop = true;
    } else if (_restingOpen <= 0 && open > 0) {
      _lastOnTop = false;
    }
    _restingOpen = open;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  double _restingTop(RenderBox child) =>
      _sliverTop + super.childMainAxisPosition(child);

  @override
  double childMainAxisPosition(RenderBox child) {
    final open = _open;
    final base = super.childMainAxisPosition(child);
    if (open >= 1) return base;
    final top = _sliverTop;
    final lockTop = LockShadeHandover.active ? _lockTopHere : null;
    if (lockTop != null) {
      // Whole, from the lock screen's place to the shade's.
      final at =
          lockTop + (_topPadding - lockTop) * LockShadeHandover.travel(open);
      return at + (top + base - _topPadding) - top;
    }
    // From the list's top, which is the screen's: the stack starts at
    // expansion x its resting top (AOSP's stackY).
    return _topPadding * open +
        (top + base - _topPadding) * AndroidStackExpansion.squish(open) -
        top;
  }

  @override
  double childCrossAxisPosition(RenderBox child) => 0;

  List<_NotificationPaintRow> _paintRows() {
    // This shell list always runs downward. Keep the standard sliver's layout,
    // scroll extent and visible-child selection; only its paint regions differ.
    assert(constraints.axisDirection == AxisDirection.down);
    assert(constraints.growthDirection == GrowthDirection.forward);
    if (_cachedRows != null) return _cachedRows!;
    final rows = <_NotificationPaintRow>[];
    final byChild = <RenderObject, _NotificationPaintRow>{};
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final baseY = super.childMainAxisPosition(child);
      if (baseY >= constraints.remainingPaintExtent ||
          baseY + child.size.height <= 0) {
        continue;
      }
      final row = _NotificationPaintRow(
        child,
        Offset(childCrossAxisPosition(child), childMainAxisPosition(child)),
      );
      rows.add(row);
      byChild[child] = row;
    }
    // Opaque rows need no silhouettes once fully revealed: each one covers
    // whatever it overlaps, and only scene occluders still cut them.
    final rowsOcclude = !_opaqueRows || _entrance.value < 1;
    for (final surface
        in rowsOcclude
            ? _surfaces
            : const <_RenderNotificationShadeSurface>{}) {
      final row = byChild[surface._row];
      if (row == null || !surface.hasSize || surface.size.isEmpty) continue;
      row.silhouettes.add(
        surface.shape.transform(surface.getTransformTo(this).storage),
      );
    }
    // From the top of the stack down, each row subtracts only the silhouettes
    // above it that reach it, usually just its neighbor while the stack
    // compresses, so the boolean work stays linear in the row count. Non-zero
    // winding represents their union. A row that nothing reaches paints
    // without a clip.
    final covers = <(Path, Rect)>[
      for (final path in _scene?.occludersFor(this) ?? const <Path>[])
        (path, path.getBounds()),
    ];
    for (final row in _lastOnTop ? rows.reversed : rows) {
      final bounds = row.bounds;
      Path? covering;
      for (final (path, coverBounds) in covers) {
        if (!coverBounds.overlaps(bounds)) continue;
        (covering ??= Path()).addPath(path, Offset.zero);
      }
      if (covering != null) {
        row.visible = Path.combine(
          PathOperation.difference,
          Path()..addRect(bounds),
          covering,
        );
      }
      for (final silhouette in row.silhouettes) {
        covers.add((silhouette, silhouette.getBounds()));
      }
    }
    _cachedRows = rows;
    return rows;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_open <= 0) return;
    final rows = _paintRows();
    for (final row in _lastOnTop ? rows : rows.reversed) {
      final visible = row.visible;
      if (visible == null) {
        context.paintChild(row.child, offset + row.offset);
      } else if (!visible.getBounds().isEmpty) {
        final clip = _clips.putIfAbsent(
          row.child,
          () => LayerHandle<ClipPathLayer>(),
        );
        clip.layer = context.pushClipPath(
          needsCompositing,
          offset,
          row.bounds,
          visible,
          (context, offset) =>
              context.paintChild(row.child, offset + row.offset),
          oldLayer: clip.layer,
        );
      }
    }
  }

  @override
  bool hitTestChildren(
    SliverHitTestResult result, {
    required double mainAxisPosition,
    required double crossAxisPosition,
  }) {
    if (_open <= 0) return false;
    final point = Offset(crossAxisPosition, mainAxisPosition);
    final boxResult = BoxHitTestResult.wrap(result);
    final rows = _paintRows();
    for (final row in _lastOnTop ? rows.reversed : rows) {
      if (row.visible != null && !row.visible!.contains(point)) continue;
      if (hitTestBoxChild(
        boxResult,
        row.child,
        mainAxisPosition: mainAxisPosition,
        crossAxisPosition: crossAxisPosition,
      )) {
        return true;
      }
    }
    return false;
  }
}

class _NotificationPaintRow {
  _NotificationPaintRow(this.child, this.offset);

  final RenderBox child;
  final Offset offset;
  final silhouettes = <Path>[];
  Path? visible;
  Rect get bounds {
    var bounds = child.paintBounds.shift(offset);
    for (final silhouette in silhouettes) {
      bounds = bounds.expandToInclude(silhouette.getBounds());
    }
    return bounds;
  }
}

/// Marks the actual rounded card, excluding row gutters and external controls.
/// Its transform includes both the stack motion and a sideways dismissal.
class NotificationShadeSurface extends SingleChildRenderObjectWidget {
  const NotificationShadeSurface({
    required super.child,
    required this.borderRadius,
    super.key,
  });

  final BorderRadius borderRadius;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNotificationShadeSurface(borderRadius);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderNotificationShadeSurface).radius = borderRadius;
  }
}

class _RenderNotificationShadeSurface extends RenderProxyBox {
  _RenderNotificationShadeSurface(this._radius);

  BorderRadius _radius;
  _RenderNotificationShadeList? _owner;
  RenderObject? _row;
  Path? _shape;
  Path get shape =>
      _shape ??= Path()..addRRect(radius.toRRect(Offset.zero & size));

  @override
  void performLayout() {
    super.performLayout();
    _shape = null;
    _owner?.markNeedsPaint();
  }

  BorderRadius get radius => _radius;
  set radius(BorderRadius value) {
    if (_radius == value) return;
    _radius = value;
    _shape = null;
    _owner?.markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    RenderObject? ancestor = parent;
    _row = this;
    while (ancestor != null && ancestor is! _RenderNotificationShadeList) {
      _row = ancestor;
      ancestor = ancestor.parent;
    }
    _owner = ancestor as _RenderNotificationShadeList?;
    _owner?._surfaces.add(this);
    _owner?.markNeedsPaint();
  }

  @override
  void detach() {
    final owner = _owner;
    owner?._surfaces.remove(this);
    if (owner?.attached ?? false) owner!.markNeedsPaint();
    _owner = null;
    _row = null;
    super.detach();
  }
}
