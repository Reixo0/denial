import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'shade_expansion_motion.dart' show androidAnimatorScale, androidDuration;

/// Horizontal container press bounce (`BounceableImpl` + `BounceableTileViewModel`)
/// and content scale bounce from AOSP Compose QS.
class QsBounceableController {
  QsBounceableController(TickerProvider vsync)
    : bounce = AnimationController.unbounded(vsync: vsync, value: 0),
      _content = AnimationController(
        vsync: vsync,
        duration: androidDuration(_contentDurationMs),
      ) {
    bounce.addListener(_checkThreshold);
  }

  /// `BounceableTileViewModel.BounceSize`: 8 dp horizontal expansion on press.
  static const double bounceSize = 8;

  /// `BounceableImpl.MINIMUM_BOUNCE_RATIO`: hold release until 75% reached.
  static const double minBounceRatio = 0.75;
  static const int _maxWaitMs = 1000;
  static const int _contentDurationMs = 167 * 2;
  static const double _iconBounceScale = 1.1;
  static const double _textBounceScale = 1.06;

  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 1500 / (androidAnimatorScale * androidAnimatorScale),
    ratio: 1.0,
  );
  static const Tolerance _tolerance = Tolerance(distance: 0.05, velocity: 0.5);

  /// Current horizontal expansion in dp (`0..8`).
  final AnimationController bounce;
  final AnimationController _content;
  Timer? _waitTimer;
  bool _waitingRelease = false;
  bool _disposed = false;

  late final Animation<double> iconScale = _content.drive(
    TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: _iconBounceScale,
        ).chain(CurveTween(curve: const Cubic(0.05, 0, 0, 1))),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: _iconBounceScale,
          end: 1.0,
        ).chain(CurveTween(curve: const Cubic(1, 0, 0.95, 1))),
        weight: 1,
      ),
    ]),
  );

  late final Animation<double> textScale = _content.drive(
    TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.0,
          end: _textBounceScale,
        ).chain(CurveTween(curve: const Cubic(0.05, 0, 0, 1))),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: _textBounceScale,
          end: 1.0,
        ).chain(CurveTween(curve: const Cubic(1, 0, 0.95, 1))),
        weight: 1,
      ),
    ]),
  );

  void onPressDown({required bool reduceMotion}) {
    if (_disposed || reduceMotion) return;
    _cancelWait();
    bounce.animateWith(
      SpringSimulation(
        _spring,
        bounce.value,
        bounceSize,
        bounce.velocity,
        tolerance: _tolerance,
        snapToEnd: true,
      ),
    );
  }

  void onPressUp() {
    if (_disposed) return;
    if (bounce.value >= bounceSize * minBounceRatio || !bounce.isAnimating) {
      _springToRest();
      return;
    }
    _waitingRelease = true;
    _waitTimer?.cancel();
    _waitTimer = Timer(androidDuration(_maxWaitMs), _springToRest);
  }

  void animateContentBounce({required bool reduceMotion}) {
    if (_disposed || reduceMotion) return;
    _content.forward(from: 0);
  }

  void _checkThreshold() {
    if (_waitingRelease && bounce.value >= bounceSize * minBounceRatio) {
      _springToRest();
    }
  }

  void _cancelWait() {
    _waitingRelease = false;
    _waitTimer?.cancel();
    _waitTimer = null;
  }

  void _springToRest() {
    if (_disposed) return;
    _cancelWait();
    if (bounce.value == 0 && !bounce.isAnimating) return;
    bounce.animateWith(
      SpringSimulation(
        _spring,
        bounce.value,
        0,
        bounce.velocity,
        tolerance: _tolerance,
        snapToEnd: true,
      ),
    );
  }

  void dispose() {
    _disposed = true;
    _cancelWait();
    bounce
      ..removeListener(_checkThreshold)
      ..dispose();
    _content.dispose();
  }
}

/// Exposes a tile's [QsBounceableController] without rebuilding on tick.
class QsBounceScope extends InheritedWidget {
  const QsBounceScope({
    required this.controller,
    required super.child,
    super.key,
  });

  final QsBounceableController controller;

  static QsBounceableController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<QsBounceScope>()?.controller;

  @override
  bool updateShouldNotify(QsBounceScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}

/// One row of quick-settings tiles whose pressed tile expands horizontally
/// while its row neighbours shrink so outer row edges and gaps stay aligned.
class QsBounceRow extends StatefulWidget {
  const QsBounceRow({
    super.key,
    required this.tiles,
    required this.bounceEnd,
    required this.columns,
    required this.gap,
    required this.tileHeight,
  });

  final List<({Widget child, int span})> tiles;

  /// True when the row stops short of [columns], so its last tile can expand
  /// into the empty space on its end edge.
  final bool bounceEnd;
  final int columns;
  final double gap;
  final double tileHeight;

