import 'package:denial_desktop/src/state/home_back.dart';
import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/input.dart' show InputEdge;
import 'package:denial_flutter_sdk/system_services.dart';

import 'phone_scheme.dart';

/// Android's edge Back gesture.
///
/// A swipe inward from the left or right edge, between the status bar and
/// the bottom gesture area, performs [ReferenceShellController.navigateBack]
/// when it is released with the arrow active, or flings inward. Over an app
/// the compositor hands the swipe to these strips as it moves inward; over
/// shell surfaces they receive it directly.
///
/// The arrow is SystemUI's BackPanel (BackPanelController, EdgePanelParams):
/// it peeks from the edge, becomes a 48 dp circle once the finger passes
/// 16 dp, stretches toward 60 dp over the next 412 dp, goes back to its
/// pre-threshold shape when the finger returns 32 dp toward the edge, and
/// on release either fades as it commits or slides back into the edge.
class MobileBackGestureLayer extends ConsumerStatefulWidget {
  const MobileBackGestureLayer({super.key, this.onBack});

  /// Handles Back in place of [ReferenceShellController.navigateBack], for a
  /// surface that covers the shell's own strips.
  final VoidCallback? onBack;

  @override
  ConsumerState<MobileBackGestureLayer> createState() =>
      _MobileBackGestureLayerState();
}

enum _ArrowState { entry, inactive, active, committed, cancelled }

