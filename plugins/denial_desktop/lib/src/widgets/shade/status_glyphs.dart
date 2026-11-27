import 'package:denial_flutter_sdk/controls.dart';
import 'package:flutter/material.dart' show Icons;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:denial_flutter_sdk/settings.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/system_services.dart';

import 'package:denial_sdk/system.dart';
import 'package:denial_flutter_sdk/localization.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/tokens.dart';

/// iOS-style rounded battery capsule with a level fill, charge nub, and an
/// optional centered charging bolt.
class _BatteryCapsule extends StatelessWidget {
  const _BatteryCapsule({
    required this.level,
    required this.fill,
    required this.charging,
    required this.scale,
    required this.foreground,
  });

  final double level;
  final Color fill;
  final bool charging;
  final double scale;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final s = scale;
    const width = 25.0;
    const height = 13.0;
    final outline = foreground.withValues(alpha: 0.48);
    return SizedBox(
      width: width * s,
      height: height * s,
      child: Stack(
        children: [
          Positioned.fill(
            right: 3.4 * s,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: outline, width: 1.3 * s),
                borderRadius: context.shellTheme.borderRadius(height * s / 2),
              ),
            ),
          ),
          Positioned(
            right: 0.4 * s,
            top: height * s / 2 - 2.3 * s,
            width: 1.8 * s,
            height: 4.6 * s,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: outline,
                borderRadius: context.shellTheme.borderRadius(0.9 * s),
              ),
            ),
          ),
          Positioned(
            left: 2.7 * s,
            top: 2.7 * s,
            bottom: 2.7 * s,
            width: (width - 2.7 - 4.8) * s * level,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: context.shellTheme.borderRadius(3.8 * s),
              ),
            ),
          ),
          if (charging)
            Positioned.fill(
              right: 3.4 * s,
              child: Center(
                child: Icon(
                  Icons.bolt_rounded,
                  size: 11 * s,
                  color: ShellMediaColors.contrastLight,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Color _batteryFill(BatteryStatus status, Color foreground) {
  if (status.charging) {
    return ShellTelemetryColors.chargingVooc;
  }
  final capacity = status.capacity;
  if (capacity != null && capacity <= 15) {
    return ShellTelemetryColors.danger;
  }
  return foreground;
}

bool _batteryLow(BatteryStatus status) =>
    !status.charging && status.capacity != null && status.capacity! <= 15;

/// Battery percentage label beside a rounded level capsule.
class BatteryMark extends StatelessWidget {
  const BatteryMark({
    super.key,
    required this.status,
    this.scale = 1.0,
    this.textScale,
    this.color,
  });

  final BatteryStatus status;
  final double scale;
  final double? textScale;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final level = ((status.capacity ?? 64) / 100.0).clamp(0.0, 1.0);
    final foreground = color ?? context.shellColors.textPrimary;
    final low = _batteryLow(status);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          status.capacity == null
              ? context.l10n.batteryCapacityUnavailable
              : context.l10n.percentCompact(status.capacity!),
          style: TextStyle(
            color: low ? ShellTelemetryColors.danger : foreground,
            fontSize: 12.5 * (textScale ?? scale),
            height: 1,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            decoration: TextDecoration.none,
          ),
        ),
        SizedBox(width: 4.5 * scale),
        _BatteryCapsule(
          level: level,
          fill: _batteryFill(status, foreground),
          charging: status.charging,
          scale: scale,
          foreground: foreground,
        ),
      ],
    );
  }
}

class BatteryIconMark extends StatelessWidget {
  const BatteryIconMark({
    super.key,
    required this.status,
    this.scale = 1.0,
    this.color,
  });

  final BatteryStatus status;
  final double scale;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final level = ((status.capacity ?? 64) / 100.0).clamp(0.0, 1.0);
    final foreground = color ?? context.shellColors.textPrimary;

    return _BatteryCapsule(
      level: level,
      fill: _batteryFill(status, foreground),
      charging: status.charging,
      scale: scale,
      foreground: foreground,
    );
  }
}

/// Four ascending pill bars.
class SignalGlyph extends StatelessWidget {
  const SignalGlyph({
    super.key,
    required this.active,
    this.strength = 0,
    this.scale = 1.0,
    this.color,
  });