  @override
  State<QsBounceRow> createState() => _QsBounceRowState();
}

class _QsBounceRowState extends State<QsBounceRow>
    with TickerProviderStateMixin {
  final List<QsBounceableController> _controllers = [];

  @override
  void initState() {
    super.initState();
    _syncCount(widget.tiles.length);
  }

  @override
  void didUpdateWidget(QsBounceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncCount(widget.tiles.length);
  }

  void _syncCount(int count) {
    while (_controllers.length < count) {
      _controllers.add(QsBounceableController(this));
    }
    while (_controllers.length > count) {
      _controllers.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    _controllers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _QsBounceRowLayout(
      controllers: List<QsBounceableController>.unmodifiable(_controllers),
      spans: [for (final tile in widget.tiles) tile.span],
      bounceEnd: widget.bounceEnd,
      columns: widget.columns,
      gap: widget.gap,
      tileHeight: widget.tileHeight,
      children: [
        for (var i = 0; i < widget.tiles.length; i++)
          QsBounceScope(
            controller: _controllers[i],
            child: widget.tiles[i].child,
          ),
      ],
    );
  }
}

class _QsBounceRowLayout extends MultiChildRenderObjectWidget {
  const _QsBounceRowLayout({
    required this.controllers,
    required this.spans,
    required this.bounceEnd,
    required this.columns,
    required this.gap,
    required this.tileHeight,
    required super.children,
  });

  final List<QsBounceableController> controllers;
  final List<int> spans;
  final bool bounceEnd;
  final int columns;
  final double gap;
  final double tileHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderQsBounceRow(
    controllers: controllers,
    spans: spans,
    bounceEnd: bounceEnd,
    columns: columns,
    gap: gap,
    tileHeight: tileHeight,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderQsBounceRow renderObject,
  ) {
    renderObject
      ..controllers = controllers
      ..spans = spans
      ..bounceEnd = bounceEnd
      ..columns = columns
      ..gap = gap
      ..tileHeight = tileHeight;
  }
}

class _BounceRowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderQsBounceRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BounceRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BounceRowParentData> {
  _RenderQsBounceRow({
    required List<QsBounceableController> controllers,
    required List<int> spans,
    required bool bounceEnd,
    required int columns,
    required double gap,
    required double tileHeight,
  }) : this._raw(controllers, spans, bounceEnd, columns, gap, tileHeight);

  _RenderQsBounceRow._raw(
    this._controllers,
    this._spans,
    this._bounceEnd,
    this._columns,
    this._gap,
    this._tileHeight,
  );

  List<QsBounceableController> _controllers;
  set controllers(List<QsBounceableController> value) {
    if (_sameControllers(_controllers, value)) return;
    if (attached) _unlisten();
    _controllers = value;
    if (attached) _listen();
    markNeedsLayout();
  }

  static bool _sameControllers(
    List<QsBounceableController> a,
    List<QsBounceableController> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  List<int> _spans;
  set spans(List<int> value) {
    if (_spans.length == value.length) {
      var same = true;
      for (var i = 0; i < value.length; i++) {
        if (_spans[i] != value[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    _spans = value;
    markNeedsLayout();
  }

  bool _bounceEnd;
  set bounceEnd(bool value) {
    if (value == _bounceEnd) return;
    _bounceEnd = value;
    markNeedsLayout();
  }

  int _columns;
  set columns(int value) {
    if (value == _columns) return;
    _columns = value;
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  double _tileHeight;
  set tileHeight(double value) {
    if (value == _tileHeight) return;
    _tileHeight = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BounceRowParentData) {
      child.parentData = _BounceRowParentData();
    }
  }

  void _listen() {
    for (final controller in _controllers) {
      controller.bounce.addListener(markNeedsLayout);
    }
  }

  void _unlisten() {
    for (final controller in _controllers) {
      controller.bounce.removeListener(markNeedsLayout);
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
  }

  @override
  void detach() {
    _unlisten();
    super.detach();
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final column = math.max(0.0, (width - _gap * (_columns - 1)) / _columns);
    final count = _controllers.length;
    var idleX = 0.0;
    var child = firstChild;
    for (var i = 0; child != null; i++, child = childAfter(child)) {
      final span = i < _spans.length ? _spans[i] : 1;
      final idleWidth = span >= 2 ? column * span + _gap * (span - 1) : column;
      final selfBounce = i < count ? _controllers[i].bounce.value : 0.0;
      final prevBounce = i > 0 && i - 1 < count
          ? _controllers[i - 1].bounce.value
          : 0.0;
      final hasNext = i + 1 < count;
      final nextBounce = hasNext ? _controllers[i + 1].bounce.value : 0.0;

      // AOSP Bounceable.kt: adjust start against previous neighbour, end
      // against next neighbour (or empty trailing space if !onLastColumn).
      final sizePrevious = i > 0 ? selfBounce - prevBounce : 0.0;
      final sizeNext = hasNext
          ? selfBounce - nextBounce
          : (_bounceEnd ? selfBounce : 0.0);
      final animatedWidth = math.max(0.0, idleWidth + sizePrevious + sizeNext);
      child.layout(
        BoxConstraints.tightFor(width: animatedWidth, height: _tileHeight),
        parentUsesSize: false,
      );
      final data = child.parentData! as _BounceRowParentData;
      data.offset = Offset(idleX - sizePrevious, 0);
      idleX += idleWidth + _gap;
    }
    size = constraints.constrain(Size(width, _tileHeight));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