class _MobileBackGestureLayerState extends ConsumerState<MobileBackGestureLayer>
    with SingleTickerProviderStateMixin {
  static const double _touchSlop = 8.0;
  static const double _flingVelocity = 600.0;

  // EdgePanelParams, in dp.
  static const double _staticThreshold = 16;
  static const double _reactivation = 32;
  static const double _deactivation = -32;
  static const double _progressThreshold = 412;
  static const double _fingerOffset = 64;
  static const double _minY = 64;

  final _arrow = _BackArrow();
  late final Ticker _ticker = createTicker(_tick);
  Duration _lastTick = Duration.zero;

  InputEdge? _edge;
  _ArrowState _state = _ArrowState.entry;
  Offset _origin = Offset.zero;
  double _dp = 1;
  double _previousTravel = 0;
  double _deltaActive = 0;
  double _deltaInactive = 0;
  double _travelOnActive = 0;
  final _clock = Stopwatch();
  VelocityTracker _velocity = VelocityTracker.withKind(PointerDeviceKind.touch);
  int? _pastThresholdAt;
  double _thresholdDelay = 0;
  int _activeAt = 0;
  _Dimens _rest = _Dimens.entry;
  _Dimens _springs = _Dimens.entry;
  Curve _inactiveWidth = _entryWidth;

  @override
  void dispose() {
    _ticker.dispose();
    _arrow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(
      referenceShellProvider.select(
        (state) => (
          enabled: state.backTarget != MobileBackTarget.none,
          keyboard: state.edgePanelVisible,
        ),
      ),
    );
    final homeBack = ref.watch(homeBackProvider) != null;
    final size = MediaQuery.sizeOf(context);
    _dp = math.max(1.0, size.shortestSide / (1216 * 160 / 468));
    final strips = ReferenceShellMetrics.backGestureRects(
      size,
      bottom: shell.keyboard
          ? size.height - ReferenceShellMetrics.edgePanelHeight(size)
          : null,
    );
    final scheme = phoneSchemeOf(context);
    final edge = _edge;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Disabling keeps a gesture in flight alive; its release then finds
        // nothing to go back from.
        IgnorePointer(
          ignoring: !shell.enabled && !homeBack && widget.onBack == null,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _strip(strips.left, InputEdge.left),
              _strip(strips.right, InputEdge.right),
            ],
          ),
        ),
        if (edge != null)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _BackArrowPainter(
                    arrow: _arrow,
                    mirrored: edge == InputEdge.right,
                    dp: _dp,
                    background: scheme.secondaryContainer,
                    glyph: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _strip(Rect rect, InputEdge edge) {
    return Positioned.fromRect(
      rect: rect,
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: <Type, GestureRecognizerFactory>{
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                HorizontalDragGestureRecognizer
              >(() => HorizontalDragGestureRecognizer(debugOwner: this), (
                recognizer,
              ) {
                recognizer
                  ..gestureSettings = const DeviceGestureSettings(
                    touchSlop: _touchSlop,
                  )
                  ..dragStartBehavior = DragStartBehavior.down
                  ..onStart = ((details) => _start(edge, details))
                  ..onUpdate = _update
                  ..onEnd = _end
                  ..onCancel = (() => _finish(commit: false));
              }),
        },
      ),
    );
  }

  void _start(InputEdge edge, DragStartDetails details) {
    _origin = details.globalPosition;
    _previousTravel = 0;
    _deltaActive = 0;
    _deltaInactive = 0;
    _travelOnActive = 0;
    _pastThresholdAt = null;
    _clock
      ..reset()
      ..start();
    _velocity = VelocityTracker.withKind(PointerDeviceKind.touch)
      ..addPosition(Duration.zero, details.globalPosition);
    final height = MediaQuery.sizeOf(context).height;
    // The arrow sits above the finger, where the finger does not hide it.
    _arrow
      ..y = (details.globalPosition.dy - _fingerOffset * _dp).clamp(
        _minY * _dp,
        math.max(_minY * _dp, height - _minY * _dp),
      )
      ..reset(_Dimens.entry);
    _setState(_ArrowState.entry);
    _stretch(0);
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
    if (_edge != edge) setState(() => _edge = edge);
  }

  void _update(DragUpdateDetails details) {
    if (_edge == null) return;
    _velocity.addPosition(_clock.elapsed, details.globalPosition);
    final travel = math.max(
      0.0,
      _inward(details.globalPosition.dx - _origin.dx),
    );
    final delta = travel - _previousTravel;
    _previousTravel = travel;
    if (delta != 0) {
      // BackPanelController: the deltas add up while the finger goes the
      // same way, and start over when it turns.
      _deltaActive = delta.sign == _deltaActive.sign
          ? _deltaActive + delta
          : delta;
      _deltaInactive = math.max(-_touchSlop, _deltaInactive + delta);
      if (delta > 0 && _deltaInactive > _touchSlop) {
        _inactiveWidth = _entryWidth;
      } else if (delta < 0 && _deltaInactive < _touchSlop) {
        _inactiveWidth = _entryWidthTowardsEdge;
      }
    }
    final vertical = (details.globalPosition.dy - _origin.dy).abs();
    final withinY = travel * 2 >= vertical;
    final pastStatic = travel > _staticThreshold * _dp;
    switch (_state) {
      case _ArrowState.entry:
        if (_pastThreshold(pastStatic, _entryDelay)) _activate(travel);
      case _ArrowState.inactive:
        final again =
            pastStatic && withinY && _deltaInactive >= _reactivation * _dp;
        if (_pastThreshold(again, () => 160)) _activate(travel);
      case _ArrowState.active:
        final back = !withinY || _deltaActive <= _deactivation * _dp;
        if (back && _clock.elapsedMilliseconds - _activeAt > 300) {
          _setState(_ArrowState.inactive);
        }
      case _ArrowState.committed || _ArrowState.cancelled:
        return;
    }
    _stretch(switch (_state) {
      _ArrowState.entry => (travel / (_staticThreshold * _dp)).clamp(0.0, 1.0),
      _ArrowState.active =>
        ((travel - _travelOnActive) / (_progressThreshold * _dp)).clamp(
          0.0,
          1.0,
        ),
      _ArrowState.inactive => (_deltaInactive / (_reactivation * _dp)).clamp(
        0.0,
        1.0,
      ),
      _ => 0.0,
    });
  }

  /// BackPanelController.isPastThresholdToActive: the condition has to hold
  /// for a delay, fixed when it first holds.
  bool _pastThreshold(bool past, double Function() delay) {
    if (!past) {
      _pastThresholdAt = null;
      return false;
    }
    final now = _clock.elapsedMilliseconds;
    if (_pastThresholdAt == null) {
      _pastThresholdAt = now;
      _thresholdDelay = delay();
    }
    return now - _pastThresholdAt! > _thresholdDelay;
  }

  /// entryToActiveDelayCalculation: 10 ms for a finger moving 1 px/ms or
  /// faster, up to 100 ms at 0.5 px/ms or slower (smoothstep between).
  double _entryDelay() {
    final pxPerMs =
        _velocity.getVelocity().pixelsPerSecond.dx.abs() *
        MediaQuery.devicePixelRatioOf(context) /
        1000;
    final x = ((pxPerMs - 0.5) / 0.5).clamp(0.0, 1.0);
    final fast = x * x * (3 - 2 * x);
    return 10 + (100 - 10) * (1 - fast);
  }

  void _activate(double travel) {
    _travelOnActive = travel;
    _deltaActive = 0;
    final fromInactive = _state == _ArrowState.inactive;
    _setState(_ArrowState.active);
    // popOffEdge: the arrow is kicked away from the edge as it activates.
    _arrow.pop(fromInactive ? 4.7 : 4.5, _dp);
    ref.read(hapticsServiceProvider).pulse();
  }

  /// A new state: where its parts rest and the springs that take them there
  /// (BackPanelController.updateRestingArrowDimens). Entry and inactive
  /// rest folded into the edge; the finger stretches them out.
  void _setState(_ArrowState state) {
    final previous = _state;
    _state = state;
    _pastThresholdAt = null;
    switch (state) {
      case _ArrowState.entry:
        _rest = _Dimens.entry;
        _springs = _Dimens.entry;
      case _ArrowState.inactive:
        _rest = _Dimens.entry;
        _springs = _Dimens.preThreshold;
        _deltaInactive = _deactivation * _dp;
        _arrow.pop(-1.5, _dp);
      case _ArrowState.active:
        _rest = _Dimens.active;
        _springs = _Dimens.active;
        _activeAt = _clock.elapsedMilliseconds;
      case _ArrowState.committed:
        _rest = _Dimens.committed;
        _springs = _Dimens.committed;
      case _ArrowState.cancelled:
        _rest = _Dimens.cancelled;
        _springs = _Dimens.cancelled;
    }
    if (previous != state || state == _ArrowState.entry) {
      _arrow.aim(_rest, _springs);
    }
  }

  /// BackPanel.setStretch: each part goes from where its state rests toward
  /// the next shape by its own share of the finger's progress.
  void _stretch(double progress) {
    final p = progress;
    final arrowShown = p >= 0.165 ? 1.0 : 0.0;
    final _Dimens target;
    switch (_state) {
      case _ArrowState.entry || _ArrowState.inactive:
        final inactive = _state == _ArrowState.inactive;
        final toward = _Dimens.preThreshold;
        target = _rest.stretchedTo(
          toward,
          margin: 0,
          arrow: _entryWidth.transform(p),
          arrowAlpha: arrowShown,
          width: math.max(
            0,
            (inactive ? _inactiveWidth : _entryWidth).transform(p),
          ),
          height: _height.transform(p),
          edgeCorner: _edgeCorner.transform(p),
          farCorner: _farCorner.transform(p),
        );
      case _ArrowState.active:
        target = _rest.stretchedTo(
          _Dimens.stretched,
          margin: _horizontalTranslation.transform(p),
          arrow: _entryWidth.transform(p),
          arrowAlpha: 1,
          width: _activeWidth.transform(p),
          height: 1,
          edgeCorner: 1,
          farCorner: 1,
        );
      case _ArrowState.committed || _ArrowState.cancelled:
        return;
    }
    _arrow.aim(target, _springs);
  }

  void _end(DragEndDetails details) {
    if (_edge == null) return;
    final velocity = _inward(details.velocity.pixelsPerSecond.dx);
    _finish(
      commit:
          _state == _ArrowState.active ||
          (_state != _ArrowState.active &&
              velocity >= _flingVelocity &&
              _previousTravel >= _staticThreshold * _dp),
    );
  }

  void _finish({required bool commit}) {
    if (_edge == null) return;
    if (_state == _ArrowState.committed || _state == _ArrowState.cancelled) {
      return;
    }
    _setState(commit ? _ArrowState.committed : _ArrowState.cancelled);
    if (commit) {
      final onBack = widget.onBack;
      if (onBack != null) {
        onBack();
      } else if (!ref.read(referenceShellProvider.notifier).navigateBack()) {
        // Nothing of the system's to go back from: home's own, if open.
        ref.read(homeBackProvider)?.call();
      }
    }
  }

  void _tick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final moving = _arrow.step(dt.clamp(0.0, 0.05));
    final ended =
        _state == _ArrowState.committed || _state == _ArrowState.cancelled;
    if (ended && (_arrow.backgroundAlpha.value < 0.01 || !moving)) {
      _ticker.stop();
      if (mounted) setState(() => _edge = null);
    }
  }

  double _inward(double dx) => _edge == InputEdge.right ? -dx : dx;

  // EdgePanelParams' interpolators.
  static const Curve _entryWidth = Cubic(0.19, 1.27, 0.71, 0.86);
  static const Curve _entryWidthTowardsEdge = Cubic(1, -3, 1, 1.2);
  static const Curve _activeWidth = Cubic(0.7, -0.24, 0.48, 1.21);
  static const Curve _horizontalTranslation = Cubic(0.2, 1, 1, 1);
  static const Curve _farCorner = Cubic(0.03, 0.19, 0.14, 1.09);
  static const Curve _edgeCorner = Cubic(0, 1.11, 0.85, 0.84);
  static const Curve _height = Cubic(1, 0.05, 0.9, -0.29);
}

