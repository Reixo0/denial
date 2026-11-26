import 'dart:ui' show lerpDouble;

import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../notification_banner.dart' show PixelNotificationMetrics;
import 'notification_shade_list.dart';
import 'shade_expansion_motion.dart' show androidAnimatorScale, androidDuration;

enum _MagneticState { idle, pulling, detached }

class _RowMagneticState {
  _RowMagneticState(
    TickerProvider vsync,
    VoidCallback onTick,
  ) : catchup = AnimationController.unbounded(vsync: vsync, value: 0),
      neighborFollow = AnimationController.unbounded(vsync: vsync, value: 1),
      topRound = AnimationController(vsync: vsync, value: 0),
      bottomRound = AnimationController(vsync: vsync, value: 0) {
    catchup.addListener(onTick);
    neighborFollow.addListener(onTick);
    topRound.addListener(onTick);
    bottomRound.addListener(onTick);
  }

  /// Delta added onto the live target translation (`base + catchup`), animated
  /// by AOSP detach/attach/snap springs so finger tracking stays 1:1 without
  /// jumps when crossing the detach/re-attach thresholds.
  final AnimationController catchup;

  /// Smooth blend (`0 -> 1`) for neighbors when transitioning onto a magnetic
  /// pull multiplier on re-attach.
  final AnimationController neighborFollow;
  final AnimationController topRound;
  final AnimationController bottomRound;

  /// Base translation driven directly by finger drag while coupled, or 0 when
  /// releasing/snapping back.
  double baseTx = 0;

  /// Snapshot starting offset used when `neighborFollow` blends toward `baseTx`.
  double fromTx = 0;

  double get translation =>
      lerpDouble(fromTx, baseTx, neighborFollow.value.clamp(0.0, 1.0))! +
      catchup.value;

  void stopTranslations() {
    catchup.stop();
    neighborFollow.stop();
  }

  void setRoundTarget(
    double top,
    double bottom, {
    required bool animate,
    required bool reduceMotion,
  }) {
    final t = top.clamp(0.0, 1.0);
    final b = bottom.clamp(0.0, 1.0);
    if (!animate || reduceMotion) {
      topRound.value = t;
      bottomRound.value = b;
      return;
    }
    final duration = androidDuration(200);
    if ((topRound.value - t).abs() > 0.005) {
      topRound.animateTo(t, duration: duration, curve: Curves.fastOutSlowIn);
    }
    if ((bottomRound.value - b).abs() > 0.005) {
      bottomRound.animateTo(
        b,
        duration: duration,
        curve: Curves.fastOutSlowIn,
      );
    }
  }

  void dispose() {
    catchup.dispose();
    neighborFollow.dispose();
    topRound.dispose();
    bottomRound.dispose();
  }
}

/// Manages AOSP's magnetic swipe-to-dismiss coupling (`72 dp` detach, `56 dp`
/// re-attach, neighbor pull, corner roundness, and spring snap-back) across
/// top-level notification rows.
class MagneticNotificationSwipeManager extends ChangeNotifier {
  MagneticNotificationSwipeManager(this._vsync);

  /// AOSP `MagneticNotificationRowManagerImpl` constants.
  static const double detachThresholdDp = 72;
  static const double attachThresholdDp = 56;
  static const double dismissVelocityDpPerSec = 500;
  static const List<double> _translationMultipliers = <double>[
    0.04,
    0.12,
    0.5,
    0.12,
    0.04,
  ];
  static const List<double> _roundnessMultipliers = <double>[
    0.5,
    0.7,
    0.9,
    1.0,
    0.9,
    0.7,
    0.5,
  ];
  static const double _maxPreDetachRoundness = 0.8;