  final bool active;
  final int strength;
  final double scale;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? context.shellColors.textPrimary;
    final bars = active ? (strength.clamp(0, 100) / 25).ceil() : 0;
    return SizedBox(
      width: 20 * scale,
      height: 11 * scale,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 4; i++) ...[
            Container(
              width: 3.2 * scale,
              height: (4.4 + i * 2.2) * scale,
              decoration: BoxDecoration(
                color: i < bars
                    ? foreground
                    : foreground.withValues(alpha: 0.28),
                borderRadius: context.shellTheme.borderRadius(1.6 * scale),
              ),
            ),
            if (i != 3) SizedBox(width: 2.4 * scale),
          ],
        ],
      ),
    );
  }
}

/// Marks while an app uses the camera, the microphone or the location: a
/// green pill for the camera and microphone, the location pin in the status
/// color. Empty while nothing is in use.
class PrivacyUsageMarks extends ConsumerWidget {
  const PrivacyUsageMarks({super.key, this.color, this.scale = 1});

  final Color? color;
  final double scale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(privacyUsageProvider);
    if (!usage.any) return const SizedBox.shrink();
    final foreground = color ?? context.shellColors.textPrimary;
    final l10n = context.l10n;
    String label(String text, List<String> apps) =>
        apps.isEmpty ? text : '$text: ${apps.join(', ')}';
    final media = usage.camera || usage.microphone;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (media)
          Semantics(
            label: [
              if (usage.camera)
                label(l10n.privacyCameraInUse, usage.cameraApps),
              if (usage.microphone)
                label(l10n.privacyMicrophoneInUse, usage.microphoneApps),
            ].join('. '),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 5 * scale,
                vertical: 2 * scale,
              ),
              decoration: BoxDecoration(
                color: ShellPrivacyColors.inUse,
                borderRadius: BorderRadius.circular(9 * scale),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (usage.camera)
                    Icon(
                      Icons.videocam_rounded,
                      size: 12 * scale,
                      color: ShellPrivacyColors.onInUse,
                    ),
                  if (usage.camera && usage.microphone)
                    SizedBox(width: 2 * scale),
                  if (usage.microphone)
                    Icon(
                      Icons.mic_rounded,
                      size: 12 * scale,
                      color: ShellPrivacyColors.onInUse,
                    ),
                ],
              ),
            ),
          ),
        if (media && usage.location) SizedBox(width: 6 * scale),
        if (usage.location)
          Semantics(
            label: label(l10n.privacyLocationInUse, usage.locationApps),
            child: Icon(
              Icons.location_on_rounded,
              size: 13 * scale,
              color: foreground,
            ),
          ),
        SizedBox(width: 10 * scale),
      ],
    );
  }
}

/// Logical pixels per Android dp for the status cluster in the shade
/// header, which is drawn in the shade's dp: Android's own size, as in the
/// status bar.
const double phoneStatusIconScale = 1.0;

/// Android's status icons (StatusIconContainer and BatteryMeterView), as
/// EvolutionX shows them on this phone: the ringer mode, the mobile bars,
/// Wi-Fi, a circle battery and its percentage. [scale] is logical pixels per
/// Android dp; sizes and gaps were measured from EvolutionX screenshots
/// (1 dp = 2.925 px) and match AOSP's 15 dp icons and 14 sp text.
class StatusCluster extends ConsumerWidget {
  const StatusCluster({
    super.key,
    required this.battery,
    this.color,
    this.scale = 1,
  });

  final BatteryStatus battery;
  final Color? color;
  final double scale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = scale;
    final foreground = color ?? context.shellColors.textPrimary;
    final ringer = ref.watch(
      shellSettingsProvider.select((settings) => settings.sound.ringerMode),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PrivacyUsageMarks(color: color, scale: 0.75 * s),
        if (ringer != PhoneRingerMode.normal) ...[
          ringer == PhoneRingerMode.vibrate
              ? CustomPaint(
                  size: Size(14 * _vibrateUnit * s, 12 * _vibrateUnit * s),
                  painter: _VibratePainter(foreground),
                )
              : Icon(Icons.volume_off_rounded, size: 15 * s, color: foreground),
          SizedBox(width: 11.3 * s),
        ],
        MobileConnectivityMarks(color: color, scale: s),
        SizedBox(width: 6.5 * s),
        StatusBattery(status: battery, scale: s, color: color),
      ],
    );
  }
}

