import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/state.dart';

import '../phone_scheme.dart';
import 'notification_shade_list.dart';

/// Android's "Clear all" (NotificationStackScrollLayout.clearNotifications):
/// the visible rows slide out one after another from the last to the first,
/// 200 ms each on fast-out-linear-in, each starting 60, 55, 50 ... (at least
/// 30) ms after the one below it.
class NotificationClearAll {
  NotificationClearAll(TickerProvider vsync)
    : _time = AnimationController(vsync: vsync);

  static const int _slideMs = 200;

  final AnimationController _time;
  final Set<_NotificationClearSlideState> _rows = {};
  late final Animation<double> fade = Tween<double>(
    begin: 1,
    end: 0,
  ).animate(CurvedAnimation(parent: _time, curve: const Interval(0, 0.5)));
  bool _running = false;

  /// The rows that are laid out, with their index.
  Iterable<(int, RenderBox)> get boxes sync* {
    for (final row in _rows) {
      if (!row.mounted) continue;
      final box = row.context.findRenderObject();
      if (box is RenderBox) yield (row.widget.index, box);
    }
  }

  /// Slides the rows out, then calls [onCleared].
  Future<void> start(VoidCallback onCleared) async {
    if (_running) return;
    final rows = [
      for (final row in _rows)
        if (row.widget.clearable && row.onScreen) row,
    ]..sort((a, b) => b.widget.index.compareTo(a.widget.index));
    if (rows.isEmpty) {
      onCleared();
      return;
    }
    var gap = 60;
    var delay = 0;
    for (final row in rows) {
      row._delay = delay;
      gap = math.max(30, gap - 5);
      delay += gap;
    }
    final total = rows.last._delay! + _slideMs;
    _time.duration = Duration(milliseconds: total);
    _running = true;
    try {
      await _time.forward(from: 0).orCancel;
      onCleared();
    } on TickerCanceled {
      // The list is gone.
      return;
    }
    for (final row in rows) {
      row._delay = null;
    }
    _time.value = 0;
    _running = false;
  }

  void dispose() => _time.dispose();
}

/// A row [NotificationClearAll] slides out to the right.
class NotificationClearSlide extends StatefulWidget {
  const NotificationClearSlide({
    required this.clearAll,
    required this.index,
    required this.clearable,
    required this.child,
    super.key,
  });

  final NotificationClearAll clearAll;
  final int index;
  final bool clearable;
  final Widget child;

  @override
  State<NotificationClearSlide> createState() => _NotificationClearSlideState();
}

class _NotificationClearSlideState extends State<NotificationClearSlide> {
  int? _delay;

  /// Any part of the row is on the screen.
  bool get onScreen {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final view = View.of(context);
    final height = view.physicalSize.height / view.devicePixelRatio;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = box.localToGlobal(Offset(0, box.size.height)).dy;
    return bottom > 0 && top < height;
  }

  @override
  void initState() {
    super.initState();
    widget.clearAll._rows.add(this);
    widget.clearAll._time.addListener(_moved);
  }

