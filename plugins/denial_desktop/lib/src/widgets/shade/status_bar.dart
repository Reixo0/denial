import 'package:denial_desktop/src/state/reference_shell_controller.dart';
import 'package:denial_desktop/src/state/reference_shell_state.dart';
import 'package:denial_desktop/src/state/reference_shell_metrics.dart';

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/models.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/shell_color_scheme.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

import '../notification_media.dart'
    show NotificationAppIcon, NotificationSmallIcon;
import 'shade_drag_detector.dart';
import 'shade_expansion.dart';
import 'shade_expansion_motion.dart';
import 'shade_reference_geometry.dart';
import 'quick_settings_panel.dart' show PixelShadeViewport;
import 'status_glyphs.dart';

/// The status row's geometry. Android (EvolutionX on this phone, which has
/// no cutout) centres the clock and icons 13.85 dp from the top, 20 dp in
/// from each side; Denial's drag strip below stays as it was.
class _StatusGeometry {
  _StatusGeometry.of(BuildContext context)
    : topPadding = MediaQuery.paddingOf(context).top,
      referenceScale = colorOsShadeScaleForViewport(MediaQuery.sizeOf(context)),
      dp = PixelShadeViewport.scaleFor(MediaQuery.sizeOf(context));

  final double topPadding;
  final double referenceScale;

  /// Logical pixels per Android dp.
  final double dp;

  double get expandedTop => math.max(40 * referenceScale, topPadding);
  double get expandedHeight => 18 * referenceScale;
  double get hitHeight => math.max(
    topPadding + ReferenceShellMetrics.statusBarHeight,
    expandedTop + expandedHeight,
  );

  static const double _centre = 13.85;
  static const double _side = 20;

  /// The status row, in screen coordinates.
  List<Widget> foreground(Color color) {
    final top = topPadding;
    final height = 2 * _centre * dp;
    return [
      PositionedDirectional(
        top: top,
        height: height,
        start: _side * dp,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _StatusClock(color: color, dp: dp),
            _StatusNotificationIcons(color: color, dp: dp),
          ],
        ),
      ),
      PositionedDirectional(
        top: top,
        height: height,
        end: _side * dp,
        child: Center(
          child: _StatusCluster(color: color, dp: dp),
        ),
      ),
    ];
  }
}

/// The status foreground over the current app, or white over a dark scene.
Color _statusForeground(BuildContext context, WidgetRef ref) {
  final statusColorArgb = ref.watch(
    referenceShellProvider.select(
      (state) => state.foregroundWindow?.statusColorArgb,
    ),
  );
  final forceWhiteForeground = ref.watch(
    referenceShellProvider.select(
      (state) =>
          state.overviewVisible ||
          state.launchTransitionActive ||
          state.gesture == GestureDragPhase.up ||
          state.homeTransitionActive,
    ),
  );
  return forceWhiteForeground
      ? ShellMediaColors.contrastLight
      : _statusForegroundFor(context.shellColors, statusColorArgb);
}

/// The always-on top status bar. Dragging it down opens the quick-settings
/// shade. Time and battery are isolated into their own consumers so their
/// periodic updates never rebuild the drag surface.
///
/// As on Android it fades under the shade's scrim while the shade comes
/// down, and the shade's own header takes over the clock and icons. A
/// landscape view shows no bar, only its drag surface.
class ShadeStatusBar extends ConsumerStatefulWidget {
  const ShadeStatusBar({super.key, required this.expansion});

  /// The shade a pull on the bar opens.
  final ShadeExpansion expansion;

  @override
  ConsumerState<ShadeStatusBar> createState() => _ShadeStatusBarState();
}

class _ShadeStatusBarState extends ConsumerState<ShadeStatusBar> {
  /// Fingers on the bar: two pull the full quick settings at once.
  final Set<int> _pointers = <int>{};

  /// This strip's drag holds the shade.
  bool _owns = false;