/// stat_sys_ringer_vibrate: 18 dp tall drawn at the 15 dp icon size.
const double _vibrateUnit = 15 / 18;

/// The phone with a bar each side (stat_sys_ringer_vibrate), in its own
/// units: an 8 x 12 body with 1 unit corners, 1.5 x 6 pills 1.5 units off
/// each side.
class _VibratePainter extends CustomPainter {
  const _VibratePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 14;
    final paint = Paint()..color = color;
    canvas.drawRRect(
      RRect.fromLTRBR(3 * u, 0, 11 * u, 12 * u, Radius.circular(u)),
      paint,
    );
    for (final x in [0.0, 12.5]) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          x * u,
          3 * u,
          (x + 1.5) * u,
          9 * u,
          Radius.circular(0.75 * u),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_VibratePainter oldDelegate) => oldDelegate.color != color;
}

/// Four rounded bars rising left to right, the unreached ones dimmed, as
/// Android 17 draws the mobile signal. Measured: 2.74 dp bars 2.05 dp apart,
/// 5.1 to 12 dp tall.
class SignalBars extends StatelessWidget {
  const SignalBars({
    super.key,
    required this.bars,
    required this.color,
    this.scale = 1,
  });

  final int bars;
  final Color color;
  final double scale;

  static const double width = 4 * _bar + 3 * _gap;
  static const double height = 11.97;
  static const double _bar = 2.735;
  static const double _gap = 2.05;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(width * scale, height * scale),
    painter: _SignalBarsPainter(bars, color),
  );
}

class _SignalBarsPainter extends CustomPainter {
  const _SignalBarsPainter(this.bars, this.color);

  final int bars;
  final Color color;

  static const List<double> _heights = <double>[5.13, 7.52, 9.91, 11.97];

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.height / SignalBars.height;
    final bar = SignalBars._bar * u;
    for (var i = 0; i < 4; i++) {
      final left = i * (SignalBars._bar + SignalBars._gap) * u;
      canvas.drawRRect(
        RRect.fromLTRBR(
          left,
          size.height - _heights[i] * u,
          left + bar,
          size.height,
          Radius.circular(bar / 2),
        ),
        Paint()..color = i < bars ? color : color.withValues(alpha: 0.45),
      );
    }
  }

  @override
  bool shouldRepaint(_SignalBarsPainter oldDelegate) =>
      oldDelegate.bars != bars || oldDelegate.color != color;
}

/// The circle battery and its percentage (EvolutionX's circle style): a
/// 13 dp ring, 2 dp thick, filled clockwise from the top over a dimmed
/// track; green with a bolt inside while charging, red when low. The
/// percentage is 14 sp regular text 4.8 dp after it.
class StatusBattery extends StatelessWidget {
  const StatusBattery({
    super.key,
    required this.status,
    this.scale = 1,
    this.color,
  });

  final BatteryStatus status;
  final double scale;
  final Color? color;

  static const Color charging = Color(0xff18cc47);

  @override
  Widget build(BuildContext context) {
    final s = scale;
    final foreground = color ?? context.shellColors.textPrimary;
    final level = ((status.capacity ?? 0) / 100.0).clamp(0.0, 1.0);
    final arc = status.charging
        ? charging
        : _batteryLow(status)
        ? ShellTelemetryColors.danger
        : foreground;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 13 * s,
          child: CustomPaint(
            painter: _BatteryRingPainter(
              level: level,
              arc: arc,
              track: foreground.withValues(alpha: 0.45),
              stroke: 2.05 * s,
            ),
            child: status.charging
                ? Center(
                    child: Icon(
                      Icons.bolt_rounded,
                      size: 7.5 * s,
                      color: foreground,
                    ),
                  )
                : null,
          ),
        ),
        SizedBox(width: 4.8 * s),
        Transform.translate(
          offset: Offset(0, statusTextDrop * statusTextSize * s),
          child: Text(
            status.capacity == null
                ? context.l10n.batteryCapacityUnavailable
                : context.l10n.percentCompact(status.capacity!),
            maxLines: 1,
            softWrap: false,
            textScaler: TextScaler.noScaling,
            style: ShellText.base.copyWith(
              color: foreground,
              fontSize: statusTextSize * s,
              height: 1,
              fontWeight: FontWeight.w400,
              letterSpacing: 0,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ],
    );
  }
}