/// A spring as (stiffness, damping ratio), Android's SpringForce values.
typedef _SpringSpec = (double, double);

/// One shape of the arrow, in dp (EdgePanelParams' BackIndicatorDimens), and
/// the springs that carry each part to it. NaN keeps a part where it is.
class _Dimens {
  const _Dimens({
    required this.margin,
    required this.scale,
    required this.arrowLength,
    required this.arrowHeight,
    required this.arrowAlpha,
    required this.width,
    required this.height,
    required this.edgeCorner,
    required this.farCorner,
    required this.alpha,
    this.marginSpring = (800, 0.76),
    this.scaleSpring = (120, 0.8),
    this.arrowSpring = (600, 0.4),
    this.widthSpring = (450, 0.65),
    this.heightSpring = (1500, 0.45),
    this.edgeCornerSpring = (150, 0.5),
    this.farCornerSpring = (300, 0.5),
    this.alphaSpring = (1400, 1),
  });

  final double margin;
  final double scale;
  final double arrowLength;
  final double arrowHeight;
  final double arrowAlpha;
  final double width;
  final double height;
  final double edgeCorner;
  final double farCorner;
  final double alpha;
  final _SpringSpec marginSpring;
  final _SpringSpec scaleSpring;
  final _SpringSpec arrowSpring;
  final _SpringSpec widthSpring;
  final _SpringSpec heightSpring;
  final _SpringSpec edgeCornerSpring;
  final _SpringSpec farCornerSpring;
  final _SpringSpec alphaSpring;

