import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'shade_expansion_motion.dart';

/// What a drag on the shade is moving.
enum _Moving { panel, quickSettings }

/// The shade as Android keeps it: two numbers, the panel's expansion (how
/// far the shade is pulled, NotificationPanelViewController) and the quick
/// settings' expansion (from the quick tiles to the full QS,
/// QuickSettingsController), with one drag handler for every place a finger
/// can move them.
///
/// The finger moves the panel 1:1 over [panelTravel], the notifications'
/// bottom (AOSP's getMaxPanelHeight); the quick settings
/// over [qsTravel], the tiles' growth, so their bottom edge stays under the
/// finger. A release flings with Android's FlingAnimationUtils
/// ([aospFling]); flung open, the notifications overshoot and spring back
/// ([overshoot]). Distances are in logical pixels.
class ShadeExpansion {
  ShadeExpansion({
    required TickerProvider vsync,
    this.onDragStart,
    this.onDragMove,
    this.onDragEnd,
  }) : panel = AnimationController(vsync: vsync),
       qs = AnimationController(vsync: vsync),
       overshoot = AnimationController.unbounded(vsync: vsync),
       overscroll = AnimationController.unbounded(vsync: vsync),
       engaged = AnimationController(vsync: vsync, duration: _engageDuration) {
    _catchUp = AnimationController(vsync: vsync, duration: _catchUpDuration)
      ..addListener(_followPanel);
    panel
      ..addListener(_collapseWhenClosed)
      ..addListener(_engage)
      ..addListener(_followPanel);
  }

  /// Android's timed reaction to the shade leaving closed, apart from the
  /// finger: the status bar's icons fade out (CollapsedStatusBarFragment)
  /// and a fifth of the blur springs in (NotificationShadeDepthController).
  /// It runs to 1 when the panel leaves 0 and back once it is closed.
  final AnimationController engaged;

  /// What the shade blurs behind it, 0 to 1 ([ShadeBlurAnimation]).
  late final Animation<double> blur = ShadeBlurAnimation(panel, engaged);

  static const _engageDuration = Duration(milliseconds: 160);

  void _engage() {
    if (panel.value > 0) {
      if (engaged.value < 1 && engaged.status != AnimationStatus.forward) {
        if (reduceMotion) {
          engaged.value = 1;
        } else {
          engaged.forward();
        }
      }
    } else if (engaged.value > 0 && engaged.status != AnimationStatus.reverse) {
      if (reduceMotion) {
        engaged.value = 0;
      } else {
        engaged.reverse();
      }
    }
  }

  /// 0 closed, 1 open.
  final AnimationController panel;

  /// 0 the quick tiles over the notifications, 1 the full quick settings.
  final AnimationController qs;

  /// How far past its place the notification stack is, in dp (AOSP's
  /// overExpansion): a fling open carries it there and it springs back.
  final AnimationController overshoot;

  /// How far the notification list is pushed up past its end, in dp.
  final AnimationController overscroll;

  /// A finger pushed the list [dp] on past its end
  /// (RUBBER_BAND_FACTOR_NORMAL).
  void overscrollBy(double dp) {
    overscroll.value = overscroll.value + dp * 0.1;
  }

  /// The finger came back by [dp]; what of it is left for the list.
  double takeOverscroll(double dp) {
    final taken = dp.clamp(0.0, overscroll.value);
    if (taken > 0) overscroll.value -= taken;
    return dp - taken;
  }

  /// The list reached its end at [speed] (dp/s): it runs on for as far as
  /// NotificationStackScrollLayout lets it (its speed over 1000 times the
  /// overfling distance, 6 dp, in Android's pixels), then springs back.
  /// [pushed] already past its end it runs a tenth of that.
  void flingOverscroll(double speed, {bool pushed = false}) {
    if (speed < 50 || reduceMotion) return releaseOverscroll();
    final seconds = AospOvershoot.overfling * (pushed ? 0.1 : 1);
    overscroll
        .animateTo(
          overscroll.value + speed * seconds,
          duration: Duration(microseconds: (seconds * 1e6).round()),
        )
        .then((_) => releaseOverscroll());
  }

  void releaseOverscroll() {
    if (overscroll.value <= 0) return;
    overscroll.animateTo(
      0,
      duration: reduceMotion ? Duration.zero : AospOvershoot.listSpringBack,
      curve: Curves.fastOutSlowIn,
    );
  }

  /// Android's two-finger pull (`isExpandImmediate`): the quick settings
  /// open with the panel, straight to the full ones, the notifications
  /// hidden. From the second finger until the panel rests open or closed.
  final ValueNotifier<bool> pullsBoth = ValueNotifier<bool>(false);

