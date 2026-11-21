part of 'notification_banner.dart';

/// A single mobile heads-up card. The top inset travels with the card, so its
/// starting position is above the screen rather than clipped at the safe area.
class MobileNotificationBannerView extends StatefulWidget {
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
  State<MobileNotificationBannerView> createState() =>
      _MobileNotificationBannerViewState();
}

class _MobileNotificationBannerViewState
    extends State<MobileNotificationBannerView> {
  /// AOSP: heads_up_status_bar_padding under the status bar, and
  /// notification_side_paddings at the sides, in dp.
  static const double _statusBarPadding = 8;
  static const double _sideMargin = 16;

  Timer? _timeout;
  bool _ready = false;

  /// Where the finger has carried the card, in dp: sideways to dismiss it,
  /// up to put it away.
  Offset _offset = Offset.zero;
  bool _dragging = false;
  Timer? _flyOff;

  /// The screen's width in dp, from the last layout.
  double _width = 400;

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
        : Motion.mobileNotificationBanner;
    // Laid out in Android's dp, as the shade is.
    return PixelShadeViewport(
      child: Builder(
        builder: (context) {
          final padding = MediaQuery.viewPaddingOf(context);
          _width = MediaQuery.sizeOf(context).width;
          final top =
              padding.top +
              ReferenceShellMetrics.statusBarHeight /
                  PixelShadeViewport.scaleOf(context) +
              _statusBarPadding;
          return Align(
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: duration,
              switchInCurve: Curves.fastOutSlowIn,
              switchOutCurve: const FlippedCurve(Curves.fastOutSlowIn),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                clipBehavior: Clip.none,
                children: [...previous, ?current],
              ),
              // The slide repaints only its own boundary, not the overlays
              // and chrome up to the root.
              transitionBuilder: (child, animation) => RepaintBoundary(
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -1),
                    end: Offset.zero,
                  ).animate(animation),
                  child: AnimatedBuilder(
                    animation: animation,
                    child: child,
                    builder: (context, child) {
                      final exiting =
                          animation.status == AnimationStatus.reverse;
                      // The banner takes input once it has arrived. A region
                      // that followed the slide would republish the native
                      // input layout on every frame of it.
                      return ShellInputScope(
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
                      );
                    },
                  ),
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
    setState(() => _dragging = true);
  }

  void _dragUpdate(DragUpdateDetails details) {
    setState(() {
      final next = _offset + details.delta;
      // A pull down only gives a little; Android's card stays put.
      _offset = Offset(next.dx, next.dy > 0 ? next.dy * 0.3 : next.dy);
    });
  }

  void _dragEnd(DesktopNotification notification, DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond;
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
    final card = RepaintBoundary(
      child: Semantics(
        onDismiss: interactive ? () => widget.onHide(notification.id) : null,
        child: GestureDetector(
          onPanStart: interactive ? _dragStart : null,
          onPanUpdate: interactive ? _dragUpdate : null,
          onPanEnd: interactive ? (d) => _dragEnd(notification, d) : null,
          onPanCancel: interactive
              ? () {
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
            child: DecoratedBox(
              // heads_up_pinned_elevation: 16 dp.
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  PixelNotificationMetrics.radius,
                ),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 16,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(
                  PixelNotificationMetrics.radius,
                ),
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
    _timeout?.cancel();
    _flyOff?.cancel();
    super.dispose();
  }
}