  static const double _scale = androidAnimatorScale * androidAnimatorScale;
  static final SpringDescription _detachSpring =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 800 / _scale,
        ratio: 0.95,
      );
  static final SpringDescription _snapSpring =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 550 / _scale,
        ratio: 0.6,
      );
  static final SpringDescription _attachSpring =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 850 / _scale,
        ratio: 0.95,
      );
  static const Tolerance _txTolerance = Tolerance(distance: 0.1, velocity: 2.0);
  static const Tolerance _unitTolerance = Tolerance(
    distance: 0.002,
    velocity: 0.01,
  );

  final TickerProvider _vsync;
  final Map<int, _RowMagneticState> _rows = <int, _RowMagneticState>{};
  final Map<int, int> _sections = <int, int>{};

  int? _activeIndex;
  _MagneticState _state = _MagneticState.idle;
  double _rawDx = 0;
  double _detachSign = 0;
  bool _disposed = false;

  _RowMagneticState _row(int index) =>
      _rows.putIfAbsent(index, () => _RowMagneticState(_vsync, _onRowTick));

  void _onRowTick() {
    if (!_disposed) notifyListeners();
  }

  /// Registers the section index of each top-level notification card so
  /// magnetic coupling stops cleanly at section headers.
  void syncSections(Iterable<(int index, int section)> entries) {
    _sections.clear();
    for (final (index, section) in entries) {
      _sections[index] = section;
    }
  }

  /// Registers the section index of top-level row [index] (e.g. alerting vs
  /// silent) so magnetic coupling stops cleanly at section headers.
  void registerRow(int index, int section) {
    _sections[index] = section;
  }

  bool _sameSection(int a, int b) =>
      _sections.containsKey(a) && _sections[a] == _sections[b];

  double translationOf(int index) => _rows[index]?.translation ?? 0;

  double topRadiusFor(int index, double baseRadius) {
    final roundness = _rows[index]?.topRound.value ?? 0;
    return lerpDouble(baseRadius, PixelNotificationMetrics.radius, roundness)!;
  }

  double bottomRadiusFor(int index, double baseRadius) {
    final roundness = _rows[index]?.bottomRound.value ?? 0;
    return lerpDouble(baseRadius, PixelNotificationMetrics.radius, roundness)!;
  }

  void beginDrag(int index) {
    if (_disposed) return;
    _activeIndex = index;
    _state = _MagneticState.pulling;
    _rawDx = 0;
    _detachSign = 0;
    for (var k = -3; k <= 3; k++) {
      final row = _rows[index + k];
      if (row == null) continue;
      final prev = row.translation;
      row
        ..stopTranslations()
        ..catchup.value = 0
        ..fromTx = prev
        ..baseTx = prev
        ..neighborFollow.value = 1;
      if (k == 0) _rawDx = prev * 2;
    }
  }

  void updateDrag(
    int index,
    double deltaDx, {
    required bool reduceMotion,
  }) {
    if (_disposed || _activeIndex != index || deltaDx == 0) return;
    _rawDx += deltaDx;

    if (_state == _MagneticState.pulling) {
      if (_rawDx.abs() >= detachThresholdDp) {
        _state = _MagneticState.detached;
        _detachSign = _rawDx.sign;
        HapticFeedback.mediumImpact();

        final swiped = _row(index);
        final current = swiped.translation;
        swiped
          ..stopTranslations()
          ..fromTx = _rawDx
          ..baseTx = _rawDx
          ..neighborFollow.value = 1;
        if (reduceMotion) {
          swiped.catchup.value = 0;
        } else {
          swiped.catchup.animateWith(
            SpringSimulation(
              _detachSpring,
              current - _rawDx,
              0,
              0,
              tolerance: _txTolerance,
              snapToEnd: true,
            ),
          );
        }

        _snapNeighbors(index, reduceMotion: reduceMotion);
        _setDetachedRoundness(index, reduceMotion: reduceMotion);
      } else {
        _applyCoupledPull(index, _rawDx);
        _updatePreDetachRoundness(index, animate: false, reduceMotion: reduceMotion);
      }
    } else if (_state == _MagneticState.detached) {
      if (_rawDx.abs() <= attachThresholdDp) {
        _state = _MagneticState.pulling;
        _detachSign = 0;
        HapticFeedback.selectionClick();

        final swiped = _row(index);
        final current = swiped.translation;
        final coupledTarget = 0.5 * _rawDx;
        swiped
          ..stopTranslations()
          ..fromTx = coupledTarget
          ..baseTx = coupledTarget
          ..neighborFollow.value = 1;
        if (reduceMotion) {
          swiped.catchup.value = 0;
        } else {
          swiped.catchup.animateWith(
            SpringSimulation(
              _attachSpring,
              current - coupledTarget,
              0,
              0,
              tolerance: _txTolerance,
              snapToEnd: true,
            ),
          );
        }

        // Pull neighbors back smoothly into their coupled fractions.
        for (var k = -2; k <= 2; k++) {
          if (k == 0) continue;
          final targetIdx = index + k;
          if (!_sameSection(index, targetIdx)) continue;
          final neighbor = _row(targetIdx);
          final prev = neighbor.translation;
          neighbor
            ..stopTranslations()
            ..catchup.value = 0
            ..fromTx = prev
            ..baseTx = _translationMultipliers[k + 2] * _rawDx;
          if (reduceMotion) {
            neighbor.neighborFollow.value = 1;
          } else {
            neighbor.neighborFollow.value = 0;
            neighbor.neighborFollow.animateWith(
              SpringSimulation(
                _attachSpring,
                0,
                1,
                0,
                tolerance: _unitTolerance,
                snapToEnd: true,
              ),
            );
          }
        }
        _updatePreDetachRoundness(
          index,
          animate: true,
          reduceMotion: reduceMotion,
        );
      } else {
        final swiped = _row(index);
        swiped
          ..fromTx = _rawDx
          ..baseTx = _rawDx;
      }
    }
    notifyListeners();
  }

  /// Finishes the horizontal drag. Returns the dismiss slide direction (`-1` or
  /// `1`) if the row should dismiss, or `null` if it snaps back to rest.
  double? endDrag(
    int index,
    double velocityDx, {
    required bool reduceMotion,
  }) {
    if (_disposed || _activeIndex != index) return null;
    final state = _state;
    final rawDx = _rawDx;
    final detachSign = _detachSign;
    _activeIndex = null;
    _state = _MagneticState.idle;
    _rawDx = 0;
    _detachSign = 0;

    final flingEnough = velocityDx.abs() >= dismissVelocityDpPerSec;
    final flungBack =
        state == _MagneticState.detached &&
        flingEnough &&
        detachSign != 0 &&
        velocityDx.sign != detachSign;
    final flungOut =
        state == _MagneticState.pulling &&
        flingEnough &&
        (rawDx == 0 || velocityDx.sign == rawDx.sign);
    final shouldDismiss =
        (state == _MagneticState.detached && !flungBack) || flungOut;

    _snapNeighbors(index, velocityDx: velocityDx, reduceMotion: reduceMotion);

    if (shouldDismiss) {
      if (state == _MagneticState.pulling) HapticFeedback.mediumImpact();
      _setDetachedRoundness(index, reduceMotion: reduceMotion);
      // Exposed neighbor edges smoothly return to inner radius after collapse.
      for (final offset in const <int>[-1, 1]) {
        _rows[index + offset]?.setRoundTarget(
          0,
          0,
          animate: true,
          reduceMotion: reduceMotion,
        );
      }
      final swiped = _row(index);
      final current = swiped.translation;
      swiped
        ..stopTranslations()
        ..fromTx = current
        ..baseTx = current
        ..catchup.value = 0
        ..neighborFollow.value = 1;
      notifyListeners();
      if (detachSign != 0) return detachSign;
      if (velocityDx != 0) return velocityDx.sign;
      return rawDx >= 0 ? 1.0 : -1.0;
    }

    // Snap swiped row back to rest on attach spring.
    final swiped = _row(index);
    final current = swiped.translation;
    swiped
      ..stopTranslations()
      ..fromTx = 0
      ..baseTx = 0
      ..neighborFollow.value = 1;
    if (reduceMotion) {
      swiped.catchup.value = 0;
    } else {
      swiped.catchup.animateWith(
        SpringSimulation(
          _attachSpring,
          current,
          0,
          velocityDx,
          tolerance: _txTolerance,
          snapToEnd: true,
        ),
      );
    }
    _clearRoundness(index, animate: true, reduceMotion: reduceMotion);
    notifyListeners();
    return null;
  }

  /// Resets the swiped translation slot once [MagneticSwipeRow] takes over the
  /// exit/collapse animation or finishes cancelling.
  void clearRowTranslation(int index) {
    final row = _rows[index];
    if (row == null) return;
    row
      ..stopTranslations()
      ..fromTx = 0
      ..baseTx = 0
      ..catchup.value = 0
      ..neighborFollow.value = 1;
  }

  void reset() {
    if (_disposed) return;
    _activeIndex = null;
    _state = _MagneticState.idle;
    _rawDx = 0;
    _detachSign = 0;
    for (final row in _rows.values) {
      row
        ..stopTranslations()
        ..fromTx = 0
        ..baseTx = 0
        ..catchup.value = 0
        ..neighborFollow.value = 1
        ..topRound.value = 0
        ..bottomRound.value = 0;
    }
    notifyListeners();
  }

  void _applyCoupledPull(int index, double translation) {
    for (var k = -2; k <= 2; k++) {
      final targetIdx = index + k;
      if (k != 0 && !_sameSection(index, targetIdx)) continue;
      final row = _row(targetIdx);
      final value = _translationMultipliers[k + 2] * translation;
      if (!row.neighborFollow.isAnimating) {
        row.fromTx = value;
      }
      row.baseTx = value;
    }
  }

  void _snapNeighbors(
    int index, {
    double? velocityDx,
    required bool reduceMotion,
  }) {
    for (var k = -2; k <= 2; k++) {
      if (k == 0) continue;
      final neighbor = _rows[index + k];
      if (neighbor == null) continue;
      final current = neighbor.translation;
      neighbor
        ..stopTranslations()
        ..fromTx = 0
        ..baseTx = 0
        ..neighborFollow.value = 1;
      if (reduceMotion || current.abs() < 0.05) {
        neighbor.catchup.value = 0;
      } else {
        neighbor.catchup.animateWith(
          SpringSimulation(
            _snapSpring,
            current,
            0,
            (velocityDx ?? 0) * _translationMultipliers[k + 2],
            tolerance: _txTolerance,
            snapToEnd: true,
          ),
        );
      }
    }
  }

  void _updatePreDetachRoundness(
    int index, {
    required bool animate,
    required bool reduceMotion,
  }) {
    final normalized = (0.5 * _rawDx.abs()) / detachThresholdDp;
    final capped = normalized.clamp(0.0, _maxPreDetachRoundness);
    for (var k = -3; k <= 3; k++) {
      final targetIdx = index + k;
      final mult = _roundnessMultipliers[k + 3];
      final r = mult * capped;
      final row = _rows[targetIdx];
      if (row == null && !_sameSection(index, targetIdx)) continue;
      final target = _row(targetIdx);
      if (!_sameSection(index, targetIdx) && k != 0) {
        target.setRoundTarget(0, 0, animate: animate, reduceMotion: reduceMotion);
        continue;
      }
      if (k == -3) {
        target.setRoundTarget(0, r, animate: animate, reduceMotion: reduceMotion);
      } else if (k == 3) {
        target.setRoundTarget(r, 0, animate: animate, reduceMotion: reduceMotion);
      } else {
        target.setRoundTarget(r, r, animate: animate, reduceMotion: reduceMotion);
      }
    }
  }

  void _setDetachedRoundness(int index, {required bool reduceMotion}) {
    for (var k = -3; k <= 3; k++) {
      final row = _rows[index + k];
      if (k == 0) {
        _row(index).setRoundTarget(
          1,
          1,
          animate: true,
          reduceMotion: reduceMotion,
        );
      } else if (k == -1 && _sameSection(index, index - 1)) {
        _row(index - 1).setRoundTarget(
          0,
          1,
          animate: true,
          reduceMotion: reduceMotion,
        );
      } else if (k == 1 && _sameSection(index, index + 1)) {
        _row(index + 1).setRoundTarget(
          1,
          0,
          animate: true,
          reduceMotion: reduceMotion,
        );
      } else {
        row?.setRoundTarget(0, 0, animate: true, reduceMotion: reduceMotion);
      }
    }
  }

  void _clearRoundness(
    int index, {
    required bool animate,
    required bool reduceMotion,
  }) {
    for (var k = -3; k <= 3; k++) {
      _rows[index + k]?.setRoundTarget(
        0,
        0,
        animate: animate,
        reduceMotion: reduceMotion,
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final row in _rows.values) {
      row.dispose();
    }
    _rows.clear();
    super.dispose();
  }
}