  /// How far the quick settings have caught up with a panel that was already
  /// on its way when the second finger landed.
  late final AnimationController _catchUp;
  static const _catchUpDuration = Duration(milliseconds: 150);

  void _pullBoth() {
    if (pullsBoth.value) return;
    qs.stop();
    pullsBoth.value = true;
    if (panel.value < 0.02 || reduceMotion) {
      _catchUp.value = 1;
    } else {
      _catchUp.forward(from: 0);
    }
    _followPanel();
  }

  void _followPanel() {
    if (!pullsBoth.value) return;
    qs.value = panel.value * Curves.fastOutSlowIn.transform(_catchUp.value);
    _finishPullBoth();
  }

  /// Over once the panel rests at an end.
  void _finishPullBoth() {
    if (_dragging || (panel.value > 0 && panel.value < 1)) return;
    _catchUp.stop();
    qs.value = panel.value;
    pullsBoth.value = false;
  }

  /// The shell's flags follow the panel: a drag took it, it moved, it was
  /// let go towards open or closed at a velocity (logical px/s). The shell
  /// then settles the panel ([settlePanel]).
  final void Function()? onDragStart;
  final void Function(bool pulled)? onDragMove;
  final void Function(bool open, double velocity)? onDragEnd;

  double screenTravel = 600;

  /// Where the notifications end on the screen while there are few; more
  /// fill it.
  double? contentBottom;

  double get panelTravel {
    final bottom = contentBottom;
    if (bottom == null || pullsBoth.value) return screenTravel;
    return bottom.clamp(screenTravel * 0.2, screenTravel);
  }

  double qsTravel = 520;

  /// Logical pixels per dp, for Android's speeds.
  double dp = 1;
  bool reduceMotion = false;

  bool _dragging = false;
  _Moving? _moving;
  bool _fromStatusBar = false;
  bool _qsAllowed = true;

  /// This drag has moved the panel (the shell was told).
  bool _started = false;

  bool get dragging => _dragging;

  /// Android resets the quick settings each time the shade closes.
  void _collapseWhenClosed() {
    if (panel.value <= 0 && qs.value != 0 && !pullsBoth.value) {
      qs.stop();
      qs.value = 0;
    }
  }

  /// A finger took the shade; false when another drag already holds it (a
  /// second finger's gesture), which then leaves it alone. From the status
  /// bar it pulls the panel; a second finger on the bar opens the quick
  /// settings with it. [fingers] are on the bar already (the drag starts
  /// with the first one's touch) and [barHeight] is how far down it reaches.
  /// [qsAllowed] lets a downward drag on the open shade expand the quick
  /// settings.
  bool beginDrag({
    bool fromStatusBar = false,
    Set<int> fingers = const <int>{},
    double barHeight = 0,
    bool qsAllowed = true,
  }) {
    if (_dragging) return false;
    if (panel.isAnimating) _springBack();
    panel.stop();
    if (!pullsBoth.value) qs.stop();
    _dragging = true;
    _moving = null;
    _fromStatusBar = fromStatusBar;
    _qsAllowed = qsAllowed;
    if (fromStatusBar) {
      // Each pull from the status bar starts on the quick tiles.
      if (panel.value <= 0) {
        pullsBoth.value = false;
        qs.value = 0;
      }
      _watchFingers(fingers, barHeight);
    }
    return true;
  }

  final Set<int> _fingers = <int>{};
  double _barHeight = 0;
  bool _watching = false;

  void _watchFingers(Set<int> fingers, double barHeight) {
    _fingers
      ..clear()
      ..addAll(fingers);
    _barHeight = barHeight;
    if (_fingers.length >= 2) _pullBoth();
    if (_watching) return;
    _watching = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  void _unwatchFingers() {
    if (!_watching) return;
    _watching = false;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) {
      if (event.position.dy > _barHeight) return;
      _fingers.add(event.pointer);
      if (_dragging && _fromStatusBar && _fingers.length >= 2) _pullBoth();
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _fingers.remove(event.pointer);
    }
  }