  static const entry = _Dimens(
    margin: 4,
    scale: 0.98,
    arrowLength: 8.6,
    arrowHeight: 5,
    arrowAlpha: 0,
    width: 0,
    height: 48,
    edgeCorner: 6,
    farCorner: 6,
    alpha: 1,
  );

  static const preThreshold = _Dimens(
    margin: 4,
    scale: 0.98,
    arrowLength: 8,
    arrowHeight: 5.6,
    arrowAlpha: 1,
    width: 51,
    height: 46,
    edgeCorner: 16,
    farCorner: 20,
    alpha: 1,
    marginSpring: (6000, 1),
    arrowSpring: (100, 0.6),
    widthSpring: (650, 1),
    farCornerSpring: (300, 1),
    edgeCornerSpring: (250, 0.5),
  );

  static const active = _Dimens(
    margin: 14,
    scale: 1,
    arrowLength: 6.4,
    arrowHeight: 7.2,
    arrowAlpha: 1,
    width: 48,
    height: 48,
    edgeCorner: 24,
    farCorner: 24,
    alpha: 1,
    marginSpring: (1000, 0.8),
    scaleSpring: (325, 0.55),
    arrowSpring: (1500, 0.29),
    widthSpring: (850, 0.75),
    heightSpring: (10000, 1),
    edgeCornerSpring: (2600, 0.855),
    farCornerSpring: (1200, 0.3),
  );

  static const stretched = _Dimens(
    margin: 18,
    scale: 1,
    arrowLength: 5.6,
    arrowHeight: 8,
    arrowAlpha: 1,
    width: 60,
    height: 48,
    edgeCorner: 24,
    farCorner: 24,
    alpha: 1,
    marginSpring: (1000, 0.8),
    scaleSpring: (325, 0.55),
    arrowSpring: (1500, 0.29),
    widthSpring: (850, 0.75),
    heightSpring: (10000, 1),
    edgeCornerSpring: (2600, 0.855),
    farCornerSpring: (1200, 0.3),
  );