  @override
  void didUpdateWidget(NotificationClearSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.clearAll, widget.clearAll)) return;
    oldWidget.clearAll._rows.remove(this);
    oldWidget.clearAll._time.removeListener(_moved);
    widget.clearAll._rows.add(this);
    widget.clearAll._time.addListener(_moved);
  }

  @override
  void activate() {
    super.activate();
    widget.clearAll._rows.add(this);
  }

  /// Out of the tree, its place must not be read.
  @override
  void deactivate() {
    widget.clearAll._rows.remove(this);
    super.deactivate();
  }

  @override
  void dispose() {
    widget.clearAll._time.removeListener(_moved);
    super.dispose();
  }

  void _moved() {
    if (_delay != null) NotificationShadeList.invalidateOcclusion(context);
  }

  double get _offset {
    final delay = _delay;
    final total = widget.clearAll._time.duration;
    if (delay == null || total == null) return 0;
    final ms = widget.clearAll._time.value * total.inMilliseconds - delay;
    return const Cubic(
      0.4,
      0,
      1,
      1,
    ).transform((ms / NotificationClearAll._slideMs).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.clearAll._time,
      builder: (context, child) => FractionalTranslation(
        // Past the screen's edge, the side margin included.
        translation: Offset(_offset * 1.1, 0),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Fades out while [NotificationClearAll] runs.
class NotificationClearFade extends StatelessWidget {
  const NotificationClearFade({
    required this.clearAll,
    required this.fades,
    required this.child,
    super.key,
  });

  final NotificationClearAll clearAll;
  final bool fades;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      fades ? FadeTransition(opacity: clearAll.fade, child: child) : child;
}

/// The footer under the last notification, EvolutionX's
/// notification_2025_footer: "Clear all" and the notification settings, 40 dp
/// pills 8 dp apart, without its history button (the owner's choice).
class NotificationFooter extends ConsumerWidget {
  const NotificationFooter({
    required this.clearAll,
    required this.onSettings,
    required this.onCleared,
    super.key,
  });

  final NotificationClearAll clearAll;
  final VoidCallback onSettings;

  /// The rows have left and their notifications are dismissed.
  final VoidCallback onCleared;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = phoneSchemeOf(context);
    final canClear = ref.watch(
      desktopNotificationsProvider.select(
        (s) => s.history.any((record) => record.notification.clearable),
      ),
    );
    return SizedBox(
      height: 48,
      child: Row(
        children: <Widget>[
          Expanded(
            child: canClear
                ? _FooterPill(
                    label: context.l10n.notificationsClearAll,
                    onTap: () => clearAll.start(() {
                      ref
                          .read(desktopNotificationsProvider.notifier)
                          .clearAll();
                      onCleared();
                    }),
                    child: Text(
                      context.l10n.notificationsClearAllButton,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 16,
                        height: 1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: _FooterPill(
              label: context.l10n.notificationSettingsButton,
              onTap: onSettings,
              child: CustomPaint(
                size: const Size.square(20),
                painter: _NotificationSettingsGlyph(scheme.onSurface),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterPill extends StatefulWidget {
  const _FooterPill({
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_FooterPill> createState() => _FooterPillState();
}

class _FooterPillState extends State<_FooterPill> {
  bool _pressed = false;

  void _press(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = phoneSchemeOf(context);
    final surface = scheme.surfaceEffect1;
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _press(true),
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _pressed
                  ? Color.alphaBlend(
                      scheme.onSurface.withValues(alpha: 0.10),
                      surface,
                    )
                  : surface,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Center(child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// A bell with a gear in place of its top end corner, as on EvolutionX's
/// button (20 dp); the gear is the icon font's.
class _NotificationSettingsGlyph extends CustomPainter {
  const _NotificationSettingsGlyph(this.color);

  final Color color;

  static const Offset _gear = Offset(14.5, 5.5);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    canvas
      ..save()
      ..scale(size.width / 20);
    final bell = Path()
      ..addRect(const Rect.fromLTRB(4, 14, 16, 15.5))
      ..moveTo(5, 14)
      ..lineTo(5, 9)
      ..arcToPoint(const Offset(15, 9), radius: const Radius.circular(5))
      ..lineTo(15, 14)
      ..close()
      ..moveTo(8.5, 16.5)
      ..lineTo(11.5, 16.5)
      ..arcToPoint(const Offset(8.5, 16.5), radius: const Radius.circular(1.5))
      ..close();
    final cut = Path()..addOval(Rect.fromCircle(center: _gear, radius: 5.56));
    canvas.drawPath(Path.combine(PathOperation.difference, bell, cut), paint);
    const gear = Icons.settings;
    final text = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(gear.codePoint),
        style: TextStyle(
          color: color,
          fontSize: 9.6,
          height: 1,
          fontFamily: gear.fontFamily,
          package: gear.fontPackage,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text
      ..paint(canvas, _gear - const Offset(4.8, 4.8))
      ..dispose();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NotificationSettingsGlyph old) => old.color != color;
}
