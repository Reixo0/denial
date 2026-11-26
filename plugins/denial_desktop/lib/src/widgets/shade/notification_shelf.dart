import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/widgets.dart';

import 'package:denial_flutter_sdk/models.dart' show DesktopNotification;

import '../notification_media.dart'
    show NotificationAppIcon, NotificationSmallIcon;
import '../phone_scheme.dart';
import '../notification_banner.dart' show PixelNotificationMetrics;
import 'shade_expansion_motion.dart' show androidDuration;
import 'notification_shade_list.dart'
    show AndroidStackExpansion, NotificationShadeList;
import 'shade_card_blur.dart';

/// The end of Android's notification stack for one frame: where the rows are
/// cut, and the shelf.
class NotificationShelfFrame {
  const NotificationShelfFrame({
    required this.open,
    required this.squish,
    required this.shift,
    required this.stackBottom,
    required this.starts,
    required this.shelfTop,
    required this.icons,
  });

  /// The shade's expansion and how it compresses and lifts the stack
  /// ([NotificationShadeList]).
  final double open;
  final double squish;
  final double shift;

  /// Where the stack ends, resting.
  final double stackBottom;

  /// The tops of the rows that are laid out, by index, resting.
  final Map<int, double> starts;

  /// The shelf's top as drawn; null while it is hidden.
  final double? shelfTop;

  /// How much of each row's icon the shelf shows.
  final List<double> icons;

  /// Where the rows are cut: 2 dp above the shelf, or at the stack's end (a
  /// hidden shelf waits there), so that a last row cut to the shelf's height
  /// looks as the shelf does.
  double get clipEnd => shelfTop == null
      ? stackBottom * squish - shift
      : shelfTop! - PixelNotificationMetrics.divider;

  /// The part of row [index] that shows. Within 48 dp of the shelf its
  /// corners round (updateCornerRoundnessOnScroll), and where it is cut it
  /// ends in them.
  RRect clipRow(int index, Size size, BorderRadius own) {
    var height = size.height * squish;
    var top = own.topLeft.x;
    var bottom = own.bottomLeft.x;
    final start = starts[index];
    if (start != null) {
      final y = start * squish - shift;
      final distance = _cornerDistance * open;
      double rounded(double at) {
        if (distance <= 0) return 0;
        final from = clipEnd + PixelNotificationMetrics.divider - distance;
        return lerpDouble(
          PixelNotificationMetrics.innerRadius,
          PixelNotificationMetrics.radius,
          ((at - from) / distance).clamp(0.0, 1.0),
        )!;
      }

      top = math.max(top, rounded(y));
      bottom = math.max(bottom, rounded(y + height));
      height = math.min(height, math.max(0, clipEnd - y));
    }
    return BorderRadius.vertical(
      top: Radius.circular(top),
      bottom: Radius.circular(bottom),
    ).toRRect(Offset.zero & Size(size.width, height));
  }

  /// notification_corner_animation_distance.
  static const double _cornerDistance = 48;
}

/// Reads [NotificationShelfFrame] while painting, when the rows have their
/// places for the frame.
class NotificationShelfGeometry {
  NotificationShelfGeometry({
    required this.list,
    required this.rows,
    required this.count,
    required this.progress,
    required this.topPadding,
  });

  /// notification_shelf_height.
  static const double height = 48;

  /// The stack ends this far above the bottom of the screen on EvolutionX.
  static const double bottomMargin = 32;

  /// The box the shelf and the rows are in.
  final RenderBox? Function() list;

  /// The rows that are laid out, with their index.
  final Iterable<(int, RenderBox)> Function() rows;

  /// How many rows there are.
  final int Function() count;

  final Animation<double> progress;

  /// The stack's resting top in the list.
  final double Function() topPadding;

  NotificationShelfFrame? _frame;
  bool _cached = false;

