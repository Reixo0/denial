import 'package:denial_desktop/src/state/app_deck.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:motor/motor.dart' as motor;

import 'package:denial_flutter_sdk/effects.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/rendering.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';

import '../phone_scheme.dart';
import 'overview_card_label.dart';
import 'overview_geometry.dart';
import 'overview_chrome.dart';

/// Draws the open apps wherever the [deck] has them, while it presents:
/// switching, lifting into recents, recents itself, a card opening, and
/// recents leaving for home. At rest with an app filling the screen it draws
/// nothing, and the app's own stage shows the app.
///
/// In recents a tap opens a card, a card swiped up closes its app, a
/// sideways drag scrolls the row, and a tap beside the cards goes home.
class AppDeckLayer extends StatefulWidget {
  const AppDeckLayer({
    super.key,
    required this.deck,
    required this.windows,
    required this.recents,
    this.backdrop,
    required this.onPresentationChanged,
    this.onProgressChanged,
    required this.onCloseRecents,
    required this.onDismissWindow,
    required this.onOpenWindow,
    this.onMoveWindowToDesk,
    this.onScreenshot,
  });

  final AppDeck deck;

  /// The open apps.
  final List<DenialWindow> windows;

  /// Recents is open or opening, and takes touches.
  final bool recents;

  /// The scene behind recents, frosted once. Translucent apps draw slices of
  /// it as their glass instead of filtering the scene on every frame.
  final ValueListenable<FrostedBackdrop?>? backdrop;
  final ValueChanged<bool> onPresentationChanged;

  /// How far recents is open, for the launcher beneath.
  final ValueChanged<double>? onProgressChanged;
  final VoidCallback onCloseRecents;
  final ValueChanged<DenialWindow> onDismissWindow;
  final ValueChanged<DenialWindow> onOpenWindow;

  /// Moves an app to the monitor beside the phone; none without a monitor.
  final ValueChanged<DenialWindow>? onMoveWindowToDesk;

  /// Android's Screenshot action under the cards: takes the centred app.
  final ValueChanged<DenialWindow>? onScreenshot;

  @override
  State<AppDeckLayer> createState() => _AppDeckLayerState();
}