  /// Committed: the circle fades and shrinks to 0.86 where it is.
  static const committed = _Dimens(
    margin: double.nan,
    scale: 0.86,
    arrowLength: double.nan,
    arrowHeight: double.nan,
    arrowAlpha: 1,
    width: double.nan,
    height: 48,
    edgeCorner: 24,
    farCorner: 24,
    alpha: 0,
    scaleSpring: (5700, 1),
    widthSpring: (10000, 1),
    heightSpring: (10000, 1),
    edgeCornerSpring: (10000, 1),
    farCornerSpring: (10000, 1),
    alphaSpring: (1400, 1),
  );

  /// Cancelled: back into the edge as at entry, fading.
  static const cancelled = _Dimens(
    margin: 4,
    scale: 0.98,
    arrowLength: 8.6,
    arrowHeight: 5,
    arrowAlpha: 0,
    width: 0,
    height: 48,
    edgeCorner: 6,
    farCorner: 6,
    alpha: 0,
    alphaSpring: (450, 1),
  );

  /// This shape moved toward [to] by a share per part (BackPanel.stretchBy).
  _Dimens stretchedTo(
    _Dimens to, {
    required double margin,
    required double arrow,
    required double arrowAlpha,
    required double width,
    required double height,
    required double edgeCorner,
    required double farCorner,
  }) {
    double l(double x, double y, double t) => x + (y - x) * t;
    return _Dimens(
      margin: l(this.margin, to.margin, margin),
      scale: scale,
      arrowLength: l(arrowLength, to.arrowLength, arrow),
      arrowHeight: l(arrowHeight, to.arrowHeight, arrow),
      arrowAlpha: l(this.arrowAlpha, to.arrowAlpha, arrowAlpha),
      width: l(this.width, to.width, width),
      height: l(this.height, to.height, height),
      edgeCorner: l(this.edgeCorner, to.edgeCorner, edgeCorner),
      farCorner: l(this.farCorner, to.farCorner, farCorner),
      alpha: alpha,
    );
  }
}

/// One sprung value: Android's SpringForce (mass 1). SystemUI's springs
/// run in real time, not at the animator duration scale.
class _Spring {
  double value = 0;
  double velocity = 0;
  double target = 0;
  double stiffness = 500;
  double damping = 1;

  void jump(double to) {
    value = to;
    target = to;
    velocity = 0;
  }

  void aim(double to, _SpringSpec spring) {
    if (to.isNaN) return;
    target = to;
    stiffness = spring.$1;
    damping = spring.$2;
  }

  /// Advances [dt] seconds; true while still moving.
  bool step(double dt) {
    final c = 2 * damping * math.sqrt(stiffness);
    var left = dt;
    while (left > 0) {
      final h = math.min(left, 0.001);
      velocity += (-stiffness * (value - target) - c * velocity) * h;
      value += velocity * h;
      left -= h;
    }
    final settled = (value - target).abs() < 0.005 && velocity.abs() < 0.05;
    if (settled) {
      value = target;
      velocity = 0;
    }
    return !settled;
  }
}

/// The arrow's sprung parts, repainted without rebuilding.
class _BackArrow extends ChangeNotifier {
  final margin = _Spring();
  final scale = _Spring();
  final arrowLength = _Spring();
  final arrowHeight = _Spring();
  final arrowAlpha = _Spring();
  final width = _Spring();
  final height = _Spring();
  final edgeCorner = _Spring();
  final farCorner = _Spring();
  final backgroundAlpha = _Spring();

  /// The arrow's centre line, in logical pixels from the top.
  double y = 0;

  late final List<_Spring> _all = [
    margin,
    scale,
    arrowLength,
    arrowHeight,
    arrowAlpha,
    width,
    height,
    edgeCorner,
    farCorner,
    backgroundAlpha,
  ];

  void reset(_Dimens d) {
    margin.jump(d.margin);
    scale.jump(d.scale);
    arrowLength.jump(d.arrowLength);
    arrowHeight.jump(d.arrowHeight);
    arrowAlpha.jump(d.arrowAlpha);
    width.jump(d.width);
    height.jump(d.height);
    edgeCorner.jump(d.edgeCorner);
    farCorner.jump(d.farCorner);
    backgroundAlpha.jump(d.alpha);
    notifyListeners();
  }