  /// The finger moved [dy] logical pixels (down is positive).
  void dragBy(double dy) {
    if (!_dragging || dy == 0) return;
    _moving ??= _choose(dy);
    switch (_moving) {
      case _Moving.panel:
        final was = panel.value;
        final next = (was + dy / panelTravel).clamp(0.0, 1.0);
        if (next == was) return;
        if (was <= 0 || !_started) {
          _started = true;
          onDragStart?.call();
        }
        panel.value = next;
        onDragMove?.call(next > 0);
      case _Moving.quickSettings:
        final next = qs.value + dy / qsTravel;
        if (next < 0 && !_fromStatusBar) {
          // Pushed up past the quick tiles: the same drag closes the shade.
          qs.value = 0;
          _moving = _Moving.panel;
          dragBy(next * qsTravel);
          return;
        }
        qs.value = next.clamp(0.0, 1.0);
      case null:
        break;
    }
  }

  _Moving? _choose(double dy) {
    if (_fromStatusBar || pullsBoth.value) return _Moving.panel;
    if (dy > 0) {
      if (panel.value < 1) return _Moving.panel;
      return _qsAllowed && qs.value < 1 ? _Moving.quickSettings : null;
    }
    return qs.value > 0 ? _Moving.quickSettings : _Moving.panel;
  }

  /// The finger left at [velocity] logical px/s (down is positive).
  void endDrag(double velocity) {
    if (!_dragging) return;
    _dragging = false;
    _unwatchFingers();
    final moving = _moving;
    final started = _started;
    _moving = null;
    _started = false;
    switch (moving) {
      case _Moving.quickSettings:
        flingQs(
          _expands(qs.value, velocity, qsTravel) ? 1 : 0,
          velocity: velocity,
        );
      case _Moving.panel:
        final open = _expands(panel.value, velocity, panelTravel);
        if (started) onDragEnd?.call(open, velocity);
      case null:
        break;
    }
    if (pullsBoth.value) _finishPullBoth();
  }

  /// PanelViewController.flingExpands: past Android's minimum fling speed
  /// (250 dp/s) the direction decides, else the half-way point.
  bool _expands(double fraction, double velocity, double travel) {
    if (velocity.abs() < 250 * dp) return fraction >= 0.5;
    return velocity > 0;
  }

  /// Settles the panel to [open], continuing [velocity] (logical px/s).
  TickerFuture settlePanel(bool open, {double velocity = 0}) {
    final target = open ? 1.0 : 0.0;
    // A fling open aims past the end by its overshoot.
    final overshoots =
        open &&
        panel.value < 1 &&
        velocity >= 0 &&
        overshoot.value == 0 &&
        !reduceMotion;
    final past = overshoots ? AospOvershoot.of(velocity / dp) : 0.0;
    final fling = aospFling(
      open ? AospFling.open : AospFling.close,
      distance: (target - panel.value) * panelTravel + past * dp,
      velocity: velocity,
      dp: dp,
      maxDistance: screenTravel,
    );
    final duration = reduceMotion
        ? Duration.zero
        : open && velocity == 0 && panel.value < 1
        ? AospOvershoot.springOut
        : fling.duration;
    if (overshoots || (!open && overshoot.value != 0)) {
      _springingBack = false;
      overshoot
          .animateTo(
            past,
            duration: duration,
            curve: ChainedCurve(fling.curve, Curves.fastOutSlowIn),
          )
          .then((_) => _springBack());
    } else {
      _springBack();
    }
    return panel.animateTo(target, duration: duration, curve: fling.curve);
  }

  void _springBack() {
    if (overshoot.value == 0) {
      overshoot.stop();
      return;
    }
    if (overshoot.isAnimating && _springingBack) return;
    _springingBack = true;
    overshoot
        .animateTo(
          0,
          duration: reduceMotion ? Duration.zero : AospOvershoot.springBack,
          curve: Curves.fastOutSlowIn,
        )
        .whenCompleteOrCancel(() => _springingBack = false);
  }

  bool _springingBack = false;

  /// Settles the quick settings to [target] (0 or 1). A finger going the
  /// other way leaves no speed and takes 350 ms.
  TickerFuture flingQs(double target, {double velocity = 0}) {
    final distance = (target - qs.value) * qsTravel;
    final opposite = velocity * distance < 0;
    final fling = aospFling(
      AospFling.open,
      distance: distance,
      velocity: opposite ? 0 : velocity,
      dp: dp,
    );
    return qs.animateTo(
      target,
      duration: reduceMotion
          ? Duration.zero
          : opposite
          ? const Duration(milliseconds: 350)
          : fling.duration,
      curve: fling.curve,
    );
  }

  void dispose() {
    _unwatchFingers();
    panel.dispose();
    qs.dispose();
    overshoot.dispose();
    overscroll.dispose();
    engaged.dispose();
    _catchUp.dispose();
    pullsBoth.dispose();
  }
}