class _AppDeckLayerState extends State<AppDeckLayer>
    with SingleTickerProviderStateMixin {
  /// How far a fling carries the recents row, in seconds of its speed.
  static const double _rowFlingProjection = 0.35;

  /// A fling coasts to its card for at least this long, in seconds; a card
  /// nearer than that is passed for the next one. Slower than the longest,
  /// a release springs to the nearest card instead.
  static const double _shortestGlide = 0.3;
  static const double _longestGlide = 1.1;

  final _open = ValueNotifier(0.0);
  late final Animation<double> _openAnimation = Animation.fromValueListenable(
    _open,
  );

  /// Recents' own look: the blur and scrim behind the cards, the app chips
  /// and the actions. As in Launcher3 they come with the overview state, on
  /// release, not while a finger lifts the app.
  late final AnimationController _chrome = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    value: widget.recents ? 1 : 0,
  );
  late final Animation<double> _scrimOpacity = CurvedAnimation(
    parent: _chrome,
    curve: Curves.easeOut,
  );
  late final Animation<double> _labelOpacity = CurvedAnimation(
    parent: _chrome,
    curve: const Interval(0.5, 1, curve: Curves.easeOut),
  );
  var _windows = <int, DenialWindow>{};

  /// Fires Clear all for the cards on screen.
  final _clearAll = ValueNotifier(0);
  final _poses = <int, ValueNotifier<WindowPose>>{};

  /// The apps drawn, back to front.
  List<int> _drawn = const <int>[];
  bool _presenting = false;

  bool _rowDragging = false;
  double _rowDrag = 0;

  /// A touch stopped the recents row where it was.
  bool _rowCaught = false;

  @override
  void initState() {
    super.initState();
    _indexWindows();
    widget.deck.addListener(_update);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = context.shellTheme;
    final size = MediaQuery.sizeOf(context);
    final geometry = DeckGeometry(
      size: size,
      padding: MediaQuery.paddingOf(context),
      // Android rounds a recents task with the display's corner radius
      // (QuickStepContract.getWindowCornerRadius): 82 px on the Pixel
      // emulator at this size, 28 dp.
      windowRadius: size.width > size.height
          ? theme.windowRadius
          : 28 * overviewDpFor(size),
      switchRadius: theme.scaledRadius(18),
      ltr: Directionality.of(context) == TextDirection.ltr,
    );
    if (geometry != widget.deck.geometry) {
      widget.deck.geometry = geometry;
      WidgetsBinding.instance.addPostFrameCallback((_) => _update());
    }
  }

  @override
  void didUpdateWidget(covariant AppDeckLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.deck != oldWidget.deck) {
      oldWidget.deck.removeListener(_update);
      widget.deck.addListener(_update);
    }
    if (!identical(widget.windows, oldWidget.windows)) _indexWindows();
    if (!widget.recents) _endRowDrag(null);
    if (widget.recents != oldWidget.recents) {
      widget.recents ? _chrome.forward() : _chrome.reverse();
    }
  }

  @override
  void dispose() {
    widget.deck.removeListener(_update);
    for (final pose in _poses.values) {
      pose.dispose();
    }
    _open.dispose();
    _chrome.dispose();
    _clearAll.dispose();
    super.dispose();
  }

  void _indexWindows() {
    _windows = {for (final window in widget.windows) window.objectId: window};
    _poses.removeWhere((id, pose) {
      if (_windows.containsKey(id)) return false;
      WidgetsBinding.instance.addPostFrameCallback((_) => pose.dispose());
      return true;
    });
  }

  /// Poses every app from the deck's values, and draws those on screen with
  /// the one nearest the screen's centre in front.
  void _update() {
    if (!mounted) return;
    final deck = widget.deck;
    final shown = deck.shown;
    _open.value = shown;
    widget.onProgressChanged?.call(shown);
    final presenting = deck.presenting.value;
    final geometry = deck.geometry;
    final drawn = <(int, double)>[];
    if (presenting && !geometry.isEmpty) {
      final screen = geometry.screen;
      final row = deck.row.value;
      for (final id in deck.order) {
        if (id == deck.hidden || !_windows.containsKey(id)) continue;
        final slot = deck.slotOf(id);
        final pose = deck.poseOf(id);
        (_poses[id] ??= ValueNotifier(pose)).value = pose;
        if (pose.rect.overlaps(screen)) drawn.add((id, (slot - row).abs()));
      }
      drawn.sort((a, b) => b.$2.compareTo(a.$2));
    }
    final ids = [for (final (id, _) in drawn) id];
    if (presenting != _presenting) {
      widget.onPresentationChanged(presenting);
    }
    if (presenting != _presenting || !listEquals(ids, _drawn)) {
      setState(() {
        _presenting = presenting;
        _drawn = ids;
      });
    }
  }

  // The recents row under the finger --------------------------------------

  void _catchRow(PointerDownEvent event) {
    final row = widget.deck.row;
    if (!widget.recents || !row.moving || row.held) return;
    row.grab();
    _rowCaught = true;
  }

  void _releaseCatch(PointerEvent event) {
    if (!_rowCaught || _rowDragging) return;
    _rowCaught = false;
    final row = widget.deck.row;
    if (row.held) {
      row.settle(_nearestCard(row.value), ShellSprings.appStrip);
    }
  }

  void _startRowDrag(DragStartDetails details) {
    final deck = widget.deck;
    if (!widget.recents || deck.geometry.landscape || deck.length == 0) {
      return;
    }
    if (!deck.row.held) deck.row.grab();
    _rowDragging = true;
    _rowCaught = false;
    _rowDrag = 0;
  }

  void _moveRow(DragUpdateDetails details) {
    if (!_rowDragging) return;
    final deck = widget.deck;
    _rowDrag += details.delta.dx;
    final position = deck.row.grabbedAt + deck.geometry.rowDelta(_rowDrag, 1);
    deck.row.hold(_stretch(position));
  }

  /// A fling coasts on to the card nearest where it would come to rest, or
  /// runs past the first or last card and bounces back; a slow release
  /// springs to the nearest card.
  void _endRowDrag(DragEndDetails? details) {
    if (!_rowDragging) return;
    _rowDragging = false;
    final deck = widget.deck;
    final row = deck.row;
    final rate = deck.geometry.rowDelta(
      details?.velocity.pixelsPerSecond.dx ?? 0,
      1,
    );
    final last = math.max(0, deck.length - 1).toDouble();
    var target = (row.value + rate * _rowFlingProjection).roundToDouble();
    if (row.glideTime(target, rate) < _shortestGlide) target += rate.sign;
    if (target < 0 || target > last) {
      // Already past the end, the stretch springs back on its own.
      final outside = row.value < 0 || row.value > last;
      row.settle(
        target < 0 ? 0.0 : last,
        ShellSprings.recentsEdge,
        velocity: outside ? 0 : rate,
      );
    } else if (row.glideTime(target, rate) <= _longestGlide) {
      row.glide(target, rate);
    } else {
      row.settle(
        _nearestCard(row.value),
        ShellSprings.appStrip,
        velocity: rate,
      );
    }
  }

  /// Clear all: the cards on screen fly up and away, closing their apps;
  /// the rest close at once. Recents with no app left goes home.
  void _clearAllApps() {
    final shown = _drawn.toSet();
    for (final window in _windows.values.toList()) {
      if (!shown.contains(window.objectId)) widget.onDismissWindow(window);
    }
    _clearAll.value++;
  }

  /// The app whose card is in the middle of the row.
  void _screenshot() {
    final deck = widget.deck;
    final onScreenshot = widget.onScreenshot;
    if (onScreenshot == null || deck.length == 0) return;
    final row = deck.row.value.round();
    for (final id in deck.order) {
      if (deck.slotOf(id).round() == row) {
        final window = _windows[id];
        if (window != null) onScreenshot(window);
        return;
      }
    }
  }

  double _nearestCard(double position) =>
      position.roundToDouble().clamp(0.0, math.max(0, widget.deck.length - 1));

  /// Past the first and last card the row stretches elastically.
  double _stretch(double position) {
    final deck = widget.deck;
    final last = math.max(0, deck.length - 1).toDouble();
    final edge = position.clamp(0.0, last).toDouble();
    final stride = deck.geometry.strideAt(1);
    final extent = deck.geometry.size.width;
    final past = (position - edge) * stride;
    if (past == 0 || stride <= 0 || extent <= 0) return edge;
    const resistance = 0.55;
    final stretch = 1 - 1 / (past.abs() * resistance / extent + 1);
    return edge + past.sign * stretch * extent / stride;
  }

  @override
  Widget build(BuildContext context) {
    if (!_presenting) return const SizedBox.shrink();
    final deck = widget.deck;
    final geometry = deck.geometry;
    final interactive = widget.recents;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !interactive,
        child: Listener(
          onPointerDown: _catchRow,
          onPointerUp: _releaseCatch,
          onPointerCancel: _releaseCatch,
          child: GestureDetector(
            onHorizontalDragStart: _startRowDrag,
            onHorizontalDragUpdate: _moveRow,
            onHorizontalDragEnd: _endRowDrag,
            onHorizontalDragCancel: () => _endRowDrag(null),
            child: ValueListenableBuilder<FrostedBackdrop?>(
              valueListenable:
                  widget.backdrop ??
                  const AlwaysStoppedAnimation<FrostedBackdrop?>(null),
              builder: (context, backdrop, stack) => WindowBackdropCache(
                backdrop: backdrop,
                motion: deck,
                overlayColor: OverviewScrim.colorOf(context),
                overlayOpacity: _scrimOpacity,
                child: stack!,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Android blurs what is behind recents at depth 0.7 of the
                  // launcher's 30 dp (about 0.62 of the shade's blur) under
                  // overviewScrimColorBlur, both growing as recents opens.
                  AnimatedBuilder(
                    animation: _scrimOpacity,
                    builder: (context, scrim) => ShellBackdropBlur(
                      edgeless: true,
                      strength: (0.62 * _scrimOpacity.value).clamp(0.0, 1.0),
                      borderRadius: BorderRadius.zero,
                      child: scrim!,
                    ),
                    child: OverviewScrim(
                      opacity: _scrimOpacity,
                      onTap: widget.onCloseRecents,
                    ),
                  ),
                  if (deck.length == 0)
                    EmptyOverviewState(progress: _openAnimation),
                  for (final id in _drawn)
                    if ((_windows[id], _poses[id]) case (
                      final window?,
                      final pose?,
                    ))
                      _DeckCard(
                        key: ValueKey<int>(id),
                        window: window,
                        pose: pose,
                        dp: overviewDpFor(geometry.size),
                        ltr: geometry.ltr,
                        labelOpacity: geometry.landscape ? null : _labelOpacity,
                        onOpen: widget.onOpenWindow,
                        onDismissed: widget.onDismissWindow,
                        onMoveToDesk: widget.onMoveWindowToDesk,
                        onScreenshot: widget.onScreenshot,
                        clearAll: _clearAll,
                      ),
                  if (!geometry.landscape &&
                      deck.length > 0 &&
                      widget.onScreenshot != null)
                    Positioned.fromRect(
                      rect: overviewActionsRectFor(
                        geometry.size,
                        geometry.card,
                      ),
                      child: FadeTransition(
                        opacity: _labelOpacity,
                        // Android's Screenshot, and the owner's Clear all
                        // beside it, 16 dp apart (overview_actions_button_
                        // spacing).
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _OverviewAction(
                              dp: overviewDpFor(geometry.size),
                              icon: Icons.crop_free_rounded,
                              label: context.l10n.overviewScreenshot,
                              onTap: _screenshot,
                            ),
                            SizedBox(width: 16 * overviewDpFor(geometry.size)),
                            _OverviewAction(
                              dp: overviewDpFor(geometry.size),
                              icon: Icons.clear_all_rounded,
                              label: context.l10n.overviewClearAll,
                              onTap: _clearAllApps,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One app as the deck poses it. In recents it is a card: a tap opens it,
/// and a swipe up throws it away.
class _DeckCard extends StatefulWidget {
  const _DeckCard({
    super.key,
    required this.window,
    required this.pose,
    required this.dp,
    required this.ltr,
    required this.labelOpacity,
    required this.onOpen,
    required this.onDismissed,
    this.onMoveToDesk,
    this.onScreenshot,
    required this.clearAll,
  });

  final DenialWindow window;
  final ValueListenable<WindowPose> pose;

  /// Takes the app's screenshot, from its chip's menu.
  final ValueChanged<DenialWindow>? onScreenshot;

  /// Clear all: every card on screen is thrown away when it fires.
  final Listenable clearAll;

  /// Logical pixels per Android dp.
  final double dp;
  final bool ltr;

  /// The app chip over the card; none without it.
  final Animation<double>? labelOpacity;
  final ValueChanged<DenialWindow> onOpen;
  final ValueChanged<DenialWindow> onDismissed;
  final ValueChanged<DenialWindow>? onMoveToDesk;

  @override
  State<_DeckCard> createState() => _DeckCardState();
}

class _DeckCardState extends State<_DeckCard> with TickerProviderStateMixin {
  // Android 16 TaskViewDismissTouchController: half the off-screen travel,
  // 25dp undershoot, and BaseSwipeDetector's 1dp/ms release threshold.
  static const double _downwardRubberBandLimit = 25.0;
  static const double _dismissDistanceRatio = 0.5;
  static const double _dismissFlingVelocity = 1000.0;
  static const double _offscreenMargin = 16.0;

  /// A card swiped away shrinks as it leaves.
  static const double _dismissShrink = 0.1;

  /// How far the card is thrown up, in logical pixels, negative upward.
  late final motor.SingleMotionController _throw;
  late final _CardPose _pose;
  double _drag = 0;
  double _exit = -double.maxFinite;
  bool _leaving = false;
  bool _dismissed = false;

  /// The chip's menu: the chip grows into its header as the menu opens.
  late final AnimationController _menu = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  late final Animation<double> _menuCurve = CurvedAnimation(
    parent: _menu,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    widget.clearAll.addListener(_throwAway);
    _throw = motor.SingleMotionController(
      motion: ShellSprings.cardReturn,
      vsync: this,
      initialValue: 0,
    )..addListener(_checkGone);
    _pose = _CardPose(widget.pose, _throw, dp: widget.dp, ltr: widget.ltr);
  }

  @override
  void didUpdateWidget(covariant _DeckCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pose != oldWidget.pose) _pose.base = widget.pose;
    if (widget.clearAll != oldWidget.clearAll) {
      oldWidget.clearAll.removeListener(_throwAway);
      widget.clearAll.addListener(_throwAway);
    }
    _pose
      ..dp = widget.dp
      ..ltr = widget.ltr;
  }

  @override
  void dispose() {
    widget.clearAll.removeListener(_throwAway);
    _menu.dispose();
    _pose.dispose();
    _throw.dispose();
    super.dispose();
  }

  /// Throws the card up and away, closing its app (Clear, Clear all).
  void _throwAway() {
    if (_leaving) return;
    _menu.reverse();
    _leaving = true;
    _pose.length = math.max(
      1.0,
      _pose.base.value.rect.bottom + _offscreenMargin,
    );
    _exit = -_pose.length;
    _throw
      ..motion = ShellSprings.cardDismiss
      ..animateTo(_exit, withVelocity: -_dismissFlingVelocity);
  }

  void _closeMenu() => _menu.reverse();

  void _toggleMenu() {
    if (_leaving) return;
    if (_menu.isDismissed || _menu.status == AnimationStatus.reverse) {
      _menu.forward();
    } else {
      _menu.reverse();
    }
  }

  List<({IconData icon, String label, VoidCallback onTap})> _menuItems(
    BuildContext context,
  ) {
    final l10n = context.l10n;
    final onScreenshot = widget.onScreenshot;
    final onMoveToDesk = widget.onMoveToDesk;
    return [
      if (onScreenshot != null)
        (
          icon: Icons.crop_free_rounded,
          label: l10n.overviewScreenshot,
          onTap: () {
            _closeMenu();
            onScreenshot(widget.window);
          },
        ),
      if (onMoveToDesk != null)
        (
          icon: Icons.desktop_windows_rounded,
          label: l10n.moveToMonitor,
          onTap: () {
            _closeMenu();
            onMoveToDesk(widget.window);
          },
        ),
      (icon: Icons.close_rounded, label: l10n.overviewClear, onTap: _throwAway),
    ];
  }

  void _startDrag(DragStartDetails details) {
    if (_leaving) return;
    _menu.reverse();
    _throw.stop(canceled: true);
    _pose.length = math.max(
      1.0,
      _pose.base.value.rect.bottom + _offscreenMargin,
    );
    final value = _throw.value;
    final length = _pose.length;
    // Continue from where the card is, also inside its downward stretch.
    _drag = value <= 0
        ? value
        : length *
              (1 -
                  math.sqrt(
                    1 - (value / _downwardRubberBandLimit).clamp(0.0, 1.0),
                  ));
  }

  void _moveDrag(DragUpdateDetails details) {
    if (_leaving) return;
    _drag += details.delta.dy;
    final length = _pose.length;
    if (_drag <= 0) {
      _throw.value = _drag.clamp(-length, 0.0);
    } else {
      // Resistance unwinds smoothly when the finger reverses.
      final fraction = (_drag / length).clamp(0.0, 1.0);
      _throw.value =
          _downwardRubberBandLimit * Curves.decelerate.transform(fraction);
    }
  }

  void _endDrag(DragEndDetails details) {
    if (_leaving) return;
    final velocity = details.velocity.pixelsPerSecond.dy.clamp(-8000.0, 8000.0);
    final passed = _throw.value < -_pose.length * _dismissDistanceRatio;
    final flingUp = velocity < -_dismissFlingVelocity;
    final flingDown = velocity > _dismissFlingVelocity;
    // The release's direction comes before distance: thrown back down, a
    // card returns even past the threshold.
    if (flingUp || (passed && !flingDown)) {
      _leaving = true;
      _exit = -_pose.length;
      _throw
        ..motion = ShellSprings.cardDismiss
        ..animateTo(_exit, withVelocity: velocity);
    } else {
      _settleBack(velocity);
    }
  }

  void _settleBack([double velocity = 0]) {
    if (_leaving) return;
    _throw
      ..motion = ShellSprings.cardReturn
      ..animateTo(0, withVelocity: velocity);
  }

  /// The app closes as soon as its card has left the screen; the spring's
  /// tail past that would only delay it.
  void _checkGone() {
    if (!_leaving || _dismissed || _throw.value > _exit + _offscreenMargin) {
      return;
    }
    _dismissed = true;
    final window = widget.window;
    // Present this last frame before releasing the app's surface.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _throw.stop(canceled: true);
      widget.onDismissed(window);
    });
  }

  @override
  Widget build(BuildContext context) {
    final labelOpacity = widget.labelOpacity;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: WindowBackdropMotion(
            motion: _pose,
            child: PosedWindow(
              pose: _pose,
              child: WindowSurface(
                window: widget.window,
                contentPadding: EdgeInsets.only(
                  top: ReferenceShellMetrics.appStatusInset(
                    MediaQuery.sizeOf(context),
                  ),
                ),
              ),
            ),
          ),
        ),
        _PoseHitRegion(
          pose: _pose,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (!_leaving) widget.onOpen(widget.window);
            },
            onVerticalDragStart: _startDrag,
            onVerticalDragUpdate: _moveDrag,
            onVerticalDragEnd: _endDrag,
            onVerticalDragCancel: _settleBack,
          ),
        ),
        // While the menu is open a tap anywhere else only closes it.
        AnimatedBuilder(
          animation: _menu,
          builder: (context, _) => _menu.isDismissed
              ? const SizedBox.shrink()
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closeMenu,
                  onVerticalDragStart: (_) => _closeMenu(),
                ),
        ),
        if (labelOpacity != null)
          // The translation spans the deck, so taps on the chip and its menu
          // are tested where they are drawn.
          Positioned.fill(
            child: CompositedTranslation(
              translation: _pose.label,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              child: FadeTransition(
                opacity: labelOpacity,
                child: AnimatedBuilder(
                  animation: _menuCurve,
                  builder: (context, _) => _chipAndMenu(context),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _chipAndMenu(BuildContext context) {
    final dp = widget.dp;
    final open = _menuCurve.value;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          top: 0,
          width: OverviewCardLabel.boxWidthDp * dp,
          height: OverviewCardLabel.boxHeightDp * dp,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleMenu,
            child: OverviewCardLabel(
              window: widget.window,
              dp: dp,
              expansion: open,
            ),
          ),
        ),
        if (open > 0)
          Positioned(
            left: 0,
            top: (OverviewCardLabel.boxHeightDp + OverviewTaskMenu.gapDp) * dp,
            child: IgnorePointer(
              ignoring: _menu.status != AnimationStatus.completed,
              child: Opacity(
                opacity: open,
                child: ClipRect(
                  child: Align(
                    alignment: Alignment.topCenter,
                    heightFactor: open,
                    child: OverviewTaskMenu(dp: dp, items: _menuItems(context)),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The deck's pose of a card, thrown up and shrinking as it leaves.
class _CardPose extends ChangeNotifier implements ValueListenable<WindowPose> {
  _CardPose(this._base, this._throw, {required this.dp, required this.ltr}) {
    _base.addListener(_changed);
    _throw.addListener(_changed);
    _changed();
  }

  ValueListenable<WindowPose> _base;
  final Animation<double> _throw;

  /// How far the card travels to leave the screen.
  double length = 1;

  /// Logical pixels per Android dp.
  double dp;
  bool ltr;

  /// Where the card's app chip goes: inside its top start corner.
  final label = ValueNotifier(Offset.zero);

  ValueListenable<WindowPose> get base => _base;
  set base(ValueListenable<WindowPose> value) {
    if (identical(value, _base)) return;
    _base.removeListener(_changed);
    _base = value..addListener(_changed);
    _changed();
  }

  @override
  WindowPose get value {
    final pose = _base.value;
    final dy = _throw.value;
    if (dy == 0) return pose;
    final shrink =
        1 - _DeckCardState._dismissShrink * (-dy / length).clamp(0.0, 1.0);
    final rect = pose.rect;
    return WindowPose(
      Rect.fromCenter(
        center: rect.center.translate(0, dy),
        width: rect.width * shrink,
        height: rect.height * shrink,
      ),
      pose.radius * shrink,
      opacity: pose.opacity,
    );
  }

  void _changed() {
    final rect = value.rect;
    final inset = OverviewCardLabel.insetDp * dp;
    final box = OverviewCardLabel.boxWidthDp * dp;
    label.value = Offset(
      ltr ? rect.left + inset : rect.right - inset - box,
      rect.top + inset,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _base.removeListener(_changed);
    _throw.removeListener(_changed);
    label.dispose();
    super.dispose();
  }
}

/// Takes touches only inside its [pose], in the screen's coordinates.
class _PoseHitRegion extends SingleChildRenderObjectWidget {
  const _PoseHitRegion({required this.pose, super.child});

  final ValueListenable<WindowPose> pose;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPoseHitRegion(pose);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPoseHitRegion).pose = pose;
  }
}

class _RenderPoseHitRegion extends RenderProxyBox {
  _RenderPoseHitRegion(this.pose);

  ValueListenable<WindowPose> pose;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final current = pose.value;
    if (current.opacity <= 0 ||
        !RRect.fromRectAndRadius(
          current.rect,
          Radius.circular(current.radius),
        ).contains(position)) {
      return false;
    }
    return super.hitTest(result, position: position);
  }
}

/// One of Android's overview actions (OverviewActionButton.Blur): a 48 dp
/// pill in customColorSurfaceEffect1 with a 24 dp icon, 8 dp, and 14 sp
/// text at weight 600, 16 dp in from each side.
class _OverviewAction extends StatelessWidget {
  const _OverviewAction({
    required this.dp,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final double dp;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 48 * dp,
          padding: EdgeInsets.symmetric(horizontal: 16 * dp),
          decoration: BoxDecoration(
            color: scheme.surfaceEffect1,
            borderRadius: BorderRadius.circular(28 * dp),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24 * dp, color: scheme.onSurface),
              SizedBox(width: 8 * dp),
              Text(
                label,
                maxLines: 1,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: 14 * dp * phoneTextScale,
                  fontWeight: FontWeight.w600,
                  height: 1,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