  /// The current one, once the list is laid out. Every row reads it while it
  /// paints, so it is kept until the frame is done.
  NotificationShelfFrame? read() {
    if (_cached) return _frame;
    final frame = _read();
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      _frame = frame;
      _cached = true;
      binding.addPostFrameCallback((_) {
        _frame = null;
        _cached = false;
      });
    }
    return frame;
  }

  NotificationShelfFrame? _read() {
    final list = this.list();
    final count = this.count();
    if (list == null || !list.hasSize || count == 0) return null;
    final open = progress.value.clamp(0.0, 1.0);
    final squish = AndroidStackExpansion.squish(open);
    final shift = topPadding() * (squish - open);
    final stackBottom = list.size.height - bottomMargin;
    final shelfStart = stackBottom - height - PixelNotificationMetrics.divider;
    final starts = <int, double>{};
    final icons = List<double>.filled(count, 0);
    var last = -1;
    var first = count;
    for (final (index, box) in rows()) {
      if (index >= count || !box.attached || !box.hasSize) continue;
      final start = NotificationShadeList.restingTop(box);
      if (start == null) continue;
      starts[index] = start;
      last = math.max(last, index);
      if (start >= shelfStart) {
        first = math.min(first, index);
        icons[index] = 1;
      } else if (open >= 1) {
        // Don't animate shelf icons during shade expansion.
        icons[index] = _iconAmount(
          start,
          box.size.height,
          shelfStart,
          isLast: index == count - 1,
        );
      }
    }
    if (last < 0) return null;
    // The rows not laid out below these are past the end too.
    for (var i = last + 1; i < count; i++) {
      first = math.min(first, i);
      icons[i] = 1;
    }
    return NotificationShelfFrame(
      open: open,
      squish: squish,
      shift: shift,
      stackBottom: stackBottom,
      starts: starts,
      shelfTop: first < count ? stackBottom * squish - height - shift : null,
      icons: icons,
    );
  }

  /// NotificationShelf.getAmountInShelf's icon transition of a row the shelf
  /// cuts.
  double _iconAmount(
    double start,
    double full,
    double shelfStart, {
    required bool isLast,
  }) {
    if (start + full < shelfStart) return 0;
    final iconStart = start + PixelNotificationMetrics.margin;
    final double shown;
    if (isLast) {
      shown = (shelfStart - start) / (iconStart - start);
    } else {
      shown =
          (shelfStart - iconStart) / math.min(start + full - iconStart, height);
    }
    return 1 - shown.clamp(0.0, 1.0);
  }
}

/// Cuts what is not a card (the section heading) off above the shelf.
class NotificationShelfClipper extends CustomClipper<Rect> {
  NotificationShelfClipper(this.geometry, {required Listenable motion})
    : super(reclip: motion);

  final NotificationShelfGeometry geometry;

  @override
  Rect getClip(Size size) {
    final frame = geometry.read();
    const far = 100000.0;
    final cut = frame != null && frame.shelfTop != null;
    return Rect.fromLTRB(-far, -far, far, cut ? frame.clipEnd : far);
  }

  @override
  bool shouldReclip(NotificationShelfClipper oldClipper) =>
      !identical(oldClipper.geometry, geometry);
}

/// Android's NotificationShelf: the bar at the end of the stack with the
/// icons of the notifications below it, each in a 22 dp slot from 13 dp in,
/// the ones that do not fit as a dot.
class NotificationShelf extends StatelessWidget {
  const NotificationShelf({
    required this.geometry,
    required this.motion,
    required this.notifications,
    super.key,
  });

  final NotificationShelfGeometry geometry;
  final Listenable motion;

  /// One for each row, in order.
  final List<DesktopNotification> notifications;

  static const double _slot = 22;
  static const double _icon = 15;
  static const double _padding = 13;