/// The status bar's text (clock, battery percentage) in dp: Android's 14 sp,
/// whose digits come out 31 px tall in Roboto Flex as in Google Sans on
/// EvolutionX.
const double statusTextSize = 14;

/// Roboto Flex's digits sit higher in a one-line box than Google Sans's:
/// this moves them onto the icons' centre, as on EvolutionX (in em).
const double statusTextDrop = 0.075;

class _BatteryRingPainter extends CustomPainter {
  const _BatteryRingPainter({
    required this.level,
    required this.arc,
    required this.track,
    required this.stroke,
  });

  final double level;
  final Color arc;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawOval(rect, paint..color = track);
    if (level > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * level,
        false,
        paint..color = arc,
      );
    }
  }

  @override
  bool shouldRepaint(_BatteryRingPainter oldDelegate) =>
      oldDelegate.level != level ||
      oldDelegate.arc != arc ||
      oldDelegate.track != track ||
      oldDelegate.stroke != stroke;
}

class StatusIconCluster extends StatelessWidget {
  const StatusIconCluster({super.key, required this.battery, this.color});

  final BatteryStatus battery;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PrivacyUsageMarks(color: color),
        MobileConnectivityMarks(color: color, scale: 1.2),
        const SizedBox(width: 12),
        BatteryIconMark(status: battery, scale: 1.18, color: color),
      ],
    );
  }
}

class MobileConnectivityMarks extends ConsumerWidget {
  const MobileConnectivityMarks({super.key, this.color, this.scale = 1});
  final Color? color;
  final double scale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wifi = ref
        .watch(networkConnectivityProvider)
        .snapshot
        .connectedNetwork;
    final discovery = ref.watch(mobileNetworkProvider);
    final lastMobile = discovery.value ?? const MobileNetworkSnapshot();
    final mobile = discovery.isLoading || discovery.hasError
        ? lastMobile.unavailable()
        : lastMobile;
    final foreground = color ?? context.shellColors.textPrimary;
    // The bars show the network's signal whenever the SIM is registered, with
    // or without mobile data; the technology shows while data runs over it
    // and no Wi-Fi is connected, and the Wi-Fi icon only while one is, as on
    // Android.
    final signal =
        mobile.simPresence == MobileSimPresence.present &&
        mobile.registered &&
        !mobile.locked;
    final s = scale;
    final technology =
        wifi == null && mobile.cellularWorking && mobile.technology.isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Hide only a confirmed absent SIM. Discovery/loading failure remains
        // visible as unavailable; modem and WWAN policy are not SIM presence.
        // Android puts the network type before the bars.
        if (mobile.showCellular) ...[
          Semantics(
            label: mobile.cellularWorking
                ? context.l10n.mobileConnected
                : mobile.simPresence == MobileSimPresence.unknown ||
                      !mobile.managerAvailable
                ? context.l10n.mobileUnavailable
                : context.l10n.mobileDisconnected,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (technology) ...[
                  Text(
                    mobile.technology,
                    maxLines: 1,
                    softWrap: false,
                    textScaler: TextScaler.noScaling,
                    style: ShellText.base.copyWith(
                      color: foreground,
                      fontSize: 12 * s,
                      height: 1,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                    ),
                  ),
                  SizedBox(width: 2 * s),
                ],
                SignalBars(
                  bars: signal
                      ? (mobile.strength.clamp(0, 100) / 25).ceil()
                      : 0,
                  color: foreground,
                  scale: s,
                ),
                if (!signal)
                  Icon(
                    Icons.priority_high_rounded,
                    size: 10 * s,
                    color: foreground,
                  ),
              ],
            ),
          ),
          if (wifi != null) SizedBox(width: 6.5 * s),
        ],
        // Material's wifi glyph is 22/24 of its box: 16.8 dp wide, as
        // measured on EvolutionX.
        if (wifi != null)
          WifiStatusIcon(
            active: true,
            strength: wifi.strength,
            size: 18.3 * s,
            color: color,
          ),
      ],
    );
  }
}
