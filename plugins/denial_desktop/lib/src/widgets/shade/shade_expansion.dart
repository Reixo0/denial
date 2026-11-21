import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'shade_expansion_motion.dart' show ShadeBlurAnimation, aospShadeFling;

/// What a drag on the shade is moving.
enum _Moving { panel, quickSettings }

/// The shade as Android keeps it: two numbers, the panel's expansion (how
/// far the shade is pulled, NotificationPanelViewController) and the quick
/// settings' expansion (from the quick tiles to the full QS,
/// QuickSettingsController), with one drag handler for every place a finger
/// can move them.
///
/// The panel follows the finger 1:1 over [panelTravel]; the quick settings
/// over [qsTravel], the tiles' growth, so their bottom edge stays under the
/// finger. A release flings with Android's FlingAnimationUtils
/// ([aospShadeFling]). Distances are in logical pixels.
class ShadeExpansion {
  ShadeExpansion({
    required TickerProvider vsync,
    this.onDragStart,
    this.onDragMove,
    this.onDragEnd,
  }) : panel = AnimationController(vsync: vsync),
       qs = AnimationController(vsync: vsync),
       engaged = AnimationController(vsync: vsync, duration: _engageDuration) {
    panel
      ..addListener(_collapseWhenClosed)
      ..addListener(_engage);
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

  /// The shell's flags follow the panel: a drag took it, it moved, it was
  /// let go towards open or closed at a velocity (logical px/s). The shell
  /// then settles the panel ([settlePanel]).
  final void Function()? onDragStart;
  final void Function(bool pulled)? onDragMove;
  final void Function(bool open, double velocity)? onDragEnd;

  double panelTravel = 600;
  double qsTravel = 520;

  /// Logical pixels per dp, for Android's speeds.
  double dp = 1;
  bool reduceMotion = false;

  bool _dragging = false;
  _Moving? _moving;
  bool _fromStatusBar = false;
  bool _twoFinger = false;
  bool _qsAllowed = true;

  /// This drag has moved the panel (the shell was told).
  bool _started = false;

  bool get dragging => _dragging;

  /// Android resets the quick settings each time the shade closes.
  void _collapseWhenClosed() {
    if (panel.value <= 0 && qs.value != 0 && !_twoFinger) {
      qs.stop();
      qs.value = 0;
    }
  }

  /// A finger took the shade; false when another drag already holds it (a
  /// second finger's gesture), which then leaves it alone. From the status
  /// bar it pulls the panel; with two fingers, at the start or when a second
  /// one lands anywhere during the pull, the quick settings open with it
  /// (Android's two-finger pull, `isOpenQsEvent` on a pointer down).
  /// [qsAllowed] lets a downward drag on the open shade expand the quick
  /// settings.
  bool beginDrag({
    bool fromStatusBar = false,
    bool twoFinger = false,
    bool qsAllowed = true,
  }) {
    if (_dragging) return false;
    panel.stop();
    qs.stop();
    _dragging = true;
    _moving = null;
    _fromStatusBar = fromStatusBar;
    _twoFinger = twoFinger;
    _qsAllowed = qsAllowed;
    // Each pull from the status bar starts on the quick tiles.
    if (fromStatusBar && panel.value <= 0) qs.value = 0;
    if (fromStatusBar) _watchFingers();
    return true;
  }

  final Set<int> _fingers = <int>{};
  bool _watching = false;

  void _watchFingers() {
    if (_watching) return;
    _watching = true;
    _fingers.clear();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  void _unwatchFingers() {
    if (!_watching) return;
    _watching = false;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) {
      _fingers.add(event.pointer);
      // A second finger during a pull from the status bar: the full quick
      // settings come with the panel from here.
      if (_dragging && _fromStatusBar && !_twoFinger && _fingers.length >= 2) {
        _twoFinger = true;
        qs.stop();
        qs.animateTo(
          panel.value,
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 150),
          curve: Curves.fastOutSlowIn,
        );
      }
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
        if (_twoFinger && !qs.isAnimating) qs.value = next;
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
    if (_fromStatusBar) return _Moving.panel;
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
        if (_twoFinger) {
          flingQs(open ? 1 : 0, velocity: velocity * qsTravel / panelTravel);
        }
        if (started) onDragEnd?.call(open, velocity);
      case null:
        break;
    }
    _twoFinger = false;
  }

  /// PanelViewController.flingExpands: past Android's minimum fling speed
  /// (250 dp/s) the direction decides, else the half-way point.
  bool _expands(double fraction, double velocity, double travel) {
    if (velocity.abs() < 250 * dp) return fraction >= 0.5;
    return velocity > 0;
  }

  /// Settles the panel to [open], continuing [velocity] (logical px/s).
  TickerFuture settlePanel(bool open, {double velocity = 0}) =>
      _fling(panel, open ? 1 : 0, velocity / panelTravel, dp / panelTravel);

  /// Settles the quick settings to [target] (0 or 1).
  TickerFuture flingQs(double target, {double velocity = 0}) =>
      _fling(qs, target, velocity / qsTravel, dp / qsTravel);

  TickerFuture _fling(
    AnimationController controller,
    double target,
    double velocity,
    double unitsPerDp,
  ) {
    final fling = aospShadeFling(
      distance: target - controller.value,
      velocity: velocity,
      dp: unitsPerDp,
    );
    return controller.animateTo(
      target,
      duration: reduceMotion ? Duration.zero : fling.duration,
      curve: fling.curve,
    );
  }

  void dispose() {
    _unwatchFingers();
    panel.dispose();
    qs.dispose();
    engaged.dispose();
  }
}