Widget _buildSwipeChild({
  required double width,
  required bool exiting,
  required Animation<double> dismissAnimation,
  required double currentTx,
  required double exitStartTx,
  required double exitDir,
  required Widget child,
}) {
  if (!exiting) {
    return Transform.translate(offset: Offset(currentTx, 0), child: child);
  }
  final t = dismissAnimation.value;
  final slideT = const Interval(
    0.0,
    0.5,
    curve: Cubic(0.4, 0, 1, 1),
  ).transform(t);
  final collapseT = const Interval(
    0.35,
    1.0,
    curve: Curves.fastOutSlowIn,
  ).transform(t);
  final dx = lerpDouble(exitStartTx, exitDir * (width + 48), slideT)!;
  final opacity = (1 - slideT).clamp(0.0, 1.0);
  return ClipRect(
    clipBehavior: t > 0 ? Clip.hardEdge : Clip.none,
    child: Align(
      alignment: Alignment.topCenter,
      heightFactor: (1 - collapseT).clamp(0.0, 1.0),
      child: Opacity(
        opacity: opacity,
        child: Transform.translate(offset: Offset(dx, 0), child: child),
      ),
    ),
  );
}

/// Top-level notification swipe row driven by [MagneticNotificationSwipeManager]
/// with smooth post-swipe exit slide and height collapse.
class MagneticSwipeRow extends StatefulWidget {
  const MagneticSwipeRow({
    super.key,
    required this.manager,
    required this.index,
    required this.section,
    required this.clearable,
    required this.onDismiss,
    required this.child,
  });

