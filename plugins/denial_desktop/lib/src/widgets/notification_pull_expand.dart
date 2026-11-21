import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'shade/shade_expansion_motion.dart' show aospShadeFling;

/// Android's ExpandHelper on one notification row: a downward pull grows
/// the row with the finger, 1:1, from its collapsed height to its natural
/// expanded one; let go, it settles open when it grew and the finger was
/// not moving up (`finishExpanding`), on FlingAnimationUtils' curve (0.3 s
/// at most), else closes again.
///
/// Two ways to grow:
///  * [expanded] null: the row grows into itself. [onStart] switches the
///    row to its expanded layout; the box shows it cut to the pulled height.
///  * [expanded] set: it builds what the row becomes (an open group), drawn
///    over the [child] and cross-faded in as the row grows, as a group's
///    children replace its summary lines.
///
/// [onSettled] says how it ended: true open, false closed.
///
/// With [expanded], [open] says which of the two the row shows at rest; a
/// change from outside (a tap on the group's pill or header) plays the same
/// cross-fade and height change, on the stack's standard animation (AOSP
/// StackStateAnimator: 360 ms, fast-out-slow-in).
class NotificationPullExpand extends StatefulWidget {
  const NotificationPullExpand({
    required this.enabled,
    required this.onSettled,
    required this.child,
    this.expanded,
    this.open = false,
    this.onStart,
    super.key,
  });

  final bool enabled;
  final WidgetBuilder? expanded;
  final bool open;
  final VoidCallback? onStart;
  final ValueChanged<bool> onSettled;
  final Widget child;

  @override
  State<NotificationPullExpand> createState() => _NotificationPullExpandState();
}

class _NotificationPullExpandState extends State<NotificationPullExpand>
    with SingleTickerProviderStateMixin {
  final _key = GlobalKey();

  /// How far the row has been pulled past its collapsed height.
  final _pulled = ValueNotifier<double>(0);
  late final AnimationController _settle = AnimationController(vsync: this);
  bool _active = false;
  double? _from;

  /// What the row shows at rest: the [NotificationPullExpand.expanded] one.
  late bool _shownOpen = widget.expanded != null && widget.open;

  static const _toggleDuration = Duration(milliseconds: 360);

  _RenderPullExpand? get _box =>
      _key.currentContext?.findRenderObject() as _RenderPullExpand?;

  @override
  void didUpdateWidget(NotificationPullExpand oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == null) {
      _shownOpen = false;
    } else if (widget.open != _shownOpen && !_active) {
      _toggle(widget.open);
    }
  }

  /// Plays the change to [open] that a tap asked for.
  void _toggle(bool open) {
    _settle.stop();
    // Closing starts grown to the full height; the box clamps it.
    _pulled.value = open ? 0 : double.infinity;
    _active = true;
    _from = null;
    // The heights are known once both are laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_active) return;
      final range = _box?.range ?? 0;
      if (range <= 0) {
        _rest(open);
        return;
      }
      final start = open ? 0.0 : range;
      final end = open ? range : 0.0;
      void follow() => _pulled.value =
          start + (end - start) * Curves.fastOutSlowIn.transform(_settle.value);
      _settle
        ..duration = _toggleDuration
        ..value = 0
        ..addListener(follow);
      _settle.forward().whenCompleteOrCancel(() {
        _settle.removeListener(follow);
        if (mounted) _rest(open);
      });
    });
  }

  void _rest(bool open) {
    setState(() {
      _active = false;
      _from = null;
      _shownOpen = widget.expanded != null && open;
    });
    _pulled.value = 0;
  }

  @override
  void dispose() {
    _settle.dispose();
    _pulled.dispose();
    super.dispose();
  }

  void _start(DragStartDetails details) {
    if (_active || _shownOpen) return;
    final box = _box;
    _from = box != null && box.hasSize ? box.size.height : null;
    HapticFeedback.lightImpact();
    _settle.stop();
    _pulled.value = 0;
    setState(() => _active = true);
    widget.onStart?.call();
  }

  void _update(DragUpdateDetails details) {
    if (!_active || _settle.isAnimating) return;
    final range = _box?.range ?? double.infinity;
    _pulled.value = (_pulled.value + details.delta.dy).clamp(0.0, range);
  }

  void _end(double velocity) {
    if (!_active || _settle.isAnimating) return;
    final range = _box?.range ?? 0;
    final current = math.min(_pulled.value, range);
    final open = range <= 0 || (current > 0 && velocity >= 0);
    final target = open ? range : 0.0;
    if (range <= 0 || target == current) {
      _finish(open);
      return;
    }
    final fling = aospShadeFling(
      distance: (target - current) / range,
      velocity: velocity / range,
      dp: 1 / range,
      maxSeconds: 0.3,
    );
    void follow() => _pulled.value =
        current + (target - current) * fling.curve.transform(_settle.value);
    _settle
      ..duration = fling.duration
      ..value = 0
      ..addListener(follow);
    _settle.forward().whenCompleteOrCancel(() {
      _settle.removeListener(follow);
      if (mounted) _finish(open);
    });
  }

  void _finish(bool open) {
    _rest(open);
    widget.onSettled(open);
  }

  @override
  Widget build(BuildContext context) {
    final expanded = widget.expanded;
    final target = expanded != null && (_active || _shownOpen)
        ? expanded(context)
        : null;
    final box = _PullExpandBox(
      key: _key,
      pulled: _pulled,
      active: _active,
      from: _from,
      showTarget: _shownOpen,
      children: <Widget>[widget.child, ?target],
    );
    if ((!widget.enabled || _shownOpen) && !_active) return box;
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        _PullDownRecognizer:
            GestureRecognizerFactoryWithHandlers<_PullDownRecognizer>(
              _PullDownRecognizer.new,
              (recognizer) => recognizer
                ..onStart = _start
                ..onUpdate = _update
                ..onEnd = ((details) => _end(details.primaryVelocity ?? 0))
                ..onCancel = (() => _end(0)),
            ),
      },
      child: box,
    );
  }
}