  /// Moves every part toward [d] on the springs of [springs].
  void aim(_Dimens d, _Dimens springs) {
    margin.aim(d.margin, springs.marginSpring);
    scale.aim(d.scale, springs.scaleSpring);
    arrowLength.aim(d.arrowLength, springs.arrowSpring);
    arrowHeight.aim(d.arrowHeight, springs.arrowSpring);
    // commonArrowDimensAlphaSpring: quick before the threshold, soft after.
    arrowAlpha.aim(d.arrowAlpha, d.arrowAlpha > 0 ? (180, 0.9) : (2000, 0.6));
    width.aim(d.width, springs.widthSpring);
    height.aim(d.height, springs.heightSpring);
    edgeCorner.aim(d.edgeCorner, springs.edgeCornerSpring);
    farCorner.aim(d.farCorner, springs.farCornerSpring);
    backgroundAlpha.aim(d.alpha, springs.alphaSpring);
  }

  /// BackPanel.popOffEdge: a kick of the scale (velocity x -0.8) and of the
  /// margin (velocity x 200 px/s, here in dp).
  void pop(double velocity, double dp) {
    scale.velocity += velocity * -0.8;
    margin.velocity += velocity * 200 / 2.925;
  }

  bool step(double dt) {
    var moving = false;
    for (final spring in _all) {
      moving = spring.step(dt) || moving;
    }
    notifyListeners();
    return moving;
  }
}

/// SystemUI's BackPanel: a background [_Dimens.margin] from the edge with
/// its own corners on the edge and far sides, and a 4 dp chevron in its
/// middle, in secondaryContainer and onSecondaryContainer.
class _BackArrowPainter extends CustomPainter {
  _BackArrowPainter({
    required this.arrow,
    required this.mirrored,
    required this.dp,
    required this.background,
    required this.glyph,
  }) : super(repaint: arrow);

  final _BackArrow arrow;
  final bool mirrored;
  final double dp;
  final Color background;
  final Color glyph;

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = arrow.backgroundAlpha.value.clamp(0.0, 1.0);
    if (alpha <= 0) return;
    if (mirrored) {
      canvas
        ..translate(size.width, 0)
        ..scale(-1, 1);
    }
    final margin = arrow.margin.value * dp;
    final width = math.max(0.0, arrow.width.value * dp);
    final height = math.max(0.0, arrow.height.value * dp);
    final centre = Offset(margin + width / 2, arrow.y);
    canvas
      ..save()
      ..translate(centre.dx, centre.dy)
      ..scale(arrow.scale.value)
      ..translate(-centre.dx, -centre.dy);
    if (width > 0.5) {
      final edge = Radius.circular(
        math.min(arrow.edgeCorner.value * dp, height / 2),
      );
      final far = Radius.circular(
        math.min(arrow.farCorner.value * dp, height / 2),
      );
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          margin,
          centre.dy - height / 2,
          margin + width,
          centre.dy + height / 2,
          topLeft: edge,
          bottomLeft: edge,
          topRight: far,
          bottomRight: far,
        ),
        Paint()..color = background.withValues(alpha: background.a * alpha),
      );
    }
    final arrowAlpha = arrow.arrowAlpha.value.clamp(0.0, 1.0) * alpha;
    if (arrowAlpha > 0) {
      final length = arrow.arrowLength.value * dp;
      final half = arrow.arrowHeight.value * dp;
      final tip = centre.dx - length / 2;
      canvas.drawPath(
        Path()
          ..moveTo(tip + length, centre.dy - half)
          ..lineTo(tip, centre.dy)
          ..lineTo(tip + length, centre.dy + half),
        Paint()
          ..color = glyph.withValues(alpha: glyph.a * arrowAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4 * dp
          ..strokeCap = StrokeCap.square
          ..strokeJoin = StrokeJoin.miter,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BackArrowPainter oldDelegate) =>
      oldDelegate.arrow != arrow ||
      oldDelegate.mirrored != mirrored ||
      oldDelegate.dp != dp ||
      oldDelegate.background != background ||
      oldDelegate.glyph != glyph;
}
