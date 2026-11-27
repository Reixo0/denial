import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/rendering.dart' show CompositedTranslation;
import 'package:denial_flutter_sdk/system_services.dart'
    show hapticsServiceProvider;

import 'liquid_pill.dart';

/// The home pill at the bottom of the screen. As in Launcher3, a lift that
/// pauses arms recents, with a tap of the haptic motor, and opens it on
/// release; otherwise an upward release sends an app home and a downward one
/// returns to it. From home a pause or a flick opens recents. A downward swipe
/// closes recents, and a horizontal swipe moves the row of apps, whose
/// release sends it to the adjacent app or back. A swipe that starts while
/// the apps still move takes them from where they are: sideways it holds
/// the row, upward it lifts the app in front as the row settles.
class BottomGestureHandle extends ConsumerStatefulWidget {
  const BottomGestureHandle({super.key});

  @override
  ConsumerState<BottomGestureHandle> createState() =>
      _BottomGestureHandleState();
}

class _BottomGestureHandleState extends ConsumerState<BottomGestureHandle>
    with SingleTickerProviderStateMixin {
  static const double _closeDistance = 72.0;
  static const double _switchDistance = 82.0;
  static const double _flickVelocity = 650.0;
  static const double _switchFlickVelocity = 720.0;
  static const double _axisLockRatio = 1.18;

  /// The pill's own feedback: how far a lift goes for its full stretch.
  static const double _recentsArmFraction = 0.06;

  // Launcher3's MotionPauseDetector and end targets, in dp and dp per ms
  // (motion_pause_detector_*, quickstep_fling_threshold_speed).
  static const double _speedVerySlow = 0.0285;
  static const double _speedSomewhatFast = 0.285;
  static const double _speedFast = 1.4;
  static const double _rapidDeceleration = 0.6;
  static const Duration _forcePause = Duration(milliseconds: 300);
  static const double _pauseMinLiftDp = 36;
  static const double _flingDp = 0.5;

  // The pill follows the drag without rebuilding: its lift moves a retained
  // layer, and only a change of [_armed] rebuilds it.
  late final ValueListenable<Offset> _drag;
  final _lift = ValueNotifier(Offset.zero);

  /// Android hides the handle while an app is lifted from it.
  final _handleOpacity = ValueNotifier(1.0);
  late final Animation<double> _handleFade = Animation.fromValueListenable(
    _handleOpacity,
  );
  final _armed = ValueNotifier(false);

  /// How the pill looks: liquid that follows the finger. It never decides
  /// anything about the gesture.
  late final PillLiquid _liquid = PillLiquid(this);
  bool _overviewVisible = false;
  bool _hasSwitchTarget = false;
  double _recentsArmTravel = double.infinity;
  bool _recentsArmed = false;

  /// Logical pixels per Android dp.
  double _dp = 1;

  // The pause detector's state for the current lift.
  double? _previousVelocity;
  bool _everPaused = false;
  Timer? _pauseTimer;

  // Keep an independent velocity estimate for compositor-generated pointer
  // streams, where event coalescing can otherwise under-report a short flick.
  final Stopwatch _panClock = Stopwatch();
  VelocityTracker _panVelocity = VelocityTracker.withKind(
    PointerDeviceKind.touch,
  );
  Offset _panTravel = Offset.zero;

  @override
  void initState() {
    super.initState();
    _drag = ref.read(referenceShellProvider.notifier).gestureDrag
      ..addListener(_dragged);
    ref.read(hapticsServiceProvider).prewarm();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _liquid.reduced = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void dispose() {
    _pauseTimer?.cancel();
    _liquid.dispose();
    _drag.removeListener(_dragged);
    _lift.dispose();
    _handleOpacity.dispose();
    _armed.dispose();
    super.dispose();
  }

  void _dragged() {
    _syncPill();
  }

  /// The lift has passed Launcher3's minimum for a pause (36 dp) on its
  /// vertical axis, from an app or from home.
  bool get _pauseAllowed =>
      !_overviewVisible &&
      !ref.read(referenceShellProvider.notifier).holdsRow &&
      -_panTravel.dy >= _pauseMinLiftDp * _dp;

  /// Launcher3's MotionPauseDetector.checkMotionPaused for one move, with
  /// [velocity] the vertical velocity in dp per ms.
  void _checkPause(double velocity) {
    final previous = _previousVelocity;
    _previousVelocity = velocity;
    _pauseTimer?.cancel();
    _pauseTimer = Timer(_forcePause, () => _setPaused(true));
    if (previous == null) return;
    final speed = velocity.abs();
    final previousSpeed = previous.abs();
    bool paused;
    if (_recentsArmed) {
      // Paused until it moves fast again.
      paused = speed < _speedFast || previousSpeed < _speedFast;
    } else if ((velocity < 0) != (previous < 0)) {
      paused = false;
    } else {
      paused = speed < _speedVerySlow && previousSpeed < _speedVerySlow;
      if (!paused && !_everPaused) {
        // The first pause also counts a rapid slow-down.
        paused =
            speed < previousSpeed * _rapidDeceleration &&
            speed < _speedSomewhatFast;
      }
    }
    _setPaused(paused);
  }

  void _setPaused(bool paused) {
    if (paused && !_pauseAllowed) paused = false;
    if (paused == _recentsArmed) return;
    _recentsArmed = paused;
    if (paused && !_everPaused) {
      _everPaused = true;
      ref.read(hapticsServiceProvider).pulse();
    }
    ref.read(referenceShellProvider.notifier).armRecents(paused);
    _syncPill();
  }

  void _resetPause() {
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _previousVelocity = null;
    _everPaused = false;
    if (_recentsArmed) {
      _recentsArmed = false;
      ref.read(referenceShellProvider.notifier).armRecents(false);
    }
  }

  void _syncPill() {
    final drag = _drag.value;
    final lift = (-drag.dy / ReferenceShellMetrics.gesturePillLiftTravel).clamp(
      0.0,
      1.0,
    );
    _lift.value = Offset(0, -lift * 8.0);
    final up = -drag.dy;
    _handleOpacity.value = _overviewVisible
        ? 1.0
        : (1 - up / (_pauseMinLiftDp * _dp)).clamp(0.0, 1.0);
    // Android's handle has no armed look: only closing recents and a
    // sideways switch show one.
    _armed.value = _overviewVisible
        ? drag.dy > _closeDistance
        : _horizontalSwitchArmed(drag, hasTarget: _hasSwitchTarget);
    final progress = _overviewVisible
        ? drag.dy / _closeDistance
        : [
            up / _recentsArmTravel,
            if (_hasSwitchTarget) drag.dx.abs() / _switchDistance,
          ].reduce((a, b) => a > b ? a : b);
    _liquid.arm(progress, armed: _armed.value);
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(
      referenceShellProvider.select(
        (state) => (
          overviewVisible: state.overviewVisible,
          hasSwitchTarget: state.canSwitchApps,
        ),
      ),
    );
    _overviewVisible = shell.overviewVisible;
    _hasSwitchTarget = shell.hasSwitchTarget;
    final size = MediaQuery.sizeOf(context);
    _recentsArmTravel = size.height * _recentsArmFraction;
    _dp = math.max(1.0, size.shortestSide / (1216 * 160 / 468));
    _syncPill();
    final controller = ref.read(referenceShellProvider.notifier);

    return Positioned(
      left: 0,
      right: 0,
      bottom: ReferenceShellMetrics.gestureBottomInset,
      child: Center(
        child: RepaintBoundary(
          child: Listener(
            onPointerDown: (event) => _liquid.touch(
              event.localPosition.dx -
                  ReferenceShellMetrics.gestureHitWidth / 2,
            ),
            // A tap, or a swipe the pan has not settled yet.
            onPointerUp: (_) => _liquid.release(PillRelease.settle),
            onPointerCancel: (_) => _liquid.release(PillRelease.settle),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) {
                _beginPanTracking();
                _resetPause();
                controller.resetGestureDrag();
              },
              onPanUpdate: (details) {
                _trackPan(details.delta);
                _checkPause(
                  _panVelocity.getVelocity().pixelsPerSecond.dy / _dp / 1000,
                );
                controller.updateGestureDrag(details.delta);
                _liquid.drag(
                  _panTravel,
                  _panVelocity.getVelocity().pixelsPerSecond.dx,
                );
              },
              onPanCancel: () {
                _resetPause();
                controller.resetGestureDrag();
                _liquid.release(PillRelease.settle);
              },
              onPanEnd: (details) => _handlePanEnd(controller, details),
              child: SizedBox(
                width: ReferenceShellMetrics.gestureHitWidth,
                height: ReferenceShellMetrics.gestureHitHeight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Center(
                    child: FadeTransition(
                      opacity: _handleFade,
                      child: CompositedTranslation(
                        translation: _lift,
                        child: LiquidPill(liquid: _liquid),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handlePanEnd(
    ReferenceShellController controller,
    DragEndDetails details,
  ) {
    _panClock.stop();
    // Raw travel (not the axis-locked visual drag, which is zeroed for short
    // gestures) and the stronger of our / Flutter's velocity estimate.
    final drag = _panTravel;
    final velocity = _strongerVelocity(
      _panVelocity.getVelocity().pixelsPerSecond,
      details.velocity.pixelsPerSecond,
    );
    final acted = _resolvePan(controller, drag, velocity);
    _resetPause();
    _liquid.release(
      acted ? PillRelease.launch : PillRelease.settle,
      velocity: velocity,
    );
  }

  /// Whether the swipe did something: closed recents, moved the row, went
  /// home or opened recents.
  bool _resolvePan(
    ReferenceShellController controller,
    Offset drag,
    Offset velocity,
  ) {
    final currentState = ref.read(referenceShellProvider);

    if (currentState.overviewVisible) {
      if (drag.dy > _closeDistance || velocity.dy > _flickVelocity) {
        controller.closeOverview();
        return true;
      }
      controller.resetGestureDrag(releaseVelocity: velocity.dy);
      return false;
    }

    if (controller.holdsRow || _horizontalFlick(currentState, drag, velocity)) {
      controller.releaseRow(velocity.dx);
      return drag.dx.abs() > _switchDistance ||
          velocity.dx.abs() > _switchFlickVelocity;
    }

    // Launcher3's calculateEndTarget: a fling (0.5 dp/ms) up goes home and
    // down back to the app; slower, a paused lift opens recents, one still
    // rising past 36 dp goes home, anything else returns to the app. From
    // home a pause or an upward fling opens recents.
    final hasForeground = currentState.foregroundWindow != null;
    final fling = velocity.dy.abs() > _flingDp * _dp * 1000;
    final paused = _recentsArmed;
    final rising = velocity.dy < 0 && -drag.dy >= _pauseMinLiftDp * _dp;
    if (currentState.launchTransitionActive) {
      if ((fling && velocity.dy < 0) || paused || rising) {
        controller.goHome(releaseVelocity: velocity.dy);
        return true;
      }
      controller.resetGestureDrag(releaseVelocity: velocity.dy);
      return false;
    }
    if (!hasForeground) {
      if (paused || (fling && velocity.dy < 0)) {
        controller.openOverview(releaseVelocity: velocity.dy);
        return true;
      }
      controller.resetGestureDrag(releaseVelocity: velocity.dy);
      return false;
    }
    if (fling) {
      if (velocity.dy < 0) {
        controller.goHome(releaseVelocity: velocity.dy);
        return true;
      }
    } else if (paused) {
      controller.openOverview(releaseVelocity: velocity.dy);
      return true;
    } else if (rising) {
      controller.goHome(releaseVelocity: velocity.dy);
      return true;
    }
    controller.resetGestureDrag(releaseVelocity: velocity.dy);
    return false;
  }

  void _beginPanTracking() {
    _panTravel = Offset.zero;
    _panVelocity = VelocityTracker.withKind(PointerDeviceKind.touch);
    _panClock
      ..reset()
      ..start();
    _panVelocity.addPosition(Duration.zero, _panTravel);
  }

  void _trackPan(Offset delta) {
    _panTravel += delta;
    _panVelocity.addPosition(_panClock.elapsed, _panTravel);
  }

  /// Per-axis, keeps whichever source reports the larger magnitude, so a usable
  /// fling survives even if one estimator under-reports.
  Offset _strongerVelocity(Offset a, Offset b) {
    return Offset(
      a.dx.abs() >= b.dx.abs() ? a.dx : b.dx,
      a.dy.abs() >= b.dy.abs() ? a.dy : b.dy,
    );
  }

  bool _horizontalSwitchArmed(Offset drag, {required bool hasTarget}) {
    if (!hasTarget) {
      return false;
    }
    return drag.dx.abs() > _switchDistance &&
        drag.dx.abs() > drag.dy.abs() * _axisLockRatio;
  }

  /// A short sideways flick, too quick for the axis to lock, still switches.
  bool _horizontalFlick(
    ReferenceShellState state,
    Offset drag,
    Offset velocity,
  ) {
    if (state.launchTransitionActive ||
        velocity.dx.abs() <= _switchFlickVelocity) {
      return false;
    }
    return drag.dx.abs() > drag.dy.abs() * _axisLockRatio ||
        velocity.dx.abs() > velocity.dy.abs() * _axisLockRatio;
  }
}