/// A vertical drag that only starts downward, so the list still scrolls up
/// from a row.
class _PullDownRecognizer extends VerticalDragGestureRecognizer {
  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) => globalDistanceMoved > computeHitSlop(pointerDeviceKind, gestureSettings);
}

class _PullExpandBox extends MultiChildRenderObjectWidget {
  const _PullExpandBox({
    required this.pulled,
    required this.active,
    required this.from,
    required this.showTarget,
    required super.children,
    super.key,
  });

  final ValueNotifier<double> pulled;
  final bool active;
  final double? from;

  /// At rest, show the second child (the open row) instead of the first.
  final bool showTarget;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPullExpand(
    pulled,
    active: active,
    from: from,
    showTarget: showTarget,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderPullExpand box) {
    box
      ..pulled = pulled
      ..active = active
      ..from = from
      ..showTarget = showTarget;
  }
}

class _PullExpandParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPullExpand extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PullExpandParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PullExpandParentData> {
  _RenderPullExpand(
    this._pulled, {
    required this._active,
    required this._from,
    required this._showTarget,
  });

  bool _showTarget;
  set showTarget(bool value) {
    if (value == _showTarget) return;
    _showTarget = value;
    markNeedsLayout();
  }

  /// The child shown at rest.
  RenderBox get _resting {
    final target = _target;
    return _showTarget && target != null ? target : firstChild!;
  }

  ValueNotifier<double> _pulled;
  set pulled(ValueNotifier<double> value) {
    if (identical(value, _pulled)) return;
    if (attached) _pulled.removeListener(markNeedsLayout);
    _pulled = value;
    if (attached) _pulled.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  bool _active;
  set active(bool value) {
    if (value == _active) return;
    _active = value;
    markNeedsLayout();
  }

  double? _from;
  set from(double? value) {
    if (value == _from) return;
    _from = value;
    markNeedsLayout();
  }

  /// How far the row can grow, from the last layout.
  double range = 0;

  /// 0 collapsed, 1 grown to the expanded height.
  double _fraction = 0;

  final _clip = LayerHandle<ClipRectLayer>();
  final _fadeOut = LayerHandle<OpacityLayer>();
  final _fadeIn = LayerHandle<OpacityLayer>();

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PullExpandParentData) {
      child.parentData = _PullExpandParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _pulled.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _pulled.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  void dispose() {
    _clip.layer = null;
    _fadeOut.layer = null;
    _fadeIn.layer = null;
    super.dispose();
  }

  RenderBox? get _target => childCount > 1 ? lastChild : null;

  @override
  void performLayout() {
    final loose = BoxConstraints(
      minWidth: constraints.minWidth,
      maxWidth: constraints.maxWidth,
    );
    final child = firstChild!;
    child.layout(loose, parentUsesSize: true);
    final target = _target;
    target?.layout(loose, parentUsesSize: true);
    if (!_active) {
      range = 0;
      _fraction = 0;
      size = constraints.constrain(_resting.size);
      return;
    }
    final start = target != null
        ? child.size.height
        : _from ?? child.size.height;
    final end = (target ?? child).size.height;
    range = math.max(0, end - start);
    final grown = math.min(_pulled.value, range);
    _fraction = range <= 0 ? 1 : grown / range;
    size = constraints.constrain(Size(child.size.width, start + grown));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = firstChild!;
    final target = _target;
    if (!_active) {
      _clip.layer = null;
      _fadeOut.layer = null;
      _fadeIn.layer = null;
      context.paintChild(_resting, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) {
        if (target == null) {
          context.paintChild(child, offset);
          return;
        }
        final out = ((1 - _fraction) * 255).round();
        final into = (_fraction * 255).round();
        _fadeOut.layer = out <= 0
            ? null
            : context.pushOpacity(
                offset,
                out,
                (context, offset) => context.paintChild(child, offset),
                oldLayer: _fadeOut.layer,
              );
        _fadeIn.layer = into <= 0
            ? null
            : context.pushOpacity(
                offset,
                into,
                (context, offset) => context.paintChild(target, offset),
                oldLayer: _fadeIn.layer,
              );
      },
      oldLayer: _clip.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_active) return false;
    return _resting.hitTest(result, position: position);
  }
}