  @override
  Widget build(BuildContext context) {
    final expansion = widget.expansion;
    final foreground = _statusForeground(context, ref);
    final progress = expansion.panel;
    final geometry = _StatusGeometry.of(context);
    // The lock screen draws its own status bar (Android's
    // KeyguardStatusBarView); this strip still pulls the shade over it.
    final shown =
        ReferenceShellMetrics.statusBarShown(MediaQuery.sizeOf(context)) &&
        !ref.watch(
          referenceShellProvider.select((state) => state.lockLayerVisible),
        );

    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: geometry.hitHeight,
      // Android: once the shade is open its header owns the top of the
      // screen; the strip only pulls it down. A drag already under way
      // keeps going (its pointer was routed when it went down).
      child: AnimatedBuilder(
        animation: progress,
        builder: (context, strip) =>
            IgnorePointer(ignoring: progress.value >= 0.99, child: strip),
        child: Listener(
          onPointerDown: (event) => _pointers.add(event.pointer),
          onPointerUp: (event) => _pointers.remove(event.pointer),
          onPointerCancel: (event) => _pointers.remove(event.pointer),
          child: ShadeDragDetector(
            behavior: HitTestBehavior.opaque,
            onStart: (_) => _owns = expansion.beginDrag(
              fromStatusBar: true,
              fingers: _pointers,
              barHeight: geometry.hitHeight,
            ),
            onUpdate: (details) {
              if (_owns) expansion.dragBy(details.delta.dy);
            },
            onEnd: (details) {
              if (_owns) expansion.endDrag(details.primaryVelocity ?? 0.0);
              _owns = false;
            },
            onCancel: () {
              if (_owns) expansion.endDrag(0.0);
              _owns = false;
            },
            // A clock or battery change repaints only the status bar; sharing a
            // picture with the rest of the chrome would damage everything down
            // to the home pill.
            // Android's status bar stays where it is and fades under the
            // shade's scrim as it comes down; the shade's own header takes
            // over the clock and icons.
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: Listenable.merge([progress, expansion.engaged]),
                builder: (context, row) {
                  // The icons leave as soon as the shade moves, on a short
                  // fade of their own (CollapsedStatusBarFragment).
                  final covered = math.max(
                    AospShadeInterpolation.scrimAlpha(progress.value),
                    expansion.engaged.value,
                  );
                  if (covered >= 1 || !shown) return const SizedBox.expand();
                  return Opacity(opacity: 1 - covered, child: row);
                },
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: geometry.foreground(foreground),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Android's status bar clock: 14 sp medium in the icon colour
/// (TextAppearance.StatusBar.Clock); Roboto Flex at 600 has Google Sans
/// Medium's stroke.
class _StatusClock extends ConsumerWidget {
  const _StatusClock({required this.color, required this.dp});

  final Color color;
  final double dp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    return Transform.translate(
      offset: Offset(0, statusTextDrop * statusTextSize * dp),
      child: Text(
        localizedTime(context, now),
        maxLines: 1,
        softWrap: false,
        textScaler: TextScaler.noScaling,
        style: ShellText.statusClock.copyWith(
          color: color,
          fontSize: statusTextSize * dp,
          height: 1,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _StatusCluster extends ConsumerWidget {
  const _StatusCluster({required this.color, required this.dp});

  final Color color;
  final double dp;

  @override
  Widget build(BuildContext context, WidgetRef ref) => StatusCluster(
    battery: ref.watch(batteryProvider),
    color: color,
    scale: dp,
  );
}

Color _statusForegroundFor(ShellColorScheme colors, int? statusColorArgb) {
  if (statusColorArgb == null) {
    return colors.textPrimary;
  }

  final background = Color.alphaBlend(
    Color(statusColorArgb),
    colors.background,
  );
  return background.computeLuminance() > 0.52
      ? ShellMediaColors.darkness
      : ShellMediaColors.contrastLight;
}

/// The notification icons after the clock, as Android's status bar shows
/// them (NotificationIconContainer): an icon per notification in the
/// shade's order, alerting ones only (Android leaves silent notifications
/// out by default), at most four (max_notif_static_icons) and then a dot.
/// Sizes from AOSP: 22 sp slots holding 15 dp icons, 6 dp after the
/// clock (measured on EvolutionX), a 4 sp dot 3 sp after them.
class _StatusNotificationIcons extends ConsumerWidget {
  const _StatusNotificationIcons({required this.color, required this.dp});

  final Color color;
  final double dp;
  static const int _max = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = ref.watch(
      referenceShellProvider.select((state) => state.lockLayerVisible),
    );
    final state = ref.watch(desktopNotificationsProvider);
    if (locked || state.lockPreview == NotificationPreviewMode.hidden) {
      return const SizedBox.shrink();
    }
    final shown = <DesktopNotification>[
      for (final group in state.groups)
        if (!group.members.every(
          (record) =>
              record.notification.urgency == DesktopNotificationUrgency.low,
        ))
          (group.summary ?? group.members.first).notification,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    final overflow = shown.length > _max;
    return Padding(
      padding: EdgeInsetsDirectional.only(start: 6 * dp),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final notification in shown.take(_max))
            SizedBox.square(
              dimension: 22 * dp,
              child: Center(
                child: SizedBox.square(
                  dimension: 15 * dp,
                  child: _StatusNotificationIcon(
                    notification: notification,
                    color: color,
                  ),
                ),
              ),
            ),
          if (overflow)
            Padding(
              padding: EdgeInsetsDirectional.only(start: 3 * dp),
              child: Container(
                width: 4 * dp,
                height: 4 * dp,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
        ],
      ),
    );
  }
}

/// One notification's status bar icon. Android draws the notification's
/// small icon, white on clear, tinted like the other status icons; until
/// the sender passes one, the app's own icon stands in.
class _StatusNotificationIcon extends StatelessWidget {
  const _StatusNotificationIcon({
    required this.notification,
    required this.color,
  });

  final DesktopNotification notification;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final small = notification.smallIcon;
    return small == null
        ? ClipOval(child: NotificationAppIcon(notification: notification))
        : NotificationSmallIcon(image: small, color: color);
  }
}