  final MagneticNotificationSwipeManager manager;
  final int index;
  final int section;
  final bool clearable;
  final bool Function() onDismiss;
  final Widget child;

  @override
  State<MagneticSwipeRow> createState() => _MagneticSwipeRowState();
}

class _MagneticSwipeRowState extends State<MagneticSwipeRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dismissController = AnimationController(
    vsync: this,
    duration: androidDuration(360),
  );
  double _exitStartTx = 0;
  double _exitDir = 1;
  bool _exiting = false;
  double _lastTx = 0;

  @override
  void initState() {
    super.initState();
    widget.manager.registerRow(widget.index, widget.section);
    widget.manager.addListener(_onMagneticChanged);
    _dismissController.addListener(_invalidateOcclusion);
  }

  @override
  void didUpdateWidget(MagneticSwipeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.manager, widget.manager)) {
      oldWidget.manager.removeListener(_onMagneticChanged);
      widget.manager.addListener(_onMagneticChanged);
    }
    widget.manager.registerRow(widget.index, widget.section);
  }

  void _onMagneticChanged() {
    final tx = widget.manager.translationOf(widget.index);
    if (tx != _lastTx) {
      _lastTx = tx;
      _invalidateOcclusion();
    }
  }

  void _invalidateOcclusion() {
    if (mounted) NotificationShadeList.invalidateOcclusion(context);
  }

  Future<void> _runDismiss(double startTx, double dir) async {
    if (_exiting || !mounted) return;
    setState(() {
      _exiting = true;
      _exitStartTx = startTx;
      _exitDir = dir;
    });
    widget.manager.clearRowTranslation(widget.index);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      _dismissController.value = 1;
    } else {
      await _dismissController.forward(from: 0).orCancel.catchError((_) {});
    }
    if (!mounted) return;
    final ok = widget.onDismiss();
    if (!ok && mounted) {
      setState(() {
        _exiting = false;
      });
      _dismissController.value = 0;
    }
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onMagneticChanged);
    _dismissController
      ..removeListener(_invalidateOcclusion)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final content = AnimatedBuilder(
      animation: Listenable.merge([widget.manager, _dismissController]),
      child: widget.child,
      builder: (context, child) => _buildSwipeChild(
        width: MediaQuery.sizeOf(context).width,
        exiting: _exiting,
        dismissAnimation: _dismissController,
        currentTx: widget.manager.translationOf(widget.index),
        exitStartTx: _exitStartTx,
        exitDir: _exitDir,
        child: child!,
      ),
    );

    if (!widget.clearable || _exiting) return content;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => widget.manager.beginDrag(widget.index),
      onHorizontalDragUpdate: (d) => widget.manager.updateDrag(
        widget.index,
        d.delta.dx,
        reduceMotion: reduceMotion,
      ),
      onHorizontalDragEnd: (d) {
        final currentTx = widget.manager.translationOf(widget.index);
        final dir = widget.manager.endDrag(
          widget.index,
          d.velocity.pixelsPerSecond.dx,
          reduceMotion: reduceMotion,
        );
        if (dir != null) {
          _runDismiss(currentTx, dir);
        }
      },
      onHorizontalDragCancel: () =>
          widget.manager.endDrag(widget.index, 0, reduceMotion: reduceMotion),
      child: content,
    );
  }
}

