import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'shade/shade_expansion_motion.dart'
    show AospFling, androidDuration, aospFling;

/// How far a notification (or a group) has opened, for what lays it out.
///
/// By hand it is a height the finger moves ([ExpandHelper]); a tap plays it
/// over AOSP's ANIMATION_DURATION_STANDARD, the height fast-out-slow-in and
/// the contents' own change linear (StackStateAnimator,
/// ViewTransformationHelper).
class NotificationExpandMotion extends ChangeNotifier {
  NotificationExpandMotion({required this._open});

  bool _open;
  bool _active = false;
  bool _byHand = false;
  bool _opening = false;
  double _pulled = 0;
  double _time = 0;

  /// What it shows at rest, or goes to.
  bool get open => _byHand ? _open : (_active ? _opening : _open);

  /// On the way: both layouts are needed.
  bool get active => _active;
  bool get showsCollapsed => _active || !_open;
  bool get showsExpanded => _active || _open;

  /// The finger moves it, or it settles after the finger.
  bool get byHand => _byHand;

  /// How much taller the expanded layout is, from the last layout.
  double range = 0;

  /// The contents turn into the expanded layout, else back to the collapsed.
  bool get toExpanded => _byHand || _opening;

  /// How far the contents have turned.
  double get amount =>
      !_byHand ? _time : (range <= 0 ? 1 : (_pulled / range).clamp(0.0, 1.0));

  /// 0 collapsed, 1 expanded: the height.
  double get progress {
    if (_byHand) return amount;
    final eased = Curves.fastOutSlowIn.transform(_time);
    return _opening ? eased : 1 - eased;
  }

  double get grown =>
      _byHand ? _pulled.clamp(0.0, range).toDouble() : progress * range;

  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }
}

/// Opens and closes a notification: Android's ExpandHelper (a downward pull
/// grows it with the finger, 1:1; let go, it settles open when it grew and
/// the finger was not moving up, else closes again, on FlingAnimationUtils'
/// curve, 0.3 s at most), and taps, through [open].
class NotificationPullExpand extends StatefulWidget {
  const NotificationPullExpand({
    required this.enabled,
    required this.open,
    required this.onOpen,
    required this.builder,
    this.onStart,
    super.key,
  });

  /// Whether it can be pulled.
  final bool enabled;

  /// What it is to be; a change plays the animation.
  final bool open;

  /// A pull ended: open or closed.
  final ValueChanged<bool> onOpen;
  final VoidCallback? onStart;
  final Widget Function(BuildContext, NotificationExpandMotion) builder;

  @override
  State<NotificationPullExpand> createState() => _NotificationPullExpandState();
}

class _NotificationPullExpandState extends State<NotificationPullExpand>
    with SingleTickerProviderStateMixin {
  late final NotificationExpandMotion _motion = NotificationExpandMotion(
    open: widget.open,
  );
  late final AnimationController _run = AnimationController(vsync: this)
    ..addListener(_onTick);

  /// What the running animation moves.
  void Function(double value)? _follow;

  void _onTick() => _follow?.call(_run.value);

  @override
  void didUpdateWidget(NotificationPullExpand oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_motion._byHand) return;
    if (widget.open != _motion.open) _toggle(widget.open);
  }

  void _toggle(bool open) {
    // Taken back on its way: the rest of the time, the other way.
    final from = _motion._active ? 1 - _motion._time : 0.0;
    _run.stop();
    _follow = null;
    _motion._set(() {
      _motion
        .._active = true
        .._byHand = false
        .._opening = open
        .._time = from;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _rest(open);
      return;
    }
    _follow = (value) => _motion._set(() => _motion._time = value);
    _run
      ..duration = androidDuration(360)
      ..value = from;
    _run.forward().whenComplete(() {
      if (mounted) setState(() => _rest(open));
    });
  }

  void _rest(bool open) {
    _follow = null;
    _motion._set(() {
      _motion
        .._active = false
        .._byHand = false
        .._open = open
        .._pulled = 0
        .._time = 0;
    });
  }

  @override
  void dispose() {
    _run.dispose();
    _motion.dispose();
    super.dispose();
  }

  void _start(DragStartDetails details) {
    if (_motion._active || _motion._open) return;
    HapticFeedback.lightImpact();
    _run.stop();
    _follow = null;
    setState(() {
      _motion._set(() {
        _motion
          .._active = true
          .._byHand = true
          .._pulled = 0
          ..range = 0;
      });
    });
    widget.onStart?.call();
  }

  bool get _held => _motion._active && _motion._byHand && _follow == null;

  void _update(DragUpdateDetails details) {
    if (!_held) return;
    final limit = _motion.range > 0 ? _motion.range : double.infinity;
    _motion._set(
      () => _motion._pulled = (_motion._pulled + details.delta.dy).clamp(
        0.0,
        limit,
      ),
    );
  }

  void _end(double velocity) {
    if (!_held) return;
    final range = _motion.range;
    final current = _motion._pulled.clamp(0.0, range);
    final open = range <= 0 || (current > 0 && velocity >= 0);
    final target = open ? range : 0.0;
    if (target == current) {
      _finish(open);
      return;
    }
    final fling = aospFling(
      AospFling.expand,
      distance: target - current,
      velocity: open == velocity >= 0 ? velocity : 0,
      dp: 1,
    );
    _follow = (value) => _motion._set(
      () => _motion._pulled =
          current + (target - current) * fling.curve.transform(value),
    );
    _run
      ..duration = fling.duration
      ..value = 0;
    _run.forward().whenComplete(() {
      if (mounted) _finish(open);
    });
  }

  void _finish(bool open) {
    setState(() => _rest(open));
    widget.onOpen(open);
  }

  @override
  Widget build(BuildContext context) {
    final pulls = _motion._active || (widget.enabled && !_motion._open);
    // Always there, so that the content keeps its place in the tree.
    return RawGestureDetector(
      // Anywhere on the row, not only on its text.
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        if (pulls)
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
      child: widget.builder(context, _motion),
    );
  }
}

/// A vertical drag that only starts downward, so the list still scrolls up
/// from a row. It starts a pixel before the drags around it, so that a row
/// always takes its pull before the shade does.
class _PullDownRecognizer extends VerticalDragGestureRecognizer {
  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      globalDistanceMoved >
      computeHitSlop(pointerDeviceKind, gestureSettings) - 1;
}
