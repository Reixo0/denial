part of 'notification_banner.dart';

/// A single mobile heads-up card. The top inset travels with the card, so its
/// starting position is above the screen rather than clipped at the safe area.
class MobileNotificationBannerView extends ConsumerStatefulWidget {
  const MobileNotificationBannerView({
    required this.notification,
    required this.onHide,
    super.key,
    this.previewMode = NotificationPreviewMode.full,
    this.interactive = true,
    this.onDismiss,
    this.onDefaultAction,
    this.onAction,
  });

  final DesktopNotification? notification;
  final NotificationPreviewMode previewMode;
  final bool interactive;
  final ValueChanged<int> onHide;
  final bool Function(int)? onDismiss;
  final bool Function(int)? onDefaultAction;
  final bool Function(int, String)? onAction;

  @override
  ConsumerState<MobileNotificationBannerView> createState() =>
      _MobileNotificationBannerViewState();
}

class _MobileNotificationBannerViewState
    extends ConsumerState<MobileNotificationBannerView> {
  /// AOSP: heads_up_status_bar_padding under the status bar, and
  /// notification_side_paddings at the sides, in dp.
  static const double _statusBarPadding = 8;
  static const double _sideMargin = 16;

  Timer? _timeout;

  /// HEADS_UP_SEEN_TIMEOUT: a heads-up shown 0.75 s has been seen, so the
  /// lock screen keeps it on the shelf.
  Timer? _seen;

  void _armSeen() {
    _seen?.cancel();
    final notification = widget.notification;
    if (notification == null) return;
    _seen = Timer(const Duration(milliseconds: 750), () {
      if (mounted) {
        ref
            .read(desktopNotificationsProvider.notifier)
            .markRead(notification.id);
      }
    });
  }

  bool _ready = false;

  /// Where the finger has carried the card, in dp: sideways to dismiss it,
  /// up to put it away.
  Offset _offset = Offset.zero;
  bool _dragging = false;
  Timer? _flyOff;

  /// The screen's width in dp, from the last layout.
  double _width = 400;

  /// Logical pixels per dp, from the last layout.
  double _scale = 1;

  /// What the finger is doing with the card since it went down.
  _HeadsUpDrag _drag = _HeadsUpDrag.undecided;

  /// Heads-ups the shade took over: they leave without the disappear
  /// animation, since the shade now shows them.
  final Set<int> _handedToShade = <int>{};

  /// The finger on the card, and the one the shade follows after the
  /// card hands over (the card's own detector goes with the heads-up).
  int? _pointer;
  int? _shadePointer;
  VelocityTracker? _shadeVelocity;

  /// One per card: the leaving and the arriving card are built together.
  final Map<int, GlobalKey> _cardKeys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _armTimeout();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void didUpdateWidget(covariant MobileNotificationBannerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.notification;
    final next = widget.notification;
    if (previous?.id != next?.id) {
      _cardKeys.removeWhere((id, _) => id != previous?.id && id != next?.id);
      _flyOff?.cancel();
      _offset = Offset.zero;
      _dragging = false;
    }
    // A quiet update keeps the banner's remaining time.
    if (previous?.id != next?.id ||
        (next != null && next.alert && !identical(previous, next))) {
      _armTimeout();
    }
  }

  void _armTimeout() {
    _armSeen();
    _timeout?.cancel();
    final notification = widget.notification;
    // A critical banner, such as a call ringing, stays until it is closed.
    if (notification == null ||
        notification.historyOnly ||
        notification.bannerDuration == null) {
      return;
    }
    // heads_up_notification_decay: 5 s.
    _timeout = Timer(const Duration(seconds: 5), () {
      if (mounted) widget.onHide(notification.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final notification = widget.notification;
    final duration =
        MediaQuery.disableAnimationsOf(context) ||
            widget.previewMode == NotificationPreviewMode.hidden
        ? Duration.zero
        // StackStateAnimator ANIMATION_DURATION_HEADS_UP_APPEAR and
        // _DISAPPEAR, 400 ms.
        : androidDuration(400);
    // Laid out in Android's dp, as the shade is.
    return PixelShadeViewport(
      child: Builder(
        builder: (context) {
          final padding = MediaQuery.viewPaddingOf(context);
          _width = MediaQuery.sizeOf(context).width;
          _scale = PixelShadeViewport.scaleOf(context);
          final top =
              padding.top +
              ReferenceShellMetrics.statusBarHeight /
                  PixelShadeViewport.scaleOf(context) +
              _statusBarPadding;
          return Align(
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: duration,
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                clipBehavior: Clip.none,
                children: [...previous, ?current],
              ),
              // The motion repaints only its own boundary, not the overlays
              // and chrome up to the root.
              transitionBuilder: (child, animation) => RepaintBoundary(
                child: AnimatedBuilder(
                  animation: animation,
                  child: child,
                  builder: (context, child) {
                    final exiting = animation.status == AnimationStatus.reverse;
                    final key = child?.key;
                    if (exiting &&
                        key is ValueKey<int> &&
                        _handedToShade.contains(key.value)) {
                      return const SizedBox.shrink();
                    }
                    // The banner takes input once it has arrived. A region
                    // that followed the motion would republish the native
                    // input layout on every frame of it.
                    return _HeadsUpAppear(
                      fraction: animation.value,
                      appearing: !exiting,
                      // heads_up_appear_y_above_screen: from 32 dp above the
                      // screen's top.
                      startOffset: -(top + 32),
                      child: ShellInputScope(
                        enabled:
                            animation.isCompleted &&
                            ShellInputScope.enabledOf(context),
                        child: IgnorePointer(
                          ignoring: exiting,
                          child: ExcludeSemantics(
                            excluding: exiting,
                            child: child,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              child: !_ready || notification == null || notification.historyOnly
                  ? const SizedBox.shrink()
                  : Padding(
                      key: ValueKey(notification.id),
                      padding: EdgeInsets.fromLTRB(
                        padding.left + _sideMargin,
                        top,
                        padding.right + _sideMargin,
                        // Room for the pinned elevation's shadow.
                        24,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: _card(notification),
                      ),
                    ),
            ),
          );
        },
      ),
    );
  }

  void _dragStart(DragStartDetails _) {
    _flyOff?.cancel();
    _timeout?.cancel();
    _drag = _HeadsUpDrag.undecided;
    setState(() => _dragging = true);
  }

  void _dragUpdate(
    DesktopNotification notification,
    DragUpdateDetails details,
  ) {
    final delta = details.delta;
    if (_drag == _HeadsUpDrag.undecided) {
      if (delta == Offset.zero) return;
      // HeadsUpTouchHelper: a downward drag on a pinned heads-up opens the
      // shade from the card's bottom edge, and the heads-up joins it.
      if (delta.dy > 0 && delta.dy.abs() > delta.dx.abs()) {
        final shade = ref.read(shadeExpansionProvider).current;
        final box = _cardKeys[notification.id]?.currentContext
            ?.findRenderObject();
        final height = box is RenderBox && box.hasSize
            ? box.localToGlobal(Offset(0, box.size.height)).dy
            : null;
        if (shade != null &&
            height != null &&
            shade.beginDrag(fromStatusBar: true)) {
          _drag = _HeadsUpDrag.shade;
          _handedToShade.add(notification.id);
          // setHeadsUpDraggingStartingHeight: the panel starts at the
          // card's bottom on the screen (logical pixels).
          shade.dragBy(height + delta.dy * _scale);
          setState(() {
            _dragging = false;
            _offset = Offset.zero;
          });
          final pointer = _pointer;
          if (pointer != null) {
            _shadePointer = pointer;
            _shadeVelocity = VelocityTracker.withKind(PointerDeviceKind.touch);
            GestureBinding.instance.pointerRouter.addRoute(
              pointer,
              _followShade,
            );
          }
          widget.onHide(notification.id);
          return;
        }
      }
      _drag = _HeadsUpDrag.card;
    }
    if (_drag == _HeadsUpDrag.shade) return;
    setState(() {
      final next = _offset + delta;
      // A pull down only gives a little; Android's card stays put.
      _offset = Offset(next.dx, next.dy > 0 ? next.dy * 0.3 : next.dy);
    });
  }

  /// The finger that pulled a heads-up into the shade, until it lifts.
  void _followShade(PointerEvent event) {
    final shade = ref.read(shadeExpansionProvider).current;
    if (event is PointerMoveEvent) {
      _shadeVelocity?.addPosition(event.timeStamp, event.position);
      shade?.dragBy(event.delta.dy);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      final velocity = event is PointerUpEvent
          ? _shadeVelocity?.getVelocity().pixelsPerSecond.dy ?? 0
          : 0.0;
      _stopFollowingShade();
      shade?.endDrag(velocity);
    }
  }

  void _stopFollowingShade() {
    final pointer = _shadePointer;
    if (pointer != null) {
      GestureBinding.instance.pointerRouter.removeRoute(pointer, _followShade);
    }
    _shadePointer = null;
    _shadeVelocity = null;
    _drag = _HeadsUpDrag.undecided;
  }

  void _dragEnd(DesktopNotification notification, DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond;
    if (_drag == _HeadsUpDrag.shade) return;
    _drag = _HeadsUpDrag.undecided;
    final width = _width;
    final sideways = _offset.dx.abs() > _offset.dy.abs();
    setState(() => _dragging = false);
    if (sideways &&
        (_offset.dx.abs() > width * 0.4 || velocity.dx.abs() > 800)) {
      // Off the side, then gone from history too.
      final direction = (_offset.dx == 0 ? velocity.dx : _offset.dx).sign;
      setState(() => _offset = Offset(direction * width, 0));
      _flyOff = Timer(const Duration(milliseconds: 200), () {
        if (!mounted) return;
        if (widget.onDismiss?.call(notification.id) != true) {
          setState(() => _offset = Offset.zero);
          _armTimeout();
        }
      });
      return;
    }
    if (!sideways && (_offset.dy < -24 || velocity.dy < -300)) {
      // Up: the heads-up goes, the notification stays in the shade.
      widget.onHide(notification.id);
      return;
    }
    setState(() => _offset = Offset.zero);
    _armTimeout();
  }

  Widget _card(DesktopNotification notification) {
    final interactive = widget.interactive;
    final width = _width;
    final card = Listener(
      onPointerDown: (event) => _pointer = event.pointer,
      child: RepaintBoundary(
        key: _cardKeys.putIfAbsent(notification.id, GlobalKey.new),
        child: Semantics(
          onDismiss: interactive ? () => widget.onHide(notification.id) : null,
          child: GestureDetector(
            onPanStart: interactive ? _dragStart : null,
            onPanUpdate: interactive
                ? (d) => _dragUpdate(notification, d)
                : null,
            onPanEnd: interactive ? (d) => _dragEnd(notification, d) : null,
            onPanCancel: interactive
                ? () {
                    // After a hand-over the shade drag runs on (_followShade).
                    if (_drag == _HeadsUpDrag.shade) return;
                    _drag = _HeadsUpDrag.undecided;
                    setState(() {
                      _dragging = false;
                      _offset = Offset.zero;
                    });
                    _armTimeout();
                  }
                : null,
            child: TweenAnimationBuilder<Offset>(
              tween: Tween<Offset>(end: _offset),
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              curve: Curves.fastOutSlowIn,
              builder: (context, offset, child) => Transform.translate(
                offset: offset,
                child: Opacity(
                  opacity: (1 - offset.dx.abs() / width).clamp(0.0, 1.0),
                  child: child,
                ),
              ),
              // The shadow and the rounded clip follow the appear animation's
              // outline (_HeadsUpAppear); the card's own background shows
              // through while its content fades in.
              child: _HeadsUpOutline(
                child: ColoredBox(
                  color: phoneSchemeOf(context).surfaceContainer,
                  child: _HeadsUpContentAlpha(
                    child: PixelNotificationCard(
                      notification: notification,
                      headsUp: true,
                      interactive: interactive,
                      previewMode: widget.previewMode,
                      onOpen: interactive && widget.onDefaultAction != null
                          ? () => widget.onDefaultAction!(notification.id)
                          : null,
                      onAction: interactive && widget.onAction != null
                          ? (key) => widget.onAction!(notification.id, key)
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return interactive
        ? ShellInputRegion(
            debugLabel: 'Mobile notification ${notification.id}',
            child: card,
          )
        : IgnorePointer(child: card);
  }

  @override
  void dispose() {
    if (_shadePointer != null) {
      _stopFollowingShade();
      ref.read(shadeExpansionProvider).current?.endDrag(0);
    }
    _timeout?.cancel();
    _seen?.cancel();
    _flyOff?.cancel();
    super.dispose();
  }
}

enum _HeadsUpDrag { undecided, card, shade }

/// AOSP's heads-up appear and disappear (StackStateAnimator with
/// ActivatableNotificationView's appear animation, as the phone's SystemUI
/// build has it, notificationAppearNonlinear on). [fraction] runs linearly in
/// time, 0 to 1 when [appearing], 1 to 0 when leaving.
///
/// Appearing, the card's top travels from [startOffset] dp above its place
/// with fast-out-slow-in, its outline grows down from the top (ClipSide
/// BOTTOM) on the same curve, and its content fades in over the last 45 %.
/// Leaving runs the same with FAST_OUT_SLOW_IN_REVERSE.
class _HeadsUpAppear extends StatelessWidget {
  const _HeadsUpAppear({
    required this.fraction,
    required this.appearing,
    required this.startOffset,
    required this.child,
  });

  final double fraction;
  final bool appearing;
  final double startOffset;
  final Widget child;

  static const Curve _reverse = Cubic(0.8, 0, 0.6, 1);

  @override
  Widget build(BuildContext context) {
    final curve = appearing ? Curves.fastOutSlowIn : _reverse;
    final f = fraction.clamp(0.0, 1.0);
    // The outline and content follow the appear fraction through the curve.
    final shown = curve.transform(f);
    // ALPHA_APPEAR_START_FRACTION 0.55 to ALPHA_APPEAR_END_FRACTION 1.
    final alpha = curve.transform(((f - 0.55) / 0.45).clamp(0.0, 1.0));
    // translationY runs in time: forward when appearing, and back up when
    // leaving.
    final travelled = appearing ? shown : 1 - curve.transform(1 - f);
    return Transform.translate(
      offset: Offset(0, startOffset * (1 - travelled)),
      child: _HeadsUpAppearScope(shown: shown, alpha: alpha, child: child),
    );
  }
}

class _HeadsUpAppearScope extends InheritedWidget {
  const _HeadsUpAppearScope({
    required this.shown,
    required this.alpha,
    required super.child,
  });

  final double shown;
  final double alpha;

  static _HeadsUpAppearScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_HeadsUpAppearScope>();

  @override
  bool updateShouldNotify(_HeadsUpAppearScope oldWidget) =>
      shown != oldWidget.shown || alpha != oldWidget.alpha;
}

/// The card's outline during the appear animation: the rounded clip and the
/// pinned elevation's shadow cover only its top [_HeadsUpAppearScope.shown].
class _HeadsUpOutline extends StatelessWidget {
  const _HeadsUpOutline({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shown = _HeadsUpAppearScope.of(context)?.shown ?? 1;
    return CustomPaint(
      painter: _HeadsUpShadowPainter(shown),
      child: ClipPath(clipper: _HeadsUpOutlineClipper(shown), child: child),
    );
  }
}

RRect _headsUpOutline(Size size, double shown) => RRect.fromRectAndRadius(
  Rect.fromLTWH(0, 0, size.width, size.height * shown),
  const Radius.circular(PixelNotificationMetrics.radius),
);

class _HeadsUpOutlineClipper extends CustomClipper<Path> {
  const _HeadsUpOutlineClipper(this.shown);

  final double shown;

  @override
  Path getClip(Size size) => Path()..addRRect(_headsUpOutline(size, shown));

  @override
  bool shouldReclip(_HeadsUpOutlineClipper oldClipper) =>
      oldClipper.shown != shown;
}

class _HeadsUpShadowPainter extends CustomPainter {
  const _HeadsUpShadowPainter(this.shown);

  final double shown;

  // heads_up_pinned_elevation: 16 dp.
  static const BoxShadow _shadow = BoxShadow(
    color: Color(0x40000000),
    blurRadius: 16,
    offset: Offset(0, 6),
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (shown <= 0) return;
    canvas.drawRRect(
      _headsUpOutline(size, shown).shift(_shadow.offset),
      _shadow.toPaint(),
    );
  }

  @override
  bool shouldRepaint(_HeadsUpShadowPainter oldDelegate) =>
      oldDelegate.shown != shown;
}

/// The card's content alpha during the appear animation.
class _HeadsUpContentAlpha extends StatelessWidget {
  const _HeadsUpContentAlpha({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final alpha = _HeadsUpAppearScope.of(context)?.alpha ?? 1;
    // Always the same wrapper, so the card keeps its state.
    return Opacity(opacity: alpha, child: child);
  }
}