/// Single-row magnetic swipe (`72 dp` detach, `56 dp` re-attach, `500 dp/s`
/// fling dismiss, smooth exit slide and height collapse) for embedded group
/// members.
class MagneticSingleSwipeRow extends StatefulWidget {
  const MagneticSingleSwipeRow({
    super.key,
    required this.clearable,
    required this.onDismiss,
    required this.child,
  });

  final bool clearable;
  final bool Function() onDismiss;
  final Widget child;

  @override
  State<MagneticSingleSwipeRow> createState() => _MagneticSingleSwipeRowState();
}

class _MagneticSingleSwipeRowState extends State<MagneticSingleSwipeRow>
    with TickerProviderStateMixin {
  static const double _scale = androidAnimatorScale * androidAnimatorScale;
  static final SpringDescription _detachSpring =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 800 / _scale,
        ratio: 0.95,
      );
  static final SpringDescription _attachSpring =
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: 850 / _scale,
        ratio: 0.95,
      );
  static const Tolerance _tolerance = Tolerance(distance: 0.1, velocity: 2.0);

  late final AnimationController _catchup = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );
  late final AnimationController _dismissController = AnimationController(
    vsync: this,
    duration: androidDuration(360),
  );

  _MagneticState _state = _MagneticState.idle;
  double _rawDx = 0;
  double _detachSign = 0;
  double _baseTx = 0;
  bool _exiting = false;
  double _exitStartTx = 0;
  double _exitDir = 1;

  double get _tx => _baseTx + _catchup.value;

  @override
  void dispose() {
    _catchup.dispose();
    _dismissController.dispose();
    super.dispose();
  }

  void _onDragStart() {
    final current = _tx;
    _catchup.stop();
    _state = _MagneticState.pulling;
    _rawDx = 0;
    _detachSign = 0;
    _baseTx = 0;
    _catchup.value = current;
  }

  void _onDragUpdate(double deltaDx, {required bool reduceMotion}) {
    _rawDx += deltaDx;
    if (_state == _MagneticState.pulling) {
      if (_rawDx.abs() >= MagneticNotificationSwipeManager.detachThresholdDp) {
        _state = _MagneticState.detached;
        _detachSign = _rawDx.sign;
        HapticFeedback.mediumImpact();
        final current = _tx;
        _baseTx = _rawDx;
        if (reduceMotion) {
          _catchup.value = 0;
        } else {
          _catchup.animateWith(
            SpringSimulation(
              _detachSpring,
              current - _rawDx,
              0,
              0,
              tolerance: _tolerance,
              snapToEnd: true,
            ),
          );
        }
      } else {
        setState(() => _baseTx = 0.5 * _rawDx);
        return;
      }
    } else if (_state == _MagneticState.detached) {
      if (_rawDx.abs() <= MagneticNotificationSwipeManager.attachThresholdDp) {
        _state = _MagneticState.pulling;
        _detachSign = 0;
        HapticFeedback.selectionClick();
        final current = _tx;
        final target = 0.5 * _rawDx;
        _baseTx = target;
        if (reduceMotion) {
          _catchup.value = 0;
        } else {
          _catchup.animateWith(
            SpringSimulation(
              _attachSpring,
              current - target,
              0,
              0,
              tolerance: _tolerance,
              snapToEnd: true,
            ),
          );
        }
      } else {
        setState(() => _baseTx = _rawDx);
        return;
      }
    }
    setState(() {});
  }

  Future<void> _onDragEnd(
    double velocityDx, {
    required bool reduceMotion,
  }) async {
    final flingEnough =
        velocityDx.abs() >=
        MagneticNotificationSwipeManager.dismissVelocityDpPerSec;
    final flungBack =
        _state == _MagneticState.detached &&
        flingEnough &&
        _detachSign != 0 &&
        velocityDx.sign != _detachSign;
    final flungOut =
        _state == _MagneticState.pulling &&
        flingEnough &&
        (_rawDx == 0 || velocityDx.sign == _rawDx.sign);
    final shouldDismiss =
        (_state == _MagneticState.detached && !flungBack) || flungOut;

    final current = _tx;
    final dir = _detachSign != 0
        ? _detachSign
        : velocityDx != 0
        ? velocityDx.sign
        : (_rawDx >= 0 ? 1.0 : -1.0);
    _state = _MagneticState.idle;
    _rawDx = 0;
    _detachSign = 0;

    if (!shouldDismiss) {
      _baseTx = 0;
      if (reduceMotion) {
        _catchup.value = 0;
      } else {
        _catchup.animateWith(
          SpringSimulation(
            _attachSpring,
            current,
            0,
            velocityDx,
            tolerance: _tolerance,
            snapToEnd: true,
          ),
        );
      }
      setState(() {});
      return;
    }

    if (flungOut) HapticFeedback.mediumImpact();
    setState(() {
      _exiting = true;
      _exitStartTx = current;
      _exitDir = dir;
      _baseTx = 0;
      _catchup.value = 0;
    });
    if (reduceMotion) {
      _dismissController.value = 1;
    } else {
      await _dismissController.forward(from: 0).orCancel.catchError((_) {});
    }
    if (!mounted) return;
    final ok = widget.onDismiss();
    if (!ok && mounted) {
      setState(() => _exiting = false);
      _dismissController.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final content = AnimatedBuilder(
      animation: Listenable.merge([_catchup, _dismissController]),
      child: widget.child,
      builder: (context, child) => _buildSwipeChild(
        width: MediaQuery.sizeOf(context).width,
        exiting: _exiting,
        dismissAnimation: _dismissController,
        currentTx: _tx,
        exitStartTx: _exitStartTx,
        exitDir: _exitDir,
        child: child!,
      ),
    );

    if (!widget.clearable || _exiting) return content;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _onDragStart(),
      onHorizontalDragUpdate: (d) =>
          _onDragUpdate(d.delta.dx, reduceMotion: reduceMotion),
      onHorizontalDragEnd: (d) => _onDragEnd(
        d.velocity.pixelsPerSecond.dx,
        reduceMotion: reduceMotion,
      ),
      onHorizontalDragCancel: () =>
          _onDragEnd(0, reduceMotion: reduceMotion),
      child: content,
    );
  }
}