  RRect? _shape(Size size) {
    final top = geometry.read()?.shelfTop;
    if (top == null) return null;
    const height = NotificationShelfGeometry.height;
    return RRect.fromRectAndRadius(
      Rect.fromLTWH(0, top, size.width, height),
      const Radius.circular(height / 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    return IgnorePointer(
      child: ShadeCard(
        shape: _shape,
        motion: motion,
        child: Flow(
          clipBehavior: Clip.none,
          delegate: _ShelfDelegate(geometry, motion),
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceEffect1,
                borderRadius: BorderRadius.circular(
                  NotificationShelfGeometry.height / 2,
                ),
              ),
            ),
            Center(
              child: SizedBox.square(
                dimension: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.onSurface,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            for (final notification in notifications)
              Center(
                child: SizedBox.square(
                  dimension: _icon,
                  child: switch (notification.smallIcon) {
                    final image? => NotificationSmallIcon(
                      image: image,
                      color: scheme.onSurface,
                    ),
                    null => ClipOval(
                      child: NotificationAppIcon(notification: notification),
                    ),
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ShelfDelegate extends FlowDelegate {
  _ShelfDelegate(this.geometry, Listenable motion) : super(repaint: motion);

  final NotificationShelfGeometry geometry;

  /// The children before the icons: the bar and the dot.
  static const int _icons = 2;

  /// ICON_ALPHA_INTERPOLATOR.
  static const Curve _fade = Cubic(0.6, 0, 0.6, 0);

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      i == 0
      ? BoxConstraints.tightFor(
          width: constraints.maxWidth,
          height: NotificationShelfGeometry.height,
        )
      : BoxConstraints.tight(const Size.square(NotificationShelf._slot));

  @override
  void paintChildren(FlowPaintingContext context) {
    final frame = geometry.read();
    final top = frame?.shelfTop;
    if (frame == null || top == null) return;
    context.paintChild(0, transform: Matrix4.translationValues(0, top, 0));
    final y =
        top + (NotificationShelfGeometry.height - NotificationShelf._slot) / 2;
    final right = context.size.width - NotificationShelf._padding;
    final shown = math.min(frame.icons.length, context.childCount - _icons);
    var x = NotificationShelf._padding;
    for (var i = 0; i < shown; i++) {
      final amount = frame.icons[i];
      if (amount <= 0) continue;
      // Room for this one, and for a dot unless it is the last.
      final need = NotificationShelf._slot * (i == shown - 1 ? 1 : 2);
      final overflows = x + need > right;
      context.paintChild(
        overflows ? 1 : _icons + i,
        transform: Matrix4.translationValues(x, y, 0),
        opacity: amount >= 1 ? 1 : _fade.transform(amount),
      );
      if (overflows) return;
      x += amount * NotificationShelf._slot;
    }
  }

  @override
  bool shouldRepaint(_ShelfDelegate oldDelegate) =>
      !identical(oldDelegate.geometry, geometry);
}

/// The footer hides (260 ms) while it does not fit above the stack's end.
class NotificationFooterFade extends StatefulWidget {
  const NotificationFooterFade({
    required this.geometry,
    required this.motion,
    required this.child,
    super.key,
  });

  final NotificationShelfGeometry geometry;
  final Listenable motion;
  final Widget child;

  @override
  State<NotificationFooterFade> createState() => _NotificationFooterFadeState();
}

class _NotificationFooterFadeState extends State<NotificationFooterFade> {
  /// Null until the first frame with a layout, which it takes as it is.
  bool? _fits;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.motion.addListener(_schedule);
    _schedule();
  }

  @override
  void didUpdateWidget(NotificationFooterFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.motion, widget.motion)) {
      oldWidget.motion.removeListener(_schedule);
      widget.motion.addListener(_schedule);
    }
    _schedule();
  }

  @override
  void dispose() {
    widget.motion.removeListener(_schedule);
    super.dispose();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final frame = widget.geometry.read();
      final box = context.findRenderObject();
      if (frame == null || box is! RenderBox || !box.hasSize) return;
      final top = NotificationShadeList.restingTop(box);
      if (top == null) return;
      final fits = top + box.size.height <= frame.stackBottom + 0.5;
      if (fits != _fits) setState(() => _fits = fits);
    });
  }

  @override
  Widget build(BuildContext context) {
    final fits = _fits;
    return IgnorePointer(
      ignoring: fits != true,
      child: AnimatedOpacity(
        opacity: fits ?? false ? 1 : 0,
        duration: fits == null || MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : androidDuration(260),
        child: widget.child,
      ),
    );
  }
}
